app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Markdown

## Copied HTML accepts Markdown but never raw markup. Arbitrary byte picks make
## valid Unicode documents from syntax, URL and injection fragments. The oracle
## recognizes only the serializer's closed HTML vocabulary and quoted href/src
## attributes. Every other less-than byte, including one inside an attribute,
## must have been escaped. It knows no parser blocks or serializer helpers.
Input : List(U8)

fragments : List(Str)
fragments = ["plain", "<script>alert(1)</script>", "<img onerror=x>", "&lt;", "&", "\"", "'", "<", ">", "# ", "## ", "###### ", "**", "`", "```\n", "\n", "\n\n", "- ", "  - ", "> ", "[", "](https://x/", "](javascript:", "](mailto:", ")", "![", "é", "🦊", "\" onmouseover=\"bad", "<&>\"'", "![alt](https://x/\"<)", "<strong>untrusted</strong>"]

document : Input -> Str
document = |picks| Str.join_with(picks.map(|pick| fragments.get(pick.to_u64() % fragments.len()) ?? crash "fuzz-html.document: modulo index is in range"), "")

## Attribute values contain neither literal markup nor a quote that can end the
## one quoted value. Entities such as &quot; are text, not delimiters.
is_attribute_text : Str -> Bool
is_attribute_text = |value| !value.contains("<") and !value.contains(">") and !value.contains("\"")

is_tag : Str -> Bool
is_tag = |tag| {
	if ["h1", "/h1", "h2", "/h2", "h3", "/h3", "h4", "/h4", "h5", "/h5", "h6", "/h6", "p", "/p", "blockquote", "/blockquote", "pre", "/pre", "code", "/code", "ul", "/ul", "li", "/li", "strong", "/strong", "/a"].contains(tag) {
		return True
	}
	if tag.starts_with("a href=\"") and tag.ends_with("\"") {
		return is_attribute_text(tag.drop_prefix("a href=\"").drop_suffix("\""))
	}
	if tag.starts_with("img src=\"") and tag.ends_with("\"") {
		values = tag.drop_prefix("img src=\"").drop_suffix("\"").split_on("\" alt=\"")
		return match values {
			[src, alt] => is_attribute_text(src) and is_attribute_text(alt)
			_ => False
		}
	}
	False
}

check : Input -> Try({}, [UnterminatedMarkup(Str), UnescapedMarkup({ source : Str, html : Str }), UnmatchedDelimiter(Str), InvalidEscapeModel, LiteralChanged({ source : Str, html : Str })])
check = |input| {
	source = document(input)
	html = Markdown.to_html(source)
	parts = html.split_on("<")
	for part in parts.drop_first(1) {
		end = part.split_first(">") ? |_| UnterminatedMarkup(html)
		if !is_tag(end.before) or end.after.contains(">") {
			return Err(UnescapedMarkup({ source, html }))
		}
	}
	if (parts.first() ?? "").contains(">") {
		return Err(UnmatchedDelimiter(html))
	}
	# A fenced document is literal regardless of its text. This separate byte
	# model requires every original markup byte to survive as its entity, even
	# when it happens to spell one of the legitimate output tags above.
	literal = Str.join_with(source.split_on("```"), "``")
	expected_bytes = literal.to_utf8().fold(
		[],
		|out, byte| out.concat(
			match byte {
				'&' => "&amp;".to_utf8()
				'<' => "&lt;".to_utf8()
				'>' => "&gt;".to_utf8()
				'"' => "&quot;".to_utf8()
				'\'' => "&#39;".to_utf8()
				_ => [byte]
			},
		),
	)
	expected = Str.from_utf8(expected_bytes) ? |_| InvalidEscapeModel
	actual = Markdown.to_html("```\n${literal}\n```")
	if actual != "<pre><code>${expected}</code></pre>" {
		return Err(LiteralChanged({ source: literal, html: actual }))
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash Str.inspect(problem)
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "markdown-html",
	examples: [
		ex("raw-markup", [1, 16, 2, 16, 29, 31]),
		ex("heading-and-emphasis", [9, 26, 12, 7, 12, 16, 0]),
		ex("attribute-breakout", [20, 28, 21, 28, 24, 16, 30]),
		ex("unsafe-scheme", [20, 0, 22, 0, 24]),
		ex("fenced-markup", [14, 1, 15, 29, 15, 14]),
		ex("lists-and-unicode", [17, 27, 15, 18, 26, 16, 19, 2]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 80),
	test!,
	show: Str.inspect,
})
