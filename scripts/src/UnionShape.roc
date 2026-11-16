## The shape of a tag union declared in text as `Name : [ ... ]`: its
## variants, each with the record field names and tag names its payload
## holds, in order. Type names are not part of the shape, so a declaration
## that elides a field's type (`{ url, headers }`, as `design.md`'s
## Appendix A does) has the shape of one that writes it.
UnionShape := [].{

	## One variant: its tag name and the parts of its payload, each
	## `field NAME` or `tag NAME`, in the order they are written.
	Variant : { name : Str, parts : List(Str) }

	## The variants of the union `name` declared in `text`: the first
	## declaration `name : [` at the start of a line or after indentation.
	## A `#` comment runs to the end of its line and adds nothing.
	variants : Str, Str -> Try(List(UnionShape.Variant), [MissingUnion(Str), UnbalancedUnion(Str)])
	variants = |text, name| {
		bytes = text.to_utf8()
		start = UnionShape.declaration_end(bytes, "${name} : [".to_utf8()) ? |_| MissingUnion(name)
		var $i = start
		var $stack = [Square]
		var $prev = '['
		var $out = []
		while $i < bytes.len() and !$stack.is_empty() {
			b = bytes.get($i) ?? 0
			if b == '#' {
				while $i < bytes.len() and (bytes.get($i) ?? 0) != '\n' {
					$i = $i + 1
				}
			} else if b == '[' or b == '{' or b == '(' {
				$stack = $stack.append(if (b == '[') Square else if (b == '{') Curly else Paren)
				$prev = b
				$i = $i + 1
			} else if b == ']' or b == '}' or b == ')' {
				$stack = $stack.drop_last(1)
				$prev = b
				$i = $i + 1
			} else if UnionShape.word_start(b) {
				var $end = $i
				while $end < bytes.len() and UnionShape.word_byte(bytes.get($end) ?? 0) {
					$end = $end + 1
				}
				word = Str.from_utf8(bytes.sublist({ start: $i, len: $end - $i })) ?? ""
				top = $stack.last() ?? Square
				listed = $prev == '[' or $prev == ','
				if top == Square and listed and $stack.len() == 1 {
					$out = $out.append({ name: word, parts: [] })
				} else if top == Square and listed {
					$out = UnionShape.with_part($out, "tag ${word}")
				} else if top == Curly and ($prev == '{' or $prev == ',') {
					$out = UnionShape.with_part($out, "field ${word}")
				}
				$prev = 'a'
				$i = $end
			} else {
				if b != ' ' and b != '\n' and b != '\t' and b != '\r' {
					$prev = b
				}
				$i = $i + 1
			}
		}
		if ($stack.is_empty()) Ok($out) else Err(UnbalancedUnion(name))
	}

	## What differs between the union a document declares and the one the
	## source declares, one sentence each; empty when they agree.
	differences : List(UnionShape.Variant), List(UnionShape.Variant) -> List(Str)
	differences = |documented, source| {
		missing = source.keep_if(|v| !documented.any(|d| d.name == v.name)).map(|v| "${v.name} is missing")
		extra = documented.keep_if(|d| !source.any(|v| v.name == d.name)).map(|d| "${d.name} is not in the source")
		repeated = documented.keep_if(|d| documented.count_if(|o| o.name == d.name) > 1).map(|d| "${d.name} is written twice")
		parts = documented.keep_oks(
			|d| match source.find_first(|v| v.name == d.name) {
				Ok(v) if v.parts != d.parts => Ok("${d.name} has ${Str.inspect(d.parts)}, the source ${Str.inspect(v.parts)}")
				_ => Err(Same)
			},
		)
		missing.concat(extra).concat(repeated).concat(parts)
	}

	## The index just past the first `needle` that starts a line or follows
	## indentation.
	declaration_end : List(U8), List(U8) -> Try(U64, [NotFound])
	declaration_end = |bytes, needle| {
		var $i = 0
		while $i + needle.len() <= bytes.len() {
			before = if ($i == 0) '\n' else bytes.get($i - 1) ?? 0
			if (before == '\n' or before == '\t' or before == ' ') and bytes.sublist({ start: $i, len: needle.len() }) == needle {
				return Ok($i + needle.len())
			}
			$i = $i + 1
		}
		Err(NotFound)
	}

	## Whether a byte starts a name.
	word_start : U8 -> Bool
	word_start = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_'

	## Whether a byte continues a name.
	word_byte : U8 -> Bool
	word_byte = |b| UnionShape.word_start(b) or (b >= '0' and b <= '9')

	## The variants with one more part on the last.
	with_part : List(UnionShape.Variant), Str -> List(UnionShape.Variant)
	with_part = |listed, part| match listed.last() {
		Ok(last) => listed.drop_last(1).append({ ..last, parts: last.parts.append(part) })
		Err(_) => listed
	}
}

## Fields, nested tags and elided types: only names and tags are a shape.
expect {
	source =
		\\	## A doc line.
		\\	Ask : [
		\\		Get({ url : Str, headers : List((Str, Str)) }),
		\\		Work({ task : Str, refusal : [None, TooDeep] }),
		\\		# a comment with Fake(x)
		\\		Done,
		\\	]
	documented = "Ask : [Get({ url, headers }), Work({ task : Str, refusal : [None, TooDeep] }), Done]   # trailing"
	actual = UnionShape.variants(source, "Ask")
	expected = Ok([{ name: "Get", parts: ["field url", "field headers"] }, { name: "Work", parts: ["field task", "field refusal", "tag None", "tag TooDeep"] }, { name: "Done", parts: [] }])
	actual == expected and UnionShape.variants(documented, "Ask") == expected
}

## A missing variant, an extra one and a missing field are each named.
expect {
	source = UnionShape.variants("A : [X({ a, b }), Y, Z]", "A") ?? []
	documented = UnionShape.variants("A : [X({ a }), Y, W]", "A") ?? []
	UnionShape.differences(documented, source) == ["Z is missing", "W is not in the source", "X has [\"field a\"], the source [\"field a\", \"field b\"]"]
}

## A declaration is found only at the start of a line or after indentation.
expect UnionShape.variants("PortCommand : [P]\nCommand : [C]", "Command") == Ok([{ name: "C", parts: [] }])

## An unclosed declaration and a missing one are refused.
expect UnionShape.variants("A : [X(", "A") == Err(UnbalancedUnion("A")) and UnionShape.variants("B : [X]", "A") == Err(MissingUnion("A"))
