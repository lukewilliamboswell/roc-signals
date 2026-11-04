## Just enough JSON output for the spec tooling: the spec-result lines and the
## steps `--emit-steps` hands to the browser runner. Values are built as a
## small tree and rendered once, so every string goes through one escaper.
JsonOut := [].{
	Value := [Null, Bool(Bool), Int(I64), Nat(U64), Text(Str), Array(List(Value)), Object(List({ key : Str, value : Value }))]

	## A JSON string literal for `text`, quotes included. Control characters,
	## quotes and backslashes are escaped; everything else is written as UTF-8.
	quote : Str -> Str
	quote = |text| {
		var $out = List.with_capacity(text.to_utf8().len() + 2)
		$out = $out.append('"')
		for b in text.to_utf8() {
			$out = if b == '"' {
				$out.concat(['\\', '"'])
			} else if b == '\\' {
				$out.concat(['\\', '\\'])
			} else if b == '\n' {
				$out.concat(['\\', 'n'])
			} else if b == '\r' {
				$out.concat(['\\', 'r'])
			} else if b == '\t' {
				$out.concat(['\\', 't'])
			} else if b < 0x20 {
				$out.concat(['\\', 'u', '0', '0', JsonOut.hex_digit(b // 16), JsonOut.hex_digit(b % 16)])
			} else {
				$out.append(b)
			}
		}
		$out = $out.append('"')
		Str.from_utf8($out) ?? crash "JsonOut.quote produced invalid UTF-8 from valid UTF-8"
	}

	hex_digit : U8 -> U8
	hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

	## Render a value on one line, with no insignificant whitespace.
	render : Value -> Str
	render = |value|
		match value {
			Null => "null"
			Bool(b) => if (b) "true" else "false"
			Int(n) => n.to_str()
			Nat(n) => n.to_str()
			Text(s) => JsonOut.quote(s)
			Array(items) => "[${Str.join_with(items.map(JsonOut.render), ",")}]"
			Object(fields) => "{${Str.join_with(fields.map(|{ key, value: v }| "${JsonOut.quote(key)}:${JsonOut.render(v)}"), ",")}}"
		}

	## A field of an object.
	field : Str, Value -> { key : Str, value : Value }
	field = |key, value| { key, value }
}

## Quotes, backslashes and control characters are escaped.
expect JsonOut.quote("a\"b\\c\nd\u(1)") == "\"a\\\"b\\\\c\\nd\\u0001\""

## Non-ASCII text passes through as UTF-8.
expect JsonOut.quote("λ — ok") == "\"λ — ok\""

## Objects keep field order; nested arrays render compactly.
expect {
	actual = JsonOut.render(Object([JsonOut.field("a", Nat(1)), JsonOut.field("b", Array([Bool(True), Null, Int(-2)])), JsonOut.field("c", Text("x"))]))
	actual == "{\"a\":1,\"b\":[true,null,-2],\"c\":\"x\"}"
}
