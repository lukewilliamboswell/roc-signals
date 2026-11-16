## A display lexer for the documentation's Scheme-style spec snippets.
## It keeps source text intact and accepts partial snippets. It is independent
## of the platform's spec parser and never decides whether a spec is valid.
ScmHighlight := [].{
	Token : { text : Str, category : Str }

	## Preserve every UTF-8 byte while identifying comments, quoted strings,
	## atoms and delimiters. A list's first atom is its head; colon keywords
	## use the palette's type color. Incomplete strings use the invalid color.
	tokens : Str -> List(Token)
	tokens = |source| {
		bytes = source.to_utf8()
		var $at = 0
		var $head = Bool.False
		var $out = []
		while $at < bytes.len() {
			start = $at
			byte = bytes.get($at) ?? ' '
			category = if is_space(byte) {
				while $at < bytes.len() and is_space(bytes.get($at) ?? ' ') {
					$at = $at + 1
				}
				"plain"
			} else if byte == ';' {
				while $at < bytes.len() and bytes.get($at) != Ok('\r') and bytes.get($at) != Ok('\n') {
					$at = $at + 1
				}
				"comment"
			} else if byte == '"' {
				$at = $at + 1
				var $closed = Bool.False
				while $at < bytes.len() {
					next = bytes.get($at) ?? ' '
					$at = $at + 1
					if next == '\\' {
						$at = ($at + 1).min(bytes.len())
					} else if next == '"' {
						$closed = Bool.True
						break
					}
				}
				$head = Bool.False
				if ($closed) "string" else "invalid"
			} else if byte == '(' or byte == ')' or byte == '[' or byte == ']' {
				$at = $at + 1
				$head = byte == '(' or byte == '['
				"symbol"
			} else if byte == '\'' or byte == '`' or byte == ',' {
				$at = $at + 1
				if byte == ',' and bytes.get($at) == Ok('@') {
					$at = $at + 1
				}
				"symbol"
			} else {
				while $at < bytes.len() and !is_delimiter(bytes.get($at) ?? ' ') {
					$at = $at + 1
				}
				atom = Str.from_utf8_lossy(bytes.sublist({ start, len: $at - start }))
				kind = if atom.starts_with(":") {
					"type"
				} else if ["true", "false", "#t", "#f", "#T", "#F"].contains(atom) {
					"keyword"
				} else if (is_digit(byte) or byte == '+' or byte == '-' or byte == '.') and F64.from_str(atom).is_ok() {
					"number"
				} else if $head {
					"keyword"
				} else {
					"name"
				}
				$head = Bool.False
				kind
			}
			text = Str.from_utf8_lossy(bytes.sublist({ start, len: $at - start }))
			$out = $out.append({ text, category })
		}
		$out
	}
}

is_space = |byte| byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n'

is_digit = |byte| byte >= '0' and byte <= '9'

is_delimiter = |byte| is_space(byte) or ['(', ')', '[', ']', '"', ';', '\'', '`', ','].contains(byte)

expect {
	sources = ["", "; café\r\n\t(test \"😀 & <>\" :name true -12)  \n\n", "(test \"a\\\"; b\")", "(unfinished \"e\u(0301)\\", "'(a ,@items)"]
	sources.all(|source| Str.join_with(ScmHighlight.tokens(source).map(|token| token.text), "") == source)
}

expect ScmHighlight.tokens("\"a\\\"; <&>\"") == [{ text: "\"a\\\"; <&>\"", category: "string" }]

expect ScmHighlight.tokens("\"unfinished\\") == [{ text: "\"unfinished\\", category: "invalid" }]

expect {
	tokens = ScmHighlight.tokens("(test :name #t false -12 +3.5e2 atom) ; comment")
	[
		("test", "keyword"),
		(":name", "type"),
		("#t", "keyword"),
		("false", "keyword"),
		("-12", "number"),
		("+3.5e2", "number"),
		("atom", "name"),
		(")", "symbol"),
		("; comment", "comment"),
	].all(|(text, category)| tokens.contains({ text, category }))
}

## The explicit absence marker keeps its source bytes and keyword category.
expect {
	source = "(expect-absent (label \"Other\") :never-drawn)"
	tokens = ScmHighlight.tokens(source)
	{ source: Str.join_with(tokens.map(|token| token.text), ""), marker: tokens.keep_if(|token| token.text == ":never-drawn") } == { source, marker: [{ text: ":never-drawn", category: "type" }] }
}
