import parser.RocSyntax
import cli.Path
import DocSamples
import SpecSuite
import ScmHighlight

## Build-time highlighting of the original sample text. The parser's lexer
## accepts partial snippets; it never formats, repairs or type-checks them.
SiteCode := [].{

	## Published samples show where a reader supplies the release package URL.
	## Only plain relative URL literals in the parsed header's dependency fields
	## change. All other source bytes, including quotes and line endings, remain
	## intact; the checked-in source still compiles against the local platform.
	published_source : Str -> Str
	published_source = |source| {
		parsed = RocSyntax.parse_str(source)
		root = match parsed.nodes.get(parsed.root) {
			Ok(node) => node
			Err(_) => return source
		}
		header = match node_children(parsed, root).first() {
			Ok(node) if node.kind == Header => node
			_ => return source
		}
		if parsed.source != source.to_utf8() or parsed.diagnostics.any(|diagnostic| diagnostic.start <= header.end) {
			return source
		}
		var $urls = []
		for dependencies in node_children(parsed, header).keep_if(|node| node.kind == Dependencies) {
			for field in node_children(parsed, dependencies).keep_if(|node| node.kind == DependencyField) {
				match dependency_url(parsed, field) {
					Ok(part) => {
						url = Str.from_utf8_lossy(parsed.source.sublist({ start: part.start, len: part.end - part.start }))
						if relative_package_url(url) {
							$urls = $urls.append(part)
						}
					}
					Err(_) => {}
				}
			}
		}
		var $cursor = 0
		var $parts = []
		for part in $urls {
			if part.start < $cursor or part.end < part.start or part.end > parsed.source.len() {
				return source
			}
			$parts = $parts.append(Str.from_utf8_lossy(parsed.source.sublist({ start: $cursor, len: part.start - $cursor }))).append("<package release URL here>")
			$cursor = part.end
		}
		Str.join_with($parts.append(Str.from_utf8_lossy(parsed.source.drop_first($cursor))), "")
	}

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

	## Scheme-style specs use their own display lexer, never the Roc lexer.
	## Token text is escaped by the same HTML boundary as the Roc samples.
	scm_html : Str -> Str
	scm_html = |source| Str.join_with(
		ScmHighlight.tokens(source).map(
			|{ text, category }| {
				escaped = SiteCode.escape(text)
				if (category == "plain") escaped else "<span class=\"syntax-${category}\">${escaped}</span>"
			},
		),
		"",
	)

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
				checked = Path.read_utf8!(Path.utf8("www/samples/${file}"))?
				source = if (file.ends_with(".roc")) SiteCode.published_source(checked) else checked
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
				displayed = SiteCode.visible(selected)
				markup = if file.ends_with(".roc") {
					SiteCode.html(displayed)
				} else if file.ends_with(".scm") {
					SiteCode.scm_html(displayed)
				} else {
					SiteCode.escape(displayed)
				}
				Path.write_utf8!(Path.utf8("${dir}/${name}.html"), markup)?
			}
		}
		Path.create_all!(Path.utf8(".build"))?
		Path.write_utf8!(Path.utf8(".build/site-code-fixture.html"), "<pre id=\"roc-fixture\"><code>${SiteCode.html(SiteCode.fixture)}</code></pre><pre id=\"scm-fixture\"><code>${SiteCode.scm_html(SiteCode.scm_fixture)}</code></pre>")?
		Ok({})
	}

	## A hostile, incomplete snippet exercises HTML safety and exact copying,
	## including Unicode, tabs, CRLF, trailing spaces and a final blank line.
	scm_fixture = "; café & <script>alert(1)</script>\r\n\t(test \"a\\\"; <&>\" :name #t false -12 symbol)  \n(unfinished \"e\u(0301)\n"

	fixture = "# café & <script>alert(1)</script>\r\n\tvalue = \"<&>\"  \n\nunterminated = \"\u(0301)\n"
}

node_children : RocSyntax.Parsed, RocSyntax.Node -> List(RocSyntax.Node)
node_children = |parsed, node| parsed.children.sublist({ start: node.children_start, len: node.children_len }).keep_oks(|index| parsed.nodes.get(index))

dependency_url : RocSyntax.Parsed, RocSyntax.Node -> Try(RocSyntax.Node, [NotUrl])
dependency_url = |parsed, field| {
	value = match node_children(parsed, field) {
		[_, child] => child
		_ => return Err(NotUrl)
	}
	literal = if value.kind == PlatformReference {
		match node_children(parsed, value) {
			[inner] => inner
			_ => return Err(NotUrl)
		}
	} else value
	match node_children(parsed, literal) {
		[part] if literal.kind == StringLiteral and part.kind == StringSegment => Ok(part)
		_ => Err(NotUrl)
	}
}

relative_package_url : Str -> Bool
relative_package_url = |url|
	!url.starts_with("/") and !url.contains(":") and !url.contains("\\")
		and (url.starts_with("./") or url.starts_with("../") or url.ends_with(".roc"))

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

expect {
	markup = SiteCode.scm_html(SiteCode.scm_fixture)
	["comment", "keyword", "string", "type", "number", "name", "symbol", "invalid"].all(|category| markup.contains("syntax-${category}")) and !markup.contains("<script>") and markup.contains("&lt;script&gt;") and markup.contains("&#13;\n")
}

## Header dependency URLs change; comments, body literals and imports do not.
expect {
	source = "# café: \"../../platform/main.roc\"\r\napp [main] { pf: platform \"../../platform/main.roc\", util: \"./lib/main.roc\", remote: \"https://example.com/pkg.tar.zst\" }\r\nimport \"../../platform/main.roc\" as text : Str\r\nmain = \"../../platform/main.roc\"  \r\n"
	wanted = "# café: \"../../platform/main.roc\"\r\napp [main] { pf: platform \"<package release URL here>\", util: \"<package release URL here>\", remote: \"https://example.com/pkg.tar.zst\" }\r\nimport \"../../platform/main.roc\" as text : Str\r\nmain = \"../../platform/main.roc\"  \r\n"
	SiteCode.published_source(source) == wanted and source.contains("pf: platform \"../../platform/main.roc\"")
}

## Package headers use the same substitution; module imports and assets do not.
expect {
	SiteCode.published_source("package [Thing] { util: \"lib/main.roc\" }\n") == "package [Thing] { util: \"<package release URL here>\" }\n"
		and SiteCode.published_source("module [main]\nimport \"../asset.svg\" as asset : Str\nmain = \"../platform/main.roc\"\n") == "module [main]\nimport \"../asset.svg\" as asset : Str\nmain = \"../platform/main.roc\"\n"
}

## Invalid/interpolated headers are untouched; absolute URLs remain literal.
expect {
	sources = ["app [main] { pf: platform \"https://example.com/main.roc\" }", "app [main] { pf: platform \"/absolute/main.roc\" }", "app [main] { pf: platform \"../\${path}/main.roc\" }", "app [main] { pf: platform \"../main.roc\""]
	sources.all(|source| SiteCode.published_source(source) == source)
}

## Platform package dependencies change without touching native target inputs.
expect {
	source = "platform \"p\" requires {} exposes [] packages { dep: \"../lib.roc\" } provides {} targets: { linux: { inputs: [\"../lib.roc\"] } }"
	SiteCode.published_source(source) == "platform \"p\" requires {} exposes [] packages { dep: \"<package release URL here>\" } provides {} targets: { linux: { inputs: [\"../lib.roc\"] } }"
}

## Transform before selecting a region that has no header context of its own.
expect {
	source = "app [main] {\n# region dependency\n pf: platform \"../platform/main.roc\"\n# endregion dependency\n}\n"
	DocSamples.region_of(SiteCode.published_source(source), "dependency") == Ok(" pf: platform \"<package release URL here>\"\n")
}
