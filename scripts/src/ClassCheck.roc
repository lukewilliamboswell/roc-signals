import parser.RocSyntax
import SourceText
import cli.Path
import SpecSuite
import Proc

## Build-time checking of example class literals against the stylesheet that
## Tailwind actually emitted. Roc's parser identifies class argument positions;
## a CSS selector reader decodes their names without treating declarations,
## comments, quoted values or at-rule preludes as selectors.
ClassCheck := [].{

	## A complete static class token and the original source line that wrote it.
	Use : { name : Str, line : U64 }

	## One decoded byte with its original source offset. Escape decoding must
	## not move diagnostics onto a different source line.
	Point : SourceText.Point

	## Check only examples, after Tailwind, without adding a stylesheet input
	## to application compilation. Every missing class names its source line.
	run! : Str => Try({}, _)
	run! = |root| {
		css = Path.read_utf8!(Path.utf8("${root}/www/static/signals.css"))?
		known = ClassCheck.selectors(css)
		var $problems = []
		var $literals = 0
		var $tokens = 0
		for path in SpecSuite.files_under!("${root}/examples", ".roc")? {
			source = Path.read_utf8!(Path.utf8(path))?
			scanned = ClassCheck.analyze(source) ? |line| InvalidClassSource("${path}:${line.to_str()}: cannot parse Roc class positions")
			$literals = $literals + scanned.literals
			$tokens = $tokens + scanned.uses.len()
			for use in ClassCheck.missing(known, scanned.uses) {
				$problems = $problems.append("${path.drop_prefix("${root}/")}:${use.line.to_str()}: ${Str.inspect(use.name)} is not a class of www/static/signals.css")
			}
		}
		if !$problems.is_empty() {
			for problem in $problems {
				Proc.warn!(problem)
			}
			return Err(UndefinedClasses)
		}
		Proc.note!("classes: checked ${$literals.to_str()} class literals (${$tokens.to_str()} tokens) against ${known.len().to_str()} generated selectors")
		Ok({})
	}

	## Keep each unresolved use, including its original source line.
	missing : Dict(Str, {}), List(Use) -> List(Use)
	missing = |known, references| references.keep_if(|use| known.get(use.name).is_err())

	## Class names are CSS identifiers in qualified-rule preludes. Grouping
	## at-rules recurse into rules; declaration blocks never contribute names.
	selectors : Str -> Dict(Str, {})
	selectors = |css| {
		bytes = css.to_utf8()
		var $at = 0
		var $contexts = [Rules]
		var $first = True
		var $at_rule = False
		var $rule_name = ""
		var $names = Dict.empty()
		while $at < bytes.len() {
			b = bytes.get($at) ?? 0
			if b == '/' and bytes.get($at + 1) == Ok('*') {
				$at = ClassCheck.comment_end(bytes, $at + 2)
			} else if b == '"' or b == '\'' {
				$at = ClassCheck.quoted_end(bytes, $at + 1, b)
				$first = False
			} else if b == '}' {
				$contexts = $contexts.drop_last(1)
				$first = True
				$at_rule = False
				$at = $at + 1
			} else if b == '{' {
				kind = if ($contexts.last() ?? Rules) == Declarations or !$at_rule or ["font-face", "page", "property", "counter-style", "font-palette-values"].contains($rule_name) {
					Declarations
				} else {
					Rules
				}
				$contexts = $contexts.append(kind)
				$first = True
				$at_rule = False
				$at = $at + 1
			} else if ($contexts.last() ?? Rules) == Rules {
				if b == ';' {
					$first = True
					$at_rule = False
					$at = $at + 1
				} else if $first and b == '@' {
					(name, end) = ClassCheck.identifier(bytes, $at + 1)
					$rule_name = name
					$at_rule = True
					$first = False
					$at = end
				} else if b == '.' and !$at_rule and ClassCheck.is_name_start(bytes, $at + 1) {
					(name, end) = ClassCheck.identifier(bytes, $at + 1)
					$names = $names.insert(name, {})
					$first = False
					$at = end
				} else {
					if !ClassCheck.is_space(b) {
						$first = False
					}
					$at = $at + 1
				}
			} else {
				$at = $at + 1
			}
		}
		$names
	}

	## Skip a CSS comment through its closing delimiter. Tailwind supplies the
	## stylesheet; an unterminated trailing comment contributes no selectors.
	comment_end : List(U8), U64 -> U64
	comment_end = |bytes, start| {
		var $at = start
		while $at < bytes.len() {
			if bytes.get($at) == Ok('*') and bytes.get($at + 1) == Ok('/') {
				return $at + 2
			}
			$at = $at + 1
		}
		$at
	}

	## Skip a CSS quoted value, honoring escaped delimiters so periods inside
	## attribute values and declaration strings cannot invent class names.
	quoted_end : List(U8), U64, U8 -> U64
	quoted_end = |bytes, start, quote| {
		var $at = start
		while $at < bytes.len() {
			b = bytes.get($at) ?? 0
			$at = $at + 1
			if b == '\\' {
				$at = ($at + 1).min(bytes.len())
			} else if b == quote {
				break
			}
		}
		$at
	}

	## HTML class-token whitespace is ASCII TAB, LF, FF, CR or space. Other
	## Unicode spaces remain part of a class name.
	is_space : U8 -> Bool
	is_space = |b| [9, 10, 12, 13, 32].contains(b)

	## The unescaped continuation bytes admitted by a CSS identifier. UTF-8
	## bytes pass through together; backslash escapes are handled by identifier.
	is_name_byte : U8 -> Bool
	is_name_byte = |b| b >= 128 or b == '_' or b == '-' or (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')

	## Recognize a CSS identifier after a selector dot, including escaped
	## digits and a valid leading hyphen. Numeric declaration values are excluded.
	is_name_start : List(U8), U64 -> Bool
	is_name_start = |bytes, at| {
		b = bytes.get(at) ?? 0
		b == '\\' or b >= 128 or b == '_' or (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b == '-' and (bytes.get(at + 1) == Ok('-') or bytes.get(at + 1) == Ok('\\') or ClassCheck.is_initial_name_byte(bytes.get(at + 1) ?? 0)))
	}

	## The unescaped first byte after a leading hyphen. A digit requires
	## a CSS escape rather than starting an ordinary class identifier.
	is_initial_name_byte : U8 -> Bool
	is_initial_name_byte = |b| b >= 128 or b == '_' or (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	## CSS escapes use up to six hexadecimal digits and one optional CSS
	## whitespace character. Invalid escaped scalar values become U+FFFD.
	identifier : List(U8), U64 -> (Str, U64)
	identifier = |bytes, start| {
		var $at = start
		var $name = []
		while $at < bytes.len() {
			b = bytes.get($at) ?? 0
			if b == '\\' {
				$at = $at + 1
				var $value = 0.U32
				var $digits = 0
				while $digits < 6 and $at < bytes.len() {
					match SourceText.hex(bytes.get($at) ?? 0) {
						Ok(digit) => {
							$value = $value * 16 + digit
							$digits = $digits + 1
							$at = $at + 1
						}
						Err(_) => break
					}
				}
				if $digits > 0 {
					scalar = if $value == 0 or $value > 0x10FFFF or ($value >= 0xD800 and $value <= 0xDFFF) {
						0xFFFD
					} else $value
					$name = $name.concat(SourceText.utf8(scalar))
					if ClassCheck.is_space(bytes.get($at) ?? 0) {
						cr = bytes.get($at) == Ok(13)
						$at = $at + 1
						if cr and bytes.get($at) == Ok(10) {
							$at = $at + 1
						}
					}
				} else if $at < bytes.len() and ![10, 12, 13].contains(bytes.get($at) ?? 0) {
					$name = $name.append(bytes.get($at) ?? 0)
					$at = $at + 1
				} else {
					break
				}
			} else if ClassCheck.is_name_byte(b) {
				$name = $name.append(b)
				$at = $at + 1
			} else {
				break
			}
		}
		(Str.from_utf8_lossy($name), $at)
	}

	## Resolve the syntax node’s direct children. Only call arguments and
	## literal segments are walked, never a second source-text grammar.
	children : RocSyntax.Parsed, RocSyntax.Node -> List(RocSyntax.Node)
	children = |parsed, node| parsed.children.sublist({ start: node.children_start, len: node.children_len }).keep_oks(|index| parsed.nodes.get(index))

	## Read an exact spelling from a node’s source span, without normalizing
	## whitespace, quotes or interpolation bytes.
	text : RocSyntax.Parsed, RocSyntax.Node -> Str
	text = |parsed, node| Str.from_utf8_lossy(parsed.source.sublist({ start: node.start, len: node.end - node.start }))

	## Read a qualified call target, allowing redundant parentheses. Dynamic
	## callees return no name and cannot be mistaken for a checked constructor.
	function_name : RocSyntax.Parsed, RocSyntax.Node -> Str
	function_name = |parsed, node| match node.kind {
		Identifier => ClassCheck.text(parsed, node)
		FieldAccess => Str.join_with(ClassCheck.children(parsed, node).map(|child| ClassCheck.function_name(parsed, child)), ".")
		Parenthesized => ClassCheck.children(parsed, node).first().map_ok(|child| ClassCheck.function_name(parsed, child)) ?? ""
		_ => ""
	}

	## Only literal arguments at documented class positions are inspected.
	## An interpolation's adjacent partial word is dynamic; complete static
	## words on either side still require stylesheet definitions.
	uses : Str -> Try(List(Use), U64)
	uses = |source| ClassCheck.analyze(source).map_ok(|scanned| scanned.uses)

	## Parse every example before counting literals, retaining byte-to-line
	## positions once for diagnostics. A syntax diagnostic fails the check.
	analyze : Str -> Try({ uses : List(Use), literals : U64 }, U64)
	analyze = |source| {
		parsed = RocSyntax.parse_str(source)
		var $line = 1.U64
		var $lines = []
		for b in parsed.source {
			$lines = $lines.append($line)
			if b == 10 {
				$line = $line + 1
			}
		}
		$lines = $lines.append($line)
		if !parsed.diagnostics.is_empty() {
			return Err($lines.get((parsed.diagnostics.first() ?? crash "has diagnostics").start) ?? 1)
		}
		var $uses = []
		var $literals = 0
		for call in parsed.nodes.keep_if(|node| node.kind == Call) {
			match ClassCheck.class_literal(parsed, call) {
				Ok(literal) => {
					$literals = $literals + 1
					$uses = $uses.concat(ClassCheck.literal_uses(parsed, literal, $lines))
				}
				Err(_) => {}
			}
		}
		Ok({ uses: $uses, literals: $literals })
	}

	## Select the literal at each supported constructor’s class argument.
	## A dynamic expression remains outside the static class check.
	class_literal : RocSyntax.Parsed, RocSyntax.Node -> Try(RocSyntax.Node, [NotClassLiteral])
	class_literal = |parsed, call| {
		args = ClassCheck.children(parsed, call)
		function = args.first() ?? return Err(NotClassLiteral)
		position = match ClassCheck.function_name(parsed, function) {
			"Engine.class" | "Html.div" => 1
			"Html.p" | "Html.h1" | "Html.h2" | "Html.h3" | "Html.section" | "Html.section_s" => 2
			"Html.icon_button" => 3
			_ => return Err(NotClassLiteral)
		}
		var $literal = args.get(position) ?? return Err(NotClassLiteral)
		while $literal.kind == Parenthesized {
			$literal = ClassCheck.children(parsed, $literal).first() ?? return Err(NotClassLiteral)
		}
		if $literal.kind != StringLiteral and $literal.kind != MultilineStringLiteral {
			return Err(NotClassLiteral)
		}
		Ok($literal)
	}

	## Extract complete static tokens around interpolation holes. Multiline
	## segments keep raw backslashes and their implicit line boundary.
	literal_uses : RocSyntax.Parsed, RocSyntax.Node, List(U64) -> List(Use)
	literal_uses = |parsed, literal, lines| {
		parts = ClassCheck.children(parsed, literal)
		var $uses = []
		for (index, part) in parts.map_with_index(|part, index| (index, part)) {
			if part.kind == StringSegment {
				bytes = parsed.source.sublist({ start: part.start, len: part.end - part.start })
				points = if literal.kind == MultilineStringLiteral {
					bytes.map_with_index(|byte, offset| { byte, at: part.start + offset })
				} else {
					SourceText.quoted(bytes, part.start)
				}
				previous = if (index == 0) part else parts.get(index - 1) ?? part
				next = parts.get(index + 1) ?? part
				left = previous.kind != Interpolation or (literal.kind == MultilineStringLiteral and lines.get(part.start) != lines.get(previous.end))
				right = next.kind != Interpolation or (literal.kind == MultilineStringLiteral and lines.get(part.end) != lines.get(next.start))
				$uses = $uses.concat(ClassCheck.words(points, { left, right }, lines))
			}
		}
		$uses
	}

	## Split complete class words using HTML whitespace and retain their
	## source line. A partial word adjacent to a dynamic hole is not static.
	words : List(Point), { left : Bool, right : Bool }, List(U64) -> List(Use)
	words = |points, complete, lines| {
		var $at = 0
		var $out = []
		while $at < points.len() {
			if ClassCheck.is_space((points.get($at) ?? crash "within points").byte) {
				$at = $at + 1
			} else {
				start = $at
				while $at < points.len() and !ClassCheck.is_space((points.get($at) ?? crash "within points").byte) {
					$at = $at + 1
				}
				if (start > 0 or complete.left) and ($at < points.len() or complete.right) {
					word = points.sublist({ start, len: $at - start })
					first = word.first() ?? crash "word is nonempty"
					$out = $out.append({ name: Str.from_utf8_lossy(word.map(|p| p.byte)), line: lines.get(first.at) ?? 1 })
				}
			}
		}
		$out
	}
}

## CSS selector names decode every escape spelling, including supplementary
## Unicode and the replacement character required for invalid scalar values.
expect {
	cases = [
		(".hover\\:bg-red-50:hover{}", "hover:bg-red-50"),
		(".foo\\2c bar{}", "foo,bar"),
		(".\\0000e9clair{}", "éclair"),
		(".\\e9\r\nclair{}", "éclair"),
		(".\\1f600 {}", "😀"),
		(".w-1\\/2{}", "w-1/2"),
		(".bg-\\[\\#fff\\]{}", "bg-[#fff]"),
		(".foo\\.bar{}", "foo.bar"),
		(".\\0 {}", "\u(fffd)"),
		(".\\d800 {}", "\u(fffd)"),
		(".\\110000 {}", "\u(fffd)"),
	]
	cases.all(
		|(css, name)| {
			names = ClassCheck.selectors(css)
			names.len() == 1 and names.get(name).is_ok()
		},
	)
}

## Declaration values, quoted attributes, comments and at-rule preludes
## cannot invent classes. Grouping rule bodies still contain real selectors.
expect {
	css = "/* .comment */ @import url(\"fake.css\"); @supports selector(.condition) { .actual[data-name=\".attribute\"]:hover { content: '.value'; background: url(x.fake); --custom: { .nested }; } } @media (min-resolution: 1.5dppx) { .other { opacity: .5 } } @font-face { src: url(font.woff); font-family: '.font'; }"
	names = ClassCheck.selectors(css)
	names.len() == 2 and names.get("actual").is_ok() and names.get("other").is_ok()
}

## The parser selects actual class arguments, never text content, comments,
## other attributes, function names inside strings or dynamic producers.
expect {
	source = "value = Html.div(\"outer\", [Html.p(\"prose is not a class\", \"small\"), Html.h1(\"heading\", \"title\"), Html.h2(\"heading\", \"title\"), Html.h3(\"heading\", \"title\"), Html.section(\"Region\", \"region\", []), Html.section_s(name, \"region\", []), Html.icon_button(\"↑\", name, \"button\", handler), Engine.class((\"direct\")), Engine.class(producer()), Engine.attr(\"title\", \"not-a-class\"), Engine.text(\"Engine.class(\\\"fake\\\")\")])\n# Engine.class(\"comment\")\n"
	uses = ClassCheck.uses(source)?
	uses.map(|use| use.name).sort_with(|a, b| SpecSuite.compare_str(a, b)) == ["button", "direct", "outer", "region", "region", "small", "title", "title", "title"]
}

## Interpolation preserves complete static words, including escaped Unicode
## and all class-attribute whitespace, but does not pretend partial names
## adjacent to dynamic text are fixed classes.
expect {
	source = "value = Engine.class(\"bg-\${color}-500\\ttext-sm \${extra} font-bold\\n\\u(00e9)clair\\u(000c)end\")\n"
	ClassCheck.uses(source)?.map(|use| use.name) == ["text-sm", "font-bold", "éclair", "end"]
}

## Source lines refer to original bytes even when decoded escapes change
## lengths or create whitespace. Malformed Roc is refused rather than skipped.
expect {
	uses = ClassCheck.uses("# café\nvalue = Html.div(\n  \"ok\\nmissing\",\n  [],\n)\n")?
	uses == [{ name: "ok", line: 3 }, { name: "missing", line: 3 }] and ClassCheck.uses("value = Engine.class(\"unfinished").is_err()
}

## Missing words are diagnosed after CSS and Roc escape decoding agree.
## Literal NUL is not CSS's replacement character, and non-ASCII spaces
## remain part of a class name under HTML's class-token whitespace rules.
expect {
	known = ClassCheck.selectors(".hover\\:red{} .\\e9 clair{} .x\\a0 y{} .\\0 {}")
	uses = ClassCheck.uses("# heading\nvalue = Engine.class(\"hover:red \\u(00e9)clair x\\u(00a0)y missing \\u(0000)\")\n")?
	ClassCheck.missing(known, uses) == [{ name: "missing", line: 2 }, { name: "\u(0000)", line: 2 }]
}

## A multiline literal contributes an implicit newline between lines, so a
## complete static word after an interpolation on the previous line is checked.
expect {
	source = "value = Engine.class(\n  \\\\head \${dynamic}\n  \\\\tail\n)\n"
	ClassCheck.uses(source)?.map(|use| use.name) == ["head", "tail"]
}

## Multiline strings preserve literal backslashes. A spelling that looks
## like a quoted-string escape remains one class word, not a newline.
expect {
	source = "value = Engine.class(\n  \\\\literal\\nname\n)\n"
	ClassCheck.uses(source)? == [{ name: "literal\\nname", line: 2 }]
}
