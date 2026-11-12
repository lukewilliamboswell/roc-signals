## A display lexer for HTML documentation samples. It preserves source text,
## including incomplete snippets, and never validates or repairs a document.
## Script and style bodies stay plain text; this lexer does not parse JavaScript
## or CSS and cannot execute the markup it describes.
HtmlHighlight := [].{
	Category : [Plain, Comment, Keyword, Name, String, Type, Symbol, Invalid]
	Token : { text : Str, category : Category }

	## Partition UTF-8 source at ASCII HTML delimiters. Tokens cover the source
	## once, without decoding entities, normalizing whitespace or changing quotes.
	## Tags and declarations use keyword color, attributes name color, attribute
	## values string color, and character references type color.
	tokens : Str -> List(Token)
	tokens = |source| {
		bytes = source.to_utf8()
		var $at = 0
		var $inside = Bool.False
		var $name = Bool.False
		var $value = Bool.False
		var $closing = Bool.False
		var $raw = ""
		var $tag_raw = ""
		var $out = []
		while $at < bytes.len() {
			start = $at
			byte = bytes.get($at) ?? ' '
			category = if !$inside and $raw != "" and !closes_raw(bytes, { at: $at, tag: $raw }) {
				while $at < bytes.len() and !closes_raw(bytes, { at: $at, tag: $raw }) {
					$at = $at + 1
				}
				Plain
			} else if !$inside and starts_at(bytes, { at: $at, text: "<!--" }) {
				$at = $at + 4
				while $at < bytes.len() and !starts_at(bytes, { at: $at, text: "-->" }) {
					$at = $at + 1
				}
				if $at < bytes.len() {
					$at = $at + 3
					Comment
				} else {
					Invalid
				}
			} else if !$inside and (starts_at(bytes, { at: $at, text: "<!" }) or starts_at(bytes, { at: $at, text: "<?" })) {
				$at = $at + 2
				var $quote = 0.U8
				var $closed = Bool.False
				while $at < bytes.len() {
					next = bytes.get($at) ?? ' '
					$at = $at + 1
					if $quote != 0 {
						if next == $quote {
							$quote = 0
						}
					} else if next == '"' or next == '\'' {
						$quote = next
					} else if next == '>' {
						$closed = Bool.True
						break
					}
				}
				if ($closed) Keyword else Invalid
			} else if !$inside and byte == '<' and (is_letter(bytes.get($at + 1) ?? 0) or (bytes.get($at + 1) == Ok('/') and is_letter(bytes.get($at + 2) ?? 0))) {
				$closing = bytes.get($at + 1) == Ok('/')
				$at = $at + if ($closing) 2 else 1
				$inside = Bool.True
				$name = Bool.True
				$value = Bool.False
				$tag_raw = ""
				$raw = ""
				Symbol
			} else if !$inside and byte == '&' {
				$at = $at + 1
				while $at < bytes.len() and is_reference_byte(bytes.get($at) ?? 0) {
					$at = $at + 1
				}
				if $at > start + 1 and bytes.get($at) == Ok(';') {
					$at = $at + 1
					Type
				} else {
					Plain
				}
			} else if !$inside {
				$at = $at + 1
				while $at < bytes.len() and bytes.get($at) != Ok('<') and bytes.get($at) != Ok('&') {
					$at = $at + 1
				}
				Plain
			} else if is_space(byte) {
				while $at < bytes.len() and is_space(bytes.get($at) ?? 0) {
					$at = $at + 1
				}
				Plain
			} else if $name {
				while $at < bytes.len() and !is_name_end(bytes.get($at) ?? 0) {
					$at = $at + 1
				}
				if ascii_equal(bytes.sublist({ start, len: $at - start }), "script") {
					$tag_raw = "script"
				} else if ascii_equal(bytes.sublist({ start, len: $at - start }), "style") {
					$tag_raw = "style"
				}
				$name = Bool.False
				Keyword
			} else if byte == '>' or starts_at(bytes, { at: $at, text: "/>" }) {
				$at = $at + if (byte == '>') 1 else 2
				$inside = Bool.False
				if byte == '>' and !$closing {
					$raw = $tag_raw
				}
				Symbol
			} else if byte == '=' {
				$at = $at + 1
				$value = Bool.True
				Symbol
			} else if $value and (byte == '"' or byte == '\'') {
				$at = $at + 1
				while $at < bytes.len() and bytes.get($at) != Ok(byte) {
					$at = $at + 1
				}
				$value = Bool.False
				if $at < bytes.len() {
					$at = $at + 1
					String
				} else {
					Invalid
				}
			} else if $value {
				$at = $at + 1
				while $at < bytes.len() and !is_space(bytes.get($at) ?? 0) and bytes.get($at) != Ok('>') {
					$at = $at + 1
				}
				$value = Bool.False
				String
			} else if is_name_end(byte) or byte == '"' or byte == '\'' {
				$at = $at + 1
				Invalid
			} else {
				$at = $at + 1
				while $at < bytes.len() and !is_name_end(bytes.get($at) ?? 0) and bytes.get($at) != Ok('"') and bytes.get($at) != Ok('\'') {
					$at = $at + 1
				}
				Name
			}
			text = match Str.from_utf8(bytes.sublist({ start, len: $at - start })) {
				Ok(decoded) => decoded
				Err(_) => crash "HtmlHighlight.tokens: an ASCII delimiter split a UTF-8 code point"
			}
			$out = $out.append({ text, category })
		}
		$out
	}
}

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 12

is_letter : U8 -> Bool
is_letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

is_reference_byte : U8 -> Bool
is_reference_byte = |byte| is_letter(byte) or (byte >= '0' and byte <= '9') or byte == '#'

is_name_end : U8 -> Bool
is_name_end = |byte| is_space(byte) or byte == '/' or byte == '>' or byte == '='

starts_at : List(U8), { at : U64, text : Str } -> Bool
starts_at = |bytes, { at, text }| bytes.sublist({ start: at, len: text.count_utf8_bytes() }) == text.to_utf8()

ascii_equal : List(U8), Str -> Bool
ascii_equal = |bytes, lower| bytes.map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte) == lower.to_utf8()

closes_raw : List(U8), { at : U64, tag : Str } -> Bool
closes_raw = |bytes, { at, tag }| {
	end = at + 2 + tag.count_utf8_bytes()
	starts_at(bytes, { at: at, text: "</" }) and ascii_equal(bytes.sublist({ start: at + 2, len: tag.count_utf8_bytes() }), tag)
		and (end == bytes.len() or is_space(bytes.get(end) ?? 0) or bytes.get(end) == Ok('>') or bytes.get(end) == Ok('/'))
}

## Tags, attributes, boolean attributes, both quote styles and bare values
## are distinct, while delimiters and character references retain their text.
expect {
	tokens = HtmlHighlight.tokens("<x-a disabled title='a>b' size=12>&amp;</x-a>")
	tokens == [
		{ text: "<", category: Symbol },
		{ text: "x-a", category: Keyword },
		{ text: " ", category: Plain },
		{ text: "disabled", category: Name },
		{ text: " ", category: Plain },
		{ text: "title", category: Name },
		{ text: "=", category: Symbol },
		{ text: "'a>b'", category: String },
		{ text: " ", category: Plain },
		{ text: "size", category: Name },
		{ text: "=", category: Symbol },
		{ text: "12", category: String },
		{ text: ">", category: Symbol },
		{ text: "&amp;", category: Type },
		{ text: "</", category: Symbol },
		{ text: "x-a", category: Keyword },
		{ text: ">", category: Symbol },
	]
}

## Arbitrary joins of complete and incomplete fragments never lose, duplicate
## or normalize a source byte, and every token advances through the source.
expect {
	fragments = ["", "<", "<!-- café\r\n", "-->", "<x-a data-note=", "\"😀 &amp; <&>\"", "'e\u(0301)'", "/>", "&#x1f600;", "</SCRIPT>", "<style>a < b", "\t  \r\n\n"]
	fragments.all(
		|left| fragments.all(
			|right| {
				source = "${left}${right}"
				tokens = HtmlHighlight.tokens(source)
				Str.join_with(tokens.map(|token| token.text), "") == source and tokens.all(|token| !token.text.is_empty())
			},
		),
	)
}

## Raw script/style bodies do not become HTML tags. A matching closing name
## is case insensitive and cannot be a prefix of a different element's name.
expect {
	script = "\"</scriptish>\"; if (a < b) x = '&amp;';"
	style = ".x::before { content: '<b>'; }"
	tokens = HtmlHighlight.tokens("<script>${script}</ScRiPt ><style>${style}</style>")
	tokens.contains({ text: script, category: Plain }) and tokens.contains({ text: style, category: Plain })
}

## Declarations honor quoted greater-than signs; an unfinished declaration,
## comment or quoted attribute stays intact and is marked incomplete.
expect {
	declaration = "<!DOCTYPE html PUBLIC \"a>b\">"
	actual = {
		declaration: HtmlHighlight.tokens(declaration),
		comment: HtmlHighlight.tokens("<!-- café"),
		declaration_end: HtmlHighlight.tokens("<!doctype"),
		attribute_end: HtmlHighlight.tokens("<p title=\"e\u(0301)").last()?,
	}
	expected = {
		declaration: [{ text: declaration, category: Keyword }],
		comment: [{ text: "<!-- café", category: Invalid }],
		declaration_end: [{ text: "<!doctype", category: Invalid }],
		attribute_end: { text: "\"e\u(0301)", category: Invalid },
	}
	actual == expected
}
