JsonState := [Input(Str)]

JsonEncodeState := { output : List(U8), container_commas : List(Bool) }

JsonEncoding :: [Default, CamelCase, TrailingCommas].{
	rename_field : JsonEncoding, Str -> Str
	rename_field = |encoding, name|
		match encoding {
			Default => name
			CamelCase => snake_to_camel(name)
			TrailingCommas => name
		}

	allows_trailing_commas : JsonEncoding -> Bool
	allows_trailing_commas = |encoding|
		match encoding {
			Default => False
			CamelCase => False
			TrailingCommas => True
		}

	parse_str : JsonEncoding, JsonState -> Try({ value : Str, rest : JsonState }, Json)
	parse_str = |_, state|
		match state {
			Input(raw) => {
				trimmed = Str.trim_start(raw)
				if Str.starts_with(trimmed, "\"") {
					string_parts = split_json_string_tail(Str.drop_prefix(trimmed, "\""))?
					rest = Str.trim_start(string_parts.after)
					Ok({ value: string_parts.value, rest: JsonState.Input(rest) })
				} else {
					Err(invalid_json)
				}
			}
		}

	parse_bool : JsonEncoding, JsonState -> Try({ value : Bool, rest : JsonState }, Json)
	parse_bool = |_, state|
		match state {
			Input(raw) => parse_json_bool(raw)
		}

	parse_u64 : JsonEncoding, JsonState -> Try({ value : U64, rest : JsonState }, Json)
	parse_u64 = |_, state|
		match state {
			Input(raw) => parse_json_u64(raw)
		}

	parse_null : JsonEncoding, JsonState -> Try(JsonState, Json)
	parse_null = |_, state|
		match state {
			Input(raw) => parse_json_null(raw)
		}

	parse_array_start : JsonEncoding, JsonState -> Try(JsonState, Json)
	parse_array_start = |_, state|
		match state {
			Input(raw) => {
				trimmed = Str.trim_start(raw)
				if Str.starts_with(trimmed, "[") {
					Ok(JsonState.Input(Str.trim_start(Str.drop_prefix(trimmed, "["))))
				} else {
					Err(invalid_json)
				}
			}
		}

	parse_array_next : JsonEncoding, JsonState -> Try([Element(JsonState), Done(JsonState)], Json)
	parse_array_next = |_, state|
		match state {
			Input(raw) => {
				trimmed = Str.trim_start(raw)
				if Str.starts_with(trimmed, "]") {
					Ok(Done(JsonState.Input(Str.trim_start(Str.drop_prefix(trimmed, "]")))))
				} else {
					Ok(Element(JsonState.Input(trimmed)))
				}
			}
		}

	parse_array_after_element : JsonEncoding, JsonState -> Try([Continue(JsonState), Done(JsonState)], Json)
	parse_array_after_element = |encoding, state|
		match state {
			Input(raw) => parse_array_after_element_from_json(encoding, raw)
		}

	parse_record_field : JsonEncoding,
	Str.FieldName.FieldNames(_shape),
	JsonState -> Try(
		[
			Field({ field : Str.FieldName(_shape), rest : JsonState }),
			TryField({ name : Str, rest : JsonState }),
			TryFieldCaseless({ name : Str, rest : JsonState }),
			Continue({ rest : JsonState }),
			Done({ rest : JsonState }),
		],
		Json,
	)
	parse_record_field = |encoding, _, state|
		match state {
			Input(raw) => parse_record_field_from_object(encoding, raw)
		}

	skip_record_field : JsonEncoding, JsonState -> Try(JsonState, Json)
	skip_record_field = |encoding, state| skip_json_value(encoding, state)

	missing_record_field : JsonEncoding, Str, JsonState -> Json
	missing_record_field = |_, _, _| Json.MissingRequired

	missing_optional_field : JsonEncoding, Str, JsonState -> [Missing]
	missing_optional_field = |_, _, _| Missing

	parse_tag_union : JsonEncoding, ParseTagUnionSpec(a), JsonState -> Try({ value : a, rest : JsonState }, Json)
	parse_tag_union = |encoding, spec, state|
		match state {
			Input(value) => parse_tag_union_from_json(value, encoding, spec)
		}

	begin_record : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	begin_record = |state|
		Ok({ output: List.append(state.output, 123), container_commas: List.append(state.container_commas, False) })

	encode_record_field : Str, JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_record_field = |field, state| {
		with_comma = if container_needs_comma(state) {
			List.append(state.output, 44)
		} else {
			state.output
		}
		output = List.append(append_json_quoted_string(with_comma, field), 58)
		Ok({ output, container_commas: mark_container_has_item(state.container_commas) })
	}

	end_record : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	end_record = |state| Ok({ output: List.append(state.output, 125), container_commas: List.drop_last(state.container_commas, 1) })

	begin_array : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	begin_array = |state| Ok({ output: List.append(state.output, 91), container_commas: List.append(state.container_commas, False) })

	encode_array_element : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_array_element = |state| {
		output = if container_needs_comma(state) {
			List.append(state.output, 44)
		} else {
			state.output
		}
		Ok({ output, container_commas: mark_container_has_item(state.container_commas) })
	}

	end_array : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	end_array = |state| Ok({ output: List.append(state.output, 93), container_commas: List.drop_last(state.container_commas, 1) })

	encode_str : Str, JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_str = |value, state| Ok({ output: append_json_quoted_string(state.output, value), container_commas: state.container_commas })

	encode_bool : Bool, JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_bool = |value, state| Ok({ output: append_json_string_bytes(state.output, if value "true" else "false"), container_commas: state.container_commas })

	encode_u64 : U64, JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_u64 = |value, state| Ok({ output: append_json_string_bytes(state.output, value.to_str()), container_commas: state.container_commas })

	encode_null : JsonEncodeState -> Try(JsonEncodeState, _never_fails)
	encode_null = |state| Ok({ output: append_json_string_bytes(state.output, "null"), container_commas: state.container_commas })
}

Json := [MissingRequired, InvalidJson].{
	Token := { raw : Str }.{
		parser_for : JsonEncoding -> (JsonState -> Try({ value : Token, rest : JsonState }, Json))
		parser_for = |encoding| |state| {
			parsed = JsonEncoding.parse_str(encoding, state)?
			Ok({ value: { raw: parsed.value }, rest: parsed.rest })
		}

		encode_to : Token, JsonEncoding -> (JsonEncodeState -> Try(JsonEncodeState, _never_fails))
		encode_to = |token, _| |state| JsonEncoding.encode_str(token.raw, state)

		count_utf8_bytes : Token -> U64
		count_utf8_bytes = |token| Str.count_utf8_bytes(token.raw)
	}

	parse : Str -> Try(a, Json)
		where [
			a.parser_for : JsonEncoding -> (JsonState -> Try({ value : a, rest : JsonState }, Json)),
		]
	parse = |json| parse_with(JsonEncoding.Default, json)

	parse_trailing_commas : Str -> Try(a, Json)
		where [
			a.parser_for : JsonEncoding -> (JsonState -> Try({ value : a, rest : JsonState }, Json)),
		]
	parse_trailing_commas = |json| parse_with(JsonEncoding.TrailingCommas, json)

	parser_camel : {} -> (Str -> Try(a, Json))
		where [
			a.parser_for : JsonEncoding -> (JsonState -> Try({ value : a, rest : JsonState }, Json)),
		]
	parser_camel = |_| |json| parse_with(JsonEncoding.CamelCase, json)

	encode : value -> Try(Str, err)
		where [
			value.encode_to : value, JsonEncoding -> (JsonEncodeState -> Try(JsonEncodeState, err)),
		]
	encode = |value| {
		encode_value = value.encode_to(JsonEncoding.Default)
		encoded = encode_value({ output: [], container_commas: [] })?
		match Str.from_utf8(encoded.output) {
			Ok(text) => Ok(text)
			Err(_) => {
				crash "json encoder produced invalid UTF-8"
			}
		}
	}
}

parse_with : JsonEncoding, Str -> Try(a, Json)
	where [
		a.parser_for : JsonEncoding -> (JsonState -> Try({ value : a, rest : JsonState }, Json)),
	]
parse_with = |encoding, json| {
	Shape : a
	parse_shape = Shape.parser_for(encoding)
	parsed = parse_shape(JsonState.Input(json))?

	match parsed.rest {
		Input(rest) =>
			if Str.is_empty(Str.trim_start(rest)) {
				Ok(parsed.value)
			} else {
				Err(invalid_json)
			}
		}
}

invalid_json : Json
invalid_json = Json.InvalidJson

parse_json_bool : Str -> Try({ value : Bool, rest : JsonState }, Json)
parse_json_bool = |raw| {
	trimmed = Str.trim_start(raw)
	parts = split_json_scalar_tail(trimmed)?
	if Str.is_eq(parts.value, "true") {
		Ok({ value: True, rest: JsonState.Input(Str.trim_start(parts.after)) })
	} else if Str.is_eq(parts.value, "false") {
		Ok({ value: False, rest: JsonState.Input(Str.trim_start(parts.after)) })
	} else {
		Err(invalid_json)
	}
}

parse_json_null : Str -> Try(JsonState, Json)
parse_json_null = |raw| {
	trimmed = Str.trim_start(raw)
	parts = split_json_scalar_tail(trimmed)?
	if Str.is_eq(parts.value, "null") {
		Ok(JsonState.Input(Str.trim_start(parts.after)))
	} else {
		Err(invalid_json)
	}
}

parse_json_u64 : Str -> Try({ value : U64, rest : JsonState }, Json)
parse_json_u64 = |raw| {
	trimmed = Str.trim_start(raw)
	parts = split_json_scalar_tail(trimmed)?
	if is_json_unsigned_int_literal(parts.value) {
		match U64.from_str(parts.value) {
			Ok(value) => Ok({ value, rest: JsonState.Input(Str.trim_start(parts.after)) })
			Err(_) => Err(invalid_json)
		}
	} else {
		Err(invalid_json)
	}
}

parse_array_after_element_from_json : JsonEncoding, Str -> Try([Continue(JsonState), Done(JsonState)], Json)
parse_array_after_element_from_json = |encoding, raw| {
	trimmed = Str.trim_start(raw)
	if Str.starts_with(trimmed, "]") {
		Ok(Done(JsonState.Input(Str.trim_start(Str.drop_prefix(trimmed, "]")))))
	} else if Str.starts_with(trimmed, ",") {
		after_comma = Str.trim_start(Str.drop_prefix(trimmed, ","))
		if Str.starts_with(after_comma, "]") {
			if JsonEncoding.allows_trailing_commas(encoding) {
				Ok(Done(JsonState.Input(Str.trim_start(Str.drop_prefix(after_comma, "]")))))
			} else {
				Err(invalid_json)
			}
		} else {
			Ok(Continue(JsonState.Input(after_comma)))
		}
	} else {
		Err(invalid_json)
	}
}

parse_record_field_from_object : JsonEncoding,
Str -> Try(
	[
		Field({ field : Str.FieldName(_shape), rest : JsonState }),
		TryField({ name : Str, rest : JsonState }),
		TryFieldCaseless({ name : Str, rest : JsonState }),
		Continue({ rest : JsonState }),
		Done({ rest : JsonState }),
	],
	Json,
)
parse_record_field_from_object = |encoding, raw| {
	remaining = Str.trim_start(raw)
	if Str.starts_with(remaining, "{") {
		parse_record_field_after_object_start(encoding, Str.trim_start(Str.drop_prefix(remaining, "{")))
	} else {
		parse_record_field_after_value(encoding, remaining)
	}
}

parse_record_field_after_object_start = |encoding, remaining| {
	if Str.starts_with(remaining, "}") {
		Ok(Done({ rest: JsonState.Input(Str.trim_start(Str.drop_prefix(remaining, "}"))) }))
	} else if Str.starts_with(remaining, ",") {
		Err(invalid_json)
	} else {
		parse_record_field_start(encoding, remaining)
	}
}

parse_record_field_after_value = |encoding, remaining| {
	if Str.starts_with(remaining, "}") {
		Ok(Done({ rest: JsonState.Input(Str.trim_start(Str.drop_prefix(remaining, "}"))) }))
	} else if !Str.starts_with(remaining, ",") {
		Err(invalid_json)
	} else {
		after_comma = Str.trim_start(Str.drop_prefix(remaining, ","))
		if Str.starts_with(after_comma, "}") {
			if JsonEncoding.allows_trailing_commas(encoding) {
				Ok(Done({ rest: JsonState.Input(Str.trim_start(Str.drop_prefix(after_comma, "}"))) }))
			} else {
				Err(invalid_json)
			}
		} else {
			parse_record_field_start(encoding, after_comma)
		}
	}
}

parse_record_field_start = |_, remaining| {
	if !Str.starts_with(remaining, "\"") {
		return Err(invalid_json)
	}

	key_parts = split_json_string_tail(Str.drop_prefix(remaining, "\""))?
	after_key = Str.trim_start(key_parts.after)

	if !Str.starts_with(after_key, ":") {
		return Err(invalid_json)
	}

	after_colon = Str.trim_start(Str.drop_prefix(after_key, ":"))
	Ok(TryField({ name: key_parts.value, rest: JsonState.Input(after_colon) }))
}

skip_json_value : JsonEncoding, JsonState -> Try(JsonState, Json)
skip_json_value = |encoding, state|
	match state {
		Input(raw) => {
			trimmed = Str.trim_start(raw)
			if Str.starts_with(trimmed, "\"") {
				value_parts = split_json_string_tail(Str.drop_prefix(trimmed, "\""))?
				Ok(JsonState.Input(Str.trim_start(value_parts.after)))
			} else if Str.starts_with(trimmed, "{") {
				skip_json_object(encoding, trimmed)
			} else if Str.starts_with(trimmed, "[") {
				skip_json_array(encoding, trimmed)
			} else {
				scalar_parts = split_json_scalar_tail(trimmed)?
				if is_json_scalar(scalar_parts.value) {
					Ok(JsonState.Input(Str.trim_start(scalar_parts.after)))
				} else {
					Err(invalid_json)
				}
			}
		}
	}

skip_json_object : JsonEncoding, Str -> Try(JsonState, Json)
skip_json_object = |encoding, raw| {
	var $after_field = Str.trim_start(Str.drop_prefix(Str.trim_start(raw), "{"))
	if Str.starts_with($after_field, "}") {
		return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix($after_field, "}"))))
	}

	while True {
		if !Str.starts_with($after_field, "\"") {
			return Err(invalid_json)
		}
		key_parts = split_json_string_tail(Str.drop_prefix($after_field, "\""))?
		after_key = Str.trim_start(key_parts.after)
		if !Str.starts_with(after_key, ":") {
			return Err(invalid_json)
		}
		skipped = skip_json_value(encoding, JsonState.Input(Str.trim_start(Str.drop_prefix(after_key, ":"))))?
		match skipped {
			Input(after_value) => {
				trimmed = Str.trim_start(after_value)
				if Str.starts_with(trimmed, "}") {
					return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix(trimmed, "}"))))
				}
				if !Str.starts_with(trimmed, ",") {
					return Err(invalid_json)
				}
				after_comma = Str.trim_start(Str.drop_prefix(trimmed, ","))
				if Str.starts_with(after_comma, "}") {
					if JsonEncoding.allows_trailing_commas(encoding) {
						return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix(after_comma, "}"))))
					} else {
						return Err(invalid_json)
					}
				}
				$after_field = after_comma
			}
		}
	}
}

skip_json_array : JsonEncoding, Str -> Try(JsonState, Json)
skip_json_array = |encoding, raw| {
	var $after_value = Str.trim_start(Str.drop_prefix(Str.trim_start(raw), "["))
	if Str.starts_with($after_value, "]") {
		return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix($after_value, "]"))))
	}

	while True {
		skipped = skip_json_value(encoding, JsonState.Input($after_value))?
		match skipped {
			Input(after_nested_value) => {
				trimmed = Str.trim_start(after_nested_value)
				if Str.starts_with(trimmed, "]") {
					return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix(trimmed, "]"))))
				}
				if !Str.starts_with(trimmed, ",") {
					return Err(invalid_json)
				}
				after_comma = Str.trim_start(Str.drop_prefix(trimmed, ","))
				if Str.starts_with(after_comma, "]") {
					if JsonEncoding.allows_trailing_commas(encoding) {
						return Ok(JsonState.Input(Str.trim_start(Str.drop_prefix(after_comma, "]"))))
					} else {
						return Err(invalid_json)
					}
				}
				$after_value = after_comma
			}
		}
	}
}

parse_tag_union_from_json : Str, JsonEncoding, ParseTagUnionSpec(a) -> Try({ value : a, rest : JsonState }, Json)
parse_tag_union_from_json = |raw, encoding, spec| {
	remaining = Str.trim_start(raw)

	if Str.starts_with(remaining, "\"") {
		key_split = split_json_string_tail(Str.drop_prefix(remaining, "\""))?
		return ParseTagUnionSpec.parse(spec, { tag: key_split.value, encoding, state: JsonState.Input(key_split.after), missing: invalid_json })
	}

	if !Str.starts_with(remaining, "{") {
		return Err(invalid_json)
	}

	after_open = Str.trim_start(Str.drop_prefix(remaining, "{"))
	if !Str.starts_with(after_open, "\"") {
		return Err(invalid_json)
	}

	key_parts = split_json_string_tail(Str.drop_prefix(after_open, "\""))?
	after_key = Str.trim_start(key_parts.after)
	if !Str.starts_with(after_key, ":") {
		return Err(invalid_json)
	}

	payload = Str.trim_start(Str.drop_prefix(after_key, ":"))
	if Str.starts_with(payload, "}") {
		return Err(invalid_json)
	}
	if Str.starts_with(payload, ",") {
		return Err(invalid_json)
	}

	parsed = ParseTagUnionSpec.parse(spec, { tag: key_parts.value, encoding, state: JsonState.Input(payload), missing: invalid_json })?
	match parsed.rest {
		Input(after_payload) => finish_tag_payload(encoding, parsed.value, after_payload)
	}
}

finish_tag_payload : JsonEncoding, a, Str -> Try({ value : a, rest : JsonState }, Json)
finish_tag_payload = |encoding, value, raw| {
	remaining = Str.trim_start(raw)
	if Str.starts_with(remaining, "}") {
		Ok({ value, rest: JsonState.Input(Str.trim_start(Str.drop_prefix(remaining, "}"))) })
	} else if Str.starts_with(remaining, ",") {
		after_comma = Str.trim_start(Str.drop_prefix(remaining, ","))
		if JsonEncoding.allows_trailing_commas(encoding) {
			if Str.starts_with(after_comma, "}") {
				Ok({ value, rest: JsonState.Input(Str.trim_start(Str.drop_prefix(after_comma, "}"))) })
			} else {
				Err(invalid_json)
			}
		} else {
			Err(invalid_json)
		}
	} else {
		empty_payload = consume_empty_json_object(remaining)?
		after_payload = Str.trim_start(empty_payload.after)
		if Str.starts_with(after_payload, "}") {
			Ok({ value, rest: JsonState.Input(Str.trim_start(Str.drop_prefix(after_payload, "}"))) })
		} else {
			Err(invalid_json)
		}
	}
}

consume_empty_json_object : Str -> Try({ after : Str }, Json)
consume_empty_json_object = |raw| {
	remaining = Str.trim_start(raw)
	if !Str.starts_with(remaining, "{") {
		return Err(invalid_json)
	}
	after_open = Str.trim_start(Str.drop_prefix(remaining, "{"))
	if Str.starts_with(after_open, "}") {
		Ok({ after: Str.drop_prefix(after_open, "}") })
	} else {
		Err(invalid_json)
	}
}

snake_to_camel : Str -> Str
snake_to_camel = |text|
	match Str.find_first(text, "_") {
		Ok({ before, after }) => before.concat(upper_first_ascii(snake_to_camel(after)))
		Err(NotFound) => text
	}

upper_first_ascii : Str -> Str
upper_first_ascii = |text| {
	bytes = Str.to_utf8(text)
	match List.first(bytes) {
		Ok(first) => {
			upper = if first >= 97 {
				if first <= 122 {
					first - 32
				} else {
					first
				}
			} else {
				first
			}
			match Str.from_utf8([upper].concat(List.drop_first(bytes, 1))) {
				Ok(value) => value
				Err(_) => text
			}
		}
		Err(_) => text
	}
}

is_json_scalar : Str -> Bool
is_json_scalar = |value|
	if Str.is_eq(value, "null") {
		True
	} else if Str.is_eq(value, "true") {
		True
	} else if Str.is_eq(value, "false") {
		True
	} else {
		is_json_number(value)
	}

is_json_number : Str -> Bool
is_json_number = |value| {
	bytes = Str.to_utf8(value)
	len = List.len(bytes)
	if len == 0 {
		return False
	}

	var $index = 0
	first = byte_at(bytes, $index)
	if first == 45 {
		$index = $index + 1
		if $index == len {
			return False
		}
	}

	int_first = byte_at(bytes, $index)
	if int_first == 48 {
		$index = $index + 1
	} else if is_json_digit_one_to_nine(int_first) {
		$index = $index + 1
		while $index < len {
			byte = byte_at(bytes, $index)
			if is_json_digit(byte) {
				$index = $index + 1
			} else {
				break
			}
		}
	} else {
		return False
	}

	if $index < len {
		if byte_at(bytes, $index) == 46 {
			$index = $index + 1
			if $index == len {
				return False
			}
			if !is_json_digit(byte_at(bytes, $index)) {
				return False
			}
			while $index < len {
				byte = byte_at(bytes, $index)
				if is_json_digit(byte) {
					$index = $index + 1
				} else {
					break
				}
			}
		}
	}

	if $index < len {
		exponent = byte_at(bytes, $index)
		if (exponent == 69) or (exponent == 101) {
			$index = $index + 1
			if $index == len {
				return False
			}
			sign = byte_at(bytes, $index)
			if (sign == 43) or (sign == 45) {
				$index = $index + 1
				if $index == len {
					return False
				}
			}
			if !is_json_digit(byte_at(bytes, $index)) {
				return False
			}
			while $index < len {
				byte = byte_at(bytes, $index)
				if is_json_digit(byte) {
					$index = $index + 1
				} else {
					break
				}
			}
		}
	}

	$index == len
}

is_json_unsigned_int_literal : Str -> Bool
is_json_unsigned_int_literal = |value| {
	bytes = Str.to_utf8(value)
	len = List.len(bytes)
	if len == 0 {
		return False
	}
	first = byte_at(bytes, 0)
	if first == 48 {
		return len == 1
	}
	if !is_json_digit_one_to_nine(first) {
		return False
	}
	var $index = 1
	while $index < len {
		byte = byte_at(bytes, $index)
		if is_json_digit(byte) {
			$index = $index + 1
		} else {
			return False
		}
	}
	True
}

is_json_digit : U8 -> Bool
is_json_digit = |byte|
	if byte >= 48 {
		byte <= 57
	} else {
		False
	}

is_json_digit_one_to_nine : U8 -> Bool
is_json_digit_one_to_nine = |byte|
	if byte >= 49 {
		byte <= 57
	} else {
		False
	}

split_json_string_tail : Str -> Try({ value : Str, after : Str }, Json)
split_json_string_tail = |tail| {
	bytes = Str.to_utf8(tail)
	len = List.len(bytes)
	var $index = 0
	var $out = []

	while $index < len {
		byte = byte_at(bytes, $index)
		if byte == 34 {
			value = match Str.from_utf8($out) {
				Ok(text) => text
				Err(_) => return Err(invalid_json)
			}
			after = match Str.from_utf8(List.drop_first(bytes, $index + 1)) {
				Ok(text) => text
				Err(_) => return Err(invalid_json)
			}
			return Ok({ value, after })
		}

		if byte == 92 {
			$index = $index + 1
			if $index == len {
				return Err(invalid_json)
			}
			escape = byte_at(bytes, $index)
			if escape == 34 {
				$out = List.append($out, 34)
			} else if escape == 92 {
				$out = List.append($out, 92)
			} else if escape == 47 {
				$out = List.append($out, 47)
			} else if escape == 98 {
				$out = List.append($out, 8)
			} else if escape == 116 {
				$out = List.append($out, 9)
			} else if escape == 110 {
				$out = List.append($out, 10)
			} else if escape == 102 {
				$out = List.append($out, 12)
			} else if escape == 114 {
				$out = List.append($out, 13)
			} else if escape == 117 {
				$out = List.append($out, decode_json_unicode_escape_byte(bytes, $index + 1)?)
				$index = $index + 4
			} else {
				return Err(invalid_json)
			}
		} else if byte < 32 {
			return Err(invalid_json)
		} else {
			$out = List.append($out, byte)
		}
		$index = $index + 1
	}

	Err(invalid_json)
}

split_json_scalar_tail : Str -> Try({ value : Str, after : Str }, Json)
split_json_scalar_tail = |raw| {
	var $value = raw
	var $after = ""
	var $offset = Str.count_utf8_bytes(raw)

	for delimiter in [",", "}", "]", " ", "\n", "\t", "\r"] {
		match Str.find_first(raw, delimiter) {
			Ok(parts) => {
				parts_offset = Str.count_utf8_bytes(parts.before)
				if parts_offset < $offset {
					$value = parts.before
					$after = Str.concat(delimiter, parts.after)
					$offset = parts_offset
				}
			}
			Err(NotFound) => {}
		}
	}

	if Str.is_empty($value) {
		Err(invalid_json)
	} else {
		Ok({ value: $value, after: $after })
	}
}

container_needs_comma : JsonEncodeState -> Bool
container_needs_comma = |state|
	match List.last(state.container_commas) {
		Ok(needs_comma) => needs_comma
		Err(ListWasEmpty) => {
			crash "json encoder container stack underflow"
		}
	}

mark_container_has_item : List(Bool) -> List(Bool)
mark_container_has_item = |container_commas| List.append(List.drop_last(container_commas, 1), True)

append_json_string_bytes : List(U8), Str -> List(U8)
append_json_string_bytes = |out, value| {
	var $out = out
	for byte in Str.to_utf8(value) {
		$out = List.append($out, byte)
	}
	$out
}

append_json_quoted_string : List(U8), Str -> List(U8)
append_json_quoted_string = |out, value| {
	var $out = List.append(out, 34)
	for byte in Str.to_utf8(value) {
		$out = append_json_string_byte($out, byte)
	}
	List.append($out, 34)
}

append_json_string_byte : List(U8), U8 -> List(U8)
append_json_string_byte = |bytes, byte|
	if byte == 34 {
		List.append(List.append(bytes, 92), 34)
	} else if byte == 92 {
		List.append(List.append(bytes, 92), 92)
	} else if byte == 8 {
		List.append(List.append(bytes, 92), 98)
	} else if byte == 9 {
		List.append(List.append(bytes, 92), 116)
	} else if byte == 10 {
		List.append(List.append(bytes, 92), 110)
	} else if byte == 12 {
		List.append(List.append(bytes, 92), 102)
	} else if byte == 13 {
		List.append(List.append(bytes, 92), 114)
	} else if byte < 32 {
		append_json_unicode_escape_byte(bytes, byte)
	} else {
		List.append(bytes, byte)
	}

decode_json_unicode_escape_byte : List(U8), U64 -> Try(U8, Json)
decode_json_unicode_escape_byte = |bytes, first_index| {
	len = List.len(bytes)
	if first_index + 3 >= len {
		return Err(invalid_json)
	}

	h0 = hex_value(byte_at(bytes, first_index))?
	h1 = hex_value(byte_at(bytes, first_index + 1))?
	h2 = hex_value(byte_at(bytes, first_index + 2))?
	h3 = hex_value(byte_at(bytes, first_index + 3))?
	value = h0 * 4096 + h1 * 256 + h2 * 16 + h3
	if value > 127 {
		return Err(invalid_json)
	}

	match U8.from_str(value.to_str()) {
		Ok(byte) => Ok(byte)
		Err(_) => Err(invalid_json)
	}
}

hex_value : U8 -> Try(U64, Json)
hex_value = |byte|
	if (byte >= 48) and (byte <= 57) {
		Ok(U8.to_u64(byte) - 48)
	} else if (byte >= 65) and (byte <= 70) {
		Ok(U8.to_u64(byte) - 55)
	} else if (byte >= 97) and (byte <= 102) {
		Ok(U8.to_u64(byte) - 87)
	} else {
		Err(invalid_json)
	}

append_json_unicode_escape_byte : List(U8), U8 -> List(U8)
append_json_unicode_escape_byte = |bytes, byte| {
	value = U8.to_u64(byte)
	prefix = append_json_string_bytes(bytes, "\\u00")
	List.append(List.append(prefix, hex_digit(value / 16)), hex_digit(value - (value / 16) * 16))
}

hex_digit : U64 -> U8
hex_digit = |value| {
	code = if value < 10 {
		48 + value
	} else {
		87 + value
	}
	match U8.from_str(code.to_str()) {
		Ok(byte) => byte
		Err(_) => {
			crash "json hex digit out of bounds"
		}
	}
}

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index|
	match List.get(bytes, index) {
		Ok(byte) => byte
		Err(_) => {
			crash "json byte index out of bounds"
		}
	}
