import parser.RocSyntax
import cli.Path
import DocSamples
import SpecSuite

## Build-time highlighting of the original sample text. The parser's lexer
## accepts partial snippets; it never formats, repairs or type-checks them.
SiteCode := [].{

	## Escape text for a code element. A carriage return is an entity so the
	## HTML parser preserves CRLF rather than normalizing it to LF.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\r", "&#13;")

	## Cover every original UTF-8 byte exactly once. If a future lexer returns
	## an incomplete range or splits a code point, retain safe, plain text.
	html : Str -> Str
	html = |source| {
		lexed = RocSyntax.tokenize_str(source)
		if lexed.source != source.to_utf8() {
			return SiteCode.escape(source)
		}
		var $cursor = 0
		var $parts = []
		for token in lexed.tokens {
			if token.start != $cursor or token.end < token.start or token.end > lexed.source.len() {
				return SiteCode.escape(source)
			}
			$cursor = token.end
			if token.end > token.start {
				text = match Str.from_utf8(lexed.source.sublist({ start: token.start, len: token.end - token.start })) {
					Ok(decoded) => SiteCode.escape(decoded)
					Err(_) => return SiteCode.escape(source)
				}
				category = RocSyntax.highlight_category(token.kind)
				$parts = $parts.append(
					if category == Trivia {
						text
					} else {
						"<span class=\"syntax-${category_name(category)}\">${text}</span>"
					},
				)
			}
		}
		if ($cursor == lexed.source.len()) Str.join_with($parts, "") else SiteCode.escape(source)
	}

	## Remove only whole marker lines, retaining indentation, blank lines,
	## trailing whitespace and line endings in the displayed sample.
	visible : Str -> Str
	visible = |source| {
		var $parts = []
		lines = source.split_on("\n")
		for (line, index) in lines.map_with_index(|line, index| (line, index)) {
			trimmed = line.trim()
			if !trimmed.starts_with("# region ") and !trimmed.starts_with("# endregion ") {
				$parts = $parts.append("${line}${if (index + 1 < lines.len()) "\n" else ""}")
			}
		}
		Str.join_with($parts, "")
	}

	## Zola loads only these generated, escaped fragments. Missing samples or
	## regions fail the build, just as they fail the documentation checks.
	build! : () => Try({}, _)
	build! = || {
		if Path.exists!(Path.utf8("www/highlighted"))? {
			Path.delete_all!(Path.utf8("www/highlighted"))?
		}
		for page in SpecSuite.files_with!("www/content/docs", ".md")? {
			for { file, region } in DocSamples.uses(Path.read_utf8!(Path.utf8(page))?) {
				source = Path.read_utf8!(Path.utf8("www/samples/${file}"))?
				selected = if region == "" {
					source
				} else {
					match DocSamples.region_of(source, region) {
						Ok(text) => text
						Err(_) => return Err(MissingSampleRegion({ page, file, region }))
					}
				}
				dir = "www/highlighted/${file}/regions"
				Path.create_all!(Path.utf8(dir))?
				name = if (region == "") "../full" else region
				Path.write_utf8!(Path.utf8("${dir}/${name}.html"), if (file.ends_with(".roc")) SiteCode.html(SiteCode.visible(selected)) else SiteCode.escape(SiteCode.visible(selected)))?
			}
		}
		Path.create_all!(Path.utf8(".build"))?
		Path.write_utf8!(Path.utf8(".build/site-code-fixture.html"), "<pre><code>${SiteCode.html(SiteCode.fixture)}</code></pre>")?
		Ok({})
	}

	## A hostile, incomplete snippet exercises HTML safety and exact copying,
	## including Unicode, tabs, CRLF, trailing spaces and a final blank line.
	fixture = "# café & <script>alert(1)</script>\r\n\tvalue = \"<&>\"  \n\nunterminated = \"\u(0301)\n"
}

category_name = |category| match category {
	Trivia => "plain"
	CommentText => "comment"
	Name => "name"
	TypeName => "type"
	ReservedWord => "keyword"
	NumericLiteral => "number"
	StringText => "string"
	Symbol => "symbol"
	InvalidText => "invalid"
}

expect SiteCode.escape("<&>\r\n") == "&lt;&amp;&gt;&#13;\n"

expect {
	html = SiteCode.html(SiteCode.fixture)
	!html.contains("<script>") and html.contains("&lt;script&gt;") and html.contains("&#13;\n") and html.ends_with("\n")
}

expect {
	html = SiteCode.html("app value = 42 # comment\n")
	["keyword", "name", "number", "comment"].all(|name| html.contains("syntax-${name}"))
}

expect SiteCode.visible("# region outer\n\tvalue = \"# region text\"  \r\n\n# endregion outer\n") == "\tvalue = \"# region text\"  \r\n\n"
