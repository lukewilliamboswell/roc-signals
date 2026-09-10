CodecProbe := [].{}

Theme := { background : Str, gap : U32 }.{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## Nominal types opt into the builtin codecs without implementing JSON grammar.
expect {
	value : Theme
	value = Json.parse("{\"background\":\"#123456\",\"gap\":8}")?
	decoded : Theme
	decoded = Json.parse(Json.to_str(value))?
	value == decoded and value.gap == 8
}

## Structural records receive codecs without nominal opt-in declarations.
expect {
	value : { background : Str, gap : U32 }
	value = Json.parse("{\"background\":\"#123456\",\"gap\":8}")?
	value == { background: "#123456", gap: 8 }
}

## Default JSON field names preserve the existing snake_case theme schema.
expect {
	value : { text_primary : Str }
	value = Json.parse("{\"text_primary\":\"#123456\"}")?
	value.text_primary == "#123456"
}

## Builtin syntax validation rejects a JSON number with a leading zero.
expect {
	value : Try({ gap : U32 }, _)
	value = Json.parse("{\"gap\":01}")
	match value {
		Err(_) => True
		Ok(_) => False
	}
}

## Characterization, NOT desired theme policy: duplicate keys are accepted.
## A migration must preserve the theme's existing duplicate-key rejection.
expect {
	value : { gap : U32 }
	value = Json.parse("{\"gap\":8,\"gap\":9}")?
	value.gap == 9
}
