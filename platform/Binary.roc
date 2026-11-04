## Versioned binary values for reproducible source examples and corpus inputs.
## Structural codecs use Roc's encoder_for and parser_for derivation. Nominal
## types opt in with both declarations. This encodes logical values, not storage.
Binary := [].{

	## Parser cursor. Decoding permits at most 4,096 value nodes and 128 total
	## containers, conservatively bounding recursion as well as aggregate work.
	State := { bytes : List(U8), nodes : U64, containers : U64 }

	## Compiler-dispatched codec marker; applications never construct codec objects.
	Format := [Default].{
		invalid_value : Format, State -> [MalformedInput]
		invalid_value = |_, _| MalformedInput

		rename_field : Format, Str -> Str
		rename_field = |_, name| name

		encode_str : Str, List(U8) -> Try(List(U8), [])
		encode_str = |value, state| Ok(write_string(List.append(state, 0), value))

		parse_str : Format, State -> Try({ value : Str, rest : State }, [MalformedInput, BudgetExceeded])
		parse_str = |_, state| read_string(take_node(state, 0)?)

		encode_bool : Bool, List(U8) -> Try(List(U8), [])
		encode_bool = |value, state| Ok(List.append(List.append(state, 1), if (value) 1 else 0))

		parse_bool : Format, State -> Try({ value : Bool, rest : State }, [MalformedInput, BudgetExceeded])
		parse_bool = |_, state| {
			read = read_unsigned(take_node(state, 1)?, 1)?
			if (read.value > 1) Err(MalformedInput) else Ok({ value: read.value == 1, rest: read.rest })
		}

		encode_null : List(U8) -> Try(List(U8), [])
		encode_null = |state| Ok(List.append(state, 15))

		parse_null : Format, State -> Try({ value : {}, rest : State }, [MalformedInput, BudgetExceeded])
		parse_null = |_, state| Ok({ value: {}, rest: take_node(state, 15)? })

		encode_u8 : U8, List(U8) -> Try(List(U8), [])
		encode_u8 = |value, state| Ok(write_unsigned(List.append(state, 2), U8.to_u128(value), 1))

		parse_u8 : Format, State -> Try({ value : U8, rest : State }, [MalformedInput, BudgetExceeded])
		parse_u8 = |_, state| {
			read = read_unsigned(take_node(state, 2)?, 1)?
			Ok({ value: U128.to_u8_wrap(read.value), rest: read.rest })
		}

		encode_i8 : I8, List(U8) -> Try(List(U8), [])
		encode_i8 = |value, state| Ok(write_unsigned(List.append(state, 3), I8.to_u128_wrap(value), 1))

		parse_i8 : Format, State -> Try({ value : I8, rest : State }, [MalformedInput, BudgetExceeded])
		parse_i8 = |_, state| {
			read = read_unsigned(take_node(state, 3)?, 1)?
			Ok({ value: U128.to_i8_wrap(read.value), rest: read.rest })
		}

		encode_u16 : U16, List(U8) -> Try(List(U8), [])
		encode_u16 = |value, state| Ok(write_unsigned(List.append(state, 4), U16.to_u128(value), 2))

		parse_u16 : Format, State -> Try({ value : U16, rest : State }, [MalformedInput, BudgetExceeded])
		parse_u16 = |_, state| {
			read = read_unsigned(take_node(state, 4)?, 2)?
			Ok({ value: U128.to_u16_wrap(read.value), rest: read.rest })
		}

		encode_i16 : I16, List(U8) -> Try(List(U8), [])
		encode_i16 = |value, state| Ok(write_unsigned(List.append(state, 5), I16.to_u128_wrap(value), 2))

		parse_i16 : Format, State -> Try({ value : I16, rest : State }, [MalformedInput, BudgetExceeded])
		parse_i16 = |_, state| {
			read = read_unsigned(take_node(state, 5)?, 2)?
			Ok({ value: U128.to_i16_wrap(read.value), rest: read.rest })
		}

		encode_u32 : U32, List(U8) -> Try(List(U8), [])
		encode_u32 = |value, state| Ok(write_unsigned(List.append(state, 6), U32.to_u128(value), 4))

		parse_u32 : Format, State -> Try({ value : U32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_u32 = |_, state| {
			read = read_unsigned(take_node(state, 6)?, 4)?
			Ok({ value: U128.to_u32_wrap(read.value), rest: read.rest })
		}

		encode_i32 : I32, List(U8) -> Try(List(U8), [])
		encode_i32 = |value, state| Ok(write_unsigned(List.append(state, 7), I32.to_u128_wrap(value), 4))

		parse_i32 : Format, State -> Try({ value : I32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_i32 = |_, state| {
			read = read_unsigned(take_node(state, 7)?, 4)?
			Ok({ value: U128.to_i32_wrap(read.value), rest: read.rest })
		}

		encode_u64 : U64, List(U8) -> Try(List(U8), [])
		encode_u64 = |value, state| Ok(write_unsigned(List.append(state, 8), U64.to_u128(value), 8))

		parse_u64 : Format, State -> Try({ value : U64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_u64 = |_, state| {
			read = read_unsigned(take_node(state, 8)?, 8)?
			Ok({ value: U128.to_u64_wrap(read.value), rest: read.rest })
		}

		encode_i64 : I64, List(U8) -> Try(List(U8), [])
		encode_i64 = |value, state| Ok(write_unsigned(List.append(state, 9), I64.to_u128_wrap(value), 8))

		parse_i64 : Format, State -> Try({ value : I64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_i64 = |_, state| {
			read = read_unsigned(take_node(state, 9)?, 8)?
			Ok({ value: U128.to_i64_wrap(read.value), rest: read.rest })
		}

		encode_u128 : U128, List(U8) -> Try(List(U8), [])
		encode_u128 = |value, state| Ok(write_unsigned(List.append(state, 10), U128.to_u128_wrap(value), 16))

		parse_u128 : Format, State -> Try({ value : U128, rest : State }, [MalformedInput, BudgetExceeded])
		parse_u128 = |_, state| {
			read = read_unsigned(take_node(state, 10)?, 16)?
			Ok({ value: U128.to_u128_wrap(read.value), rest: read.rest })
		}

		encode_i128 : I128, List(U8) -> Try(List(U8), [])
		encode_i128 = |value, state| Ok(write_unsigned(List.append(state, 11), I128.to_u128_wrap(value), 16))

		parse_i128 : Format, State -> Try({ value : I128, rest : State }, [MalformedInput, BudgetExceeded])
		parse_i128 = |_, state| {
			read = read_unsigned(take_node(state, 11)?, 16)?
			Ok({ value: U128.to_i128_wrap(read.value), rest: read.rest })
		}

		encode_f32 : F32, List(U8) -> Try(List(U8), [])
		encode_f32 = |value, state| Ok(write_unsigned(List.append(state, 12), U32.to_u128(F32.to_bits(value)), 4))

		parse_f32 : Format, State -> Try({ value : F32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_f32 = |_, state| {
			read = read_unsigned(take_node(state, 12)?, 4)?
			Ok({ value: F32.from_bits(U128.to_u32_wrap(read.value)), rest: read.rest })
		}

		encode_f64 : F64, List(U8) -> Try(List(U8), [])
		encode_f64 = |value, state| Ok(write_unsigned(List.append(state, 13), U64.to_u128(F64.to_bits(value)), 8))

		parse_f64 : Format, State -> Try({ value : F64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_f64 = |_, state| {
			read = read_unsigned(take_node(state, 13)?, 8)?
			Ok({ value: F64.from_bits(U128.to_u64_wrap(read.value)), rest: read.rest })
		}

		encode_dec : Dec, List(U8) -> Try(List(U8), [])
		encode_dec = |value, state| Ok(write_unsigned(List.append(state, 14), I128.to_u128_wrap(Dec.to_attos(value)), 16))

		parse_dec : Format, State -> Try({ value : Dec, rest : State }, [MalformedInput, BudgetExceeded])
		parse_dec = |_, state| {
			read = read_unsigned(take_node(state, 14)?, 16)?
			Ok({ value: Dec.from_attos(U128.to_i128_wrap(read.value)), rest: read.rest })
		}

		encode_list : List(U8), U64, (List(U8), (List(U8), (List(U8) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)
		encode_list = |state, count, write_items|
			write_items(write_count(List.append(state, 20), count), |current, write_value| write_value(current))

		parse_list_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], [MalformedInput, BudgetExceeded])
		parse_list_start = |_, state| {
			read = read_count(take_node(state, 20)?)?
			Ok(Counted({ len: read.value, rest: read.rest }))
		}

		parse_list_next : Format, State -> Try([Item(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_list_next = |_, _| Err(MalformedInput)

		parse_list_after_item : Format, State -> Try([Continue(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_list_after_item = |_, _| Err(MalformedInput)

		encode_record : List(U8), U64, (List(U8), (List(U8), Str, (List(U8) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)
		encode_record = |state, count, write_fields|
			write_fields(write_count(List.append(state, 21), count), |current, name, write_value| write_value(write_string(current, name)))

		parse_record_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], [MalformedInput, BudgetExceeded])
		parse_record_start = |_, state| {
			read = read_count(take_node(state, 21)?)?
			Ok(Counted({ len: read.value, rest: read.rest }))
		}

		parse_record_field : Format, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_record_field = |_, _, state| {
			read = read_string(state)?
			Ok(TryField({ name: read.value, rest: read.rest }))
		}

		parse_record_after_field : Format, State -> Try([Continue(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_record_after_field = |_, _| Err(MalformedInput)

		skip_record_field : Format, State -> Try(State, [MalformedInput, BudgetExceeded])
		skip_record_field = |_, state| skip_value(state)

		encode_tuple : List(U8), U64, (List(U8), (List(U8), (List(U8) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)
		encode_tuple = |state, count, write_items|
			write_items(write_count(List.append(state, 22), count), |current, write_value| write_value(current))

		parse_tuple_start : Format, State, U64 -> Try(State, [MalformedInput, BudgetExceeded])
		parse_tuple_start = |_, state, count| {
			read = read_count(take_node(state, 22)?)?
			if (read.value == count) Ok(read.rest) else Err(MalformedInput)
		}

		parse_tuple_next : Format, State, U64, U64 -> Try(State, [MalformedInput, BudgetExceeded])
		parse_tuple_next = |_, state, _, _| Ok(state)

		parse_tuple_end : Format, State, U64 -> Try(State, [MalformedInput, BudgetExceeded])
		parse_tuple_end = |_, state, _| Ok(state)

		encode_tag : List(U8), Str, U64, (List(U8), (List(U8), (List(U8) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)
		encode_tag = |state, name, count, write_payloads|
			write_payloads(write_count(write_string(List.append(state, 23), name), count), |current, write_value| write_value(current))

		parse_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, [MalformedInput, BudgetExceeded])
		parse_tag_union = |encoding, spec, state| {
			name = read_string(take_node(state, 23)?)?
			Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag: name.value,
					encoding,
					state: name.rest,
					start_payloads: |current, count| {
						read = read_count(current)?
						if (read.value == count) Ok(read.rest) else Err(MalformedInput)
					},
					next_payload: |current, _, _| Ok(current),
					finish_payloads: |current, _| Ok(current),
					missing: MalformedInput,
				},
			)
		}

		encode_dict : List(U8), U64, (List(U8), (List(U8), (List(U8) -> Try(List(U8), err)), (List(U8) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)) -> Try(List(U8), err)
		encode_dict = |state, count, write_entries|
			write_entries(write_count(List.append(state, 24), count), |current, write_key, write_value| write_value(write_key(current)?))

		parse_dict_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], [MalformedInput, BudgetExceeded])
		parse_dict_start = |_, state| {
			read = read_count(take_node(state, 24)?)?
			Ok(Counted({ len: read.value, rest: read.rest }))
		}

		parse_dict_next : Format, State -> Try([Entry(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_dict_next = |_, _| Err(MalformedInput)

		parse_dict_after_key : Format, State -> Try(State, [MalformedInput, BudgetExceeded])
		parse_dict_after_key = |_, state| Ok(state)

		parse_dict_after_entry : Format, State -> Try([Continue(State), Done(State)], [MalformedInput, BudgetExceeded])
		parse_dict_after_entry = |_, _| Err(MalformedInput)

		encode_key_start : Format, List(U8) -> Try(List(U8), [])
		encode_key_start = |_, state| Ok(state)

		parse_key_start : Format, State -> Try(State, [MalformedInput, BudgetExceeded])
		parse_key_start = |_, state| Ok(state)

		encode_key_str : Format, Str, List(U8) -> Try(List(U8), [])
		encode_key_str = |_, value, state| Format.encode_str(value, state)

		parse_key_str : Format, State -> Try({ value : Str, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_str = |encoding, state| Format.parse_str(encoding, state)

		encode_key_bool : Format, Bool, List(U8) -> Try(List(U8), [])
		encode_key_bool = |_, value, state| Format.encode_bool(value, state)

		parse_key_bool : Format, State -> Try({ value : Bool, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_bool = |encoding, state| Format.parse_bool(encoding, state)

		encode_key_u8 : Format, U8, List(U8) -> Try(List(U8), [])
		encode_key_u8 = |_, value, state| Format.encode_u8(value, state)

		parse_key_u8 : Format, State -> Try({ value : U8, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_u8 = |encoding, state| Format.parse_u8(encoding, state)

		encode_key_i8 : Format, I8, List(U8) -> Try(List(U8), [])
		encode_key_i8 = |_, value, state| Format.encode_i8(value, state)

		parse_key_i8 : Format, State -> Try({ value : I8, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_i8 = |encoding, state| Format.parse_i8(encoding, state)

		encode_key_u16 : Format, U16, List(U8) -> Try(List(U8), [])
		encode_key_u16 = |_, value, state| Format.encode_u16(value, state)

		parse_key_u16 : Format, State -> Try({ value : U16, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_u16 = |encoding, state| Format.parse_u16(encoding, state)

		encode_key_i16 : Format, I16, List(U8) -> Try(List(U8), [])
		encode_key_i16 = |_, value, state| Format.encode_i16(value, state)

		parse_key_i16 : Format, State -> Try({ value : I16, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_i16 = |encoding, state| Format.parse_i16(encoding, state)

		encode_key_u32 : Format, U32, List(U8) -> Try(List(U8), [])
		encode_key_u32 = |_, value, state| Format.encode_u32(value, state)

		parse_key_u32 : Format, State -> Try({ value : U32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_u32 = |encoding, state| Format.parse_u32(encoding, state)

		encode_key_i32 : Format, I32, List(U8) -> Try(List(U8), [])
		encode_key_i32 = |_, value, state| Format.encode_i32(value, state)

		parse_key_i32 : Format, State -> Try({ value : I32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_i32 = |encoding, state| Format.parse_i32(encoding, state)

		encode_key_u64 : Format, U64, List(U8) -> Try(List(U8), [])
		encode_key_u64 = |_, value, state| Format.encode_u64(value, state)

		parse_key_u64 : Format, State -> Try({ value : U64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_u64 = |encoding, state| Format.parse_u64(encoding, state)

		encode_key_i64 : Format, I64, List(U8) -> Try(List(U8), [])
		encode_key_i64 = |_, value, state| Format.encode_i64(value, state)

		parse_key_i64 : Format, State -> Try({ value : I64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_i64 = |encoding, state| Format.parse_i64(encoding, state)

		encode_key_u128 : Format, U128, List(U8) -> Try(List(U8), [])
		encode_key_u128 = |_, value, state| Format.encode_u128(value, state)

		parse_key_u128 : Format, State -> Try({ value : U128, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_u128 = |encoding, state| Format.parse_u128(encoding, state)

		encode_key_i128 : Format, I128, List(U8) -> Try(List(U8), [])
		encode_key_i128 = |_, value, state| Format.encode_i128(value, state)

		parse_key_i128 : Format, State -> Try({ value : I128, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_i128 = |encoding, state| Format.parse_i128(encoding, state)

		encode_key_f32 : Format, F32, List(U8) -> Try(List(U8), [])
		encode_key_f32 = |_, value, state| Format.encode_f32(value, state)

		parse_key_f32 : Format, State -> Try({ value : F32, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_f32 = |encoding, state| Format.parse_f32(encoding, state)

		encode_key_f64 : Format, F64, List(U8) -> Try(List(U8), [])
		encode_key_f64 = |_, value, state| Format.encode_f64(value, state)

		parse_key_f64 : Format, State -> Try({ value : F64, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_f64 = |encoding, state| Format.parse_f64(encoding, state)

		encode_key_dec : Format, Dec, List(U8) -> Try(List(U8), [])
		encode_key_dec = |_, value, state| Format.encode_dec(value, state)

		parse_key_dec : Format, State -> Try({ value : Dec, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_dec = |encoding, state| Format.parse_dec(encoding, state)

		encode_key_tag : Format, List(U8), Str -> Try(List(U8), [])
		encode_key_tag = |_, state, name| Ok(write_count(write_string(List.append(state, 23), name), 0))

		parse_key_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, [MalformedInput, BudgetExceeded])
		parse_key_tag_union = |encoding, spec, state| Format.parse_tag_union(encoding, spec, state)
	}

	## A type accepted by the platform's binary encoder.
	a.Encodable : where [a.encoder_for : Format -> (a, List(U8) -> Try(List(U8), []))]

	## A type accepted by the platform's binary parser.
	a.Parseable(errs) : where [a.parser_for : Format -> (State -> Try({ value : a, rest : State }, [MalformedInput, BudgetExceeded, ..errs]))]

	## Encode a logical value as a version-one encoded-value input.
	encode : a -> List(U8) where [a.Encodable]
	encode = |value| {
		Shape : a
		encode_shape = Shape.encoder_for(Format.Default)
		Ok(encoded) = encode_shape(value, [82, 70, 90, 1, 1])
		encoded
	}

	## Decode a version-one encoded-value input, enforcing all input budgets.
	decode : List(U8) -> Try(a, [MalformedInput, BudgetExceeded, ..errs]) where [a.Parseable(errs)]
	decode = |input| {
		Shape : a
		parse_shape = Shape.parser_for(Format.Default)
		if input.len() > 1048576 {
			return Err(BudgetExceeded)
		}
		match input {
			[82, 70, 90, 1, 1, .. as bytes] => {
				read = parse_shape(State.{ bytes, nodes: 4096, containers: 128 })?
				if (read.rest.bytes.is_empty()) Ok(read.value) else Err(MalformedInput)
			}
			_ => Err(MalformedInput)
		}
	}

	## Wrap generator entropy without changing any generator decisions.
	entropy : List(U8) -> List(U8)
	entropy = |bytes| List.concat([82, 70, 90, 1, 0], bytes)

	## Identify generated entropy and encoded values. Bare bytes are entropy;
	## a reserved format prefix with an unsupported version or form is rejected.
	form : List(U8) -> Try([Entropy(List(U8)), Encoded], [MalformedInput])
	form = |input|
		match input {
			[82, 70, 90, 1, 0, .. as bytes] => Ok(Entropy(bytes))
			[82, 70, 90, 1, 1, ..] => Ok(Encoded)
			[82, 70, 90, ..] => Err(MalformedInput)
			_ => Ok(Entropy(input))
		}
}

write_unsigned : List(U8), U128, U64 -> List(U8)
write_unsigned = |state, value, width| {
	var $output = state
	var $remaining = value
	var $index = 0
	while $index < width {
		$output = List.append($output, U128.to_u8_wrap($remaining))
		$remaining = U128.shr_zf_wrap($remaining, 8)
		$index = $index + 1
	}
	$output
}

write_count : List(U8), U64 -> List(U8)
write_count = |state, value| write_unsigned(state, U64.to_u128(value), 8)

write_string : List(U8), Str -> List(U8)
write_string = |state, value| List.concat(write_count(state, Str.count_utf8_bytes(value)), Str.to_utf8(value))

take_node : Binary.State, U8 -> Try(Binary.State, [MalformedInput, BudgetExceeded])
take_node = |state, expected| {
	if state.nodes == 0 {
		return Err(BudgetExceeded)
	}
	if expected >= 20 and state.containers == 0 {
		return Err(BudgetExceeded)
	}
	match state.bytes {
		[tag, .. as bytes] if tag == expected => Ok(
			Binary.State.{
				bytes,
				nodes: state.nodes - 1,
				containers: if (expected >= 20) state.containers - 1 else state.containers,
			},
		)
		_ => Err(MalformedInput)
	}
}

read_unsigned : Binary.State, U64 -> Try({ value : U128, rest : Binary.State }, [MalformedInput])
read_unsigned = |state, width| {
	if state.bytes.len() < width {
		return Err(MalformedInput)
	}
	var $value = U128.to_u128(0)
	var $index = width
	while $index > 0 {
		$index = $index - 1
		$value = U128.bitwise_or(U128.shl_wrap($value, 8), U8.to_u128(state.bytes.get($index).catch(|_| 0, |value| value)))
	}
	Ok({ value: $value, rest: Binary.State.{ bytes: state.bytes.drop_first(width), nodes: state.nodes, containers: state.containers } })
}

read_count : Binary.State -> Try({ value : U64, rest : Binary.State }, [MalformedInput, BudgetExceeded])
read_count = |state| {
	read = read_unsigned(state, 8)?
	if read.value > 4096 or read.value > U64.to_u128(read.rest.nodes) {
		return Err(BudgetExceeded)
	}
	Ok({ value: U128.to_u64_wrap(read.value), rest: read.rest })
}

read_string : Binary.State -> Try({ value : Str, rest : Binary.State }, [MalformedInput, BudgetExceeded])
read_string = |state| {
	read = read_unsigned(state, 8)?
	if read.value > 1048576 {
		return Err(BudgetExceeded)
	}
	length = U128.to_u64_wrap(read.value)
	if length > read.rest.bytes.len() {
		return Err(MalformedInput)
	}
	value = Str.from_utf8(read.rest.bytes.take_first(length)).map_err(|_| MalformedInput)?
	Ok({ value, rest: Binary.State.{ bytes: read.rest.bytes.drop_first(length), nodes: read.rest.nodes, containers: read.rest.containers } })
}

skip_value : Binary.State -> Try(Binary.State, [MalformedInput, BudgetExceeded])
skip_value = |state| {
	tag = state.bytes.first().map_err(|_| MalformedInput)?
	start = take_node(state, tag)?
	match tag {
		0 => Ok(read_string(start)?.rest)
		1 => {
			read = read_unsigned(start, 1)?
			if (read.value <= 1) Ok(read.rest) else Err(MalformedInput)
		}
		2 | 3 => Ok(read_unsigned(start, 1)?.rest)
		4 | 5 => Ok(read_unsigned(start, 2)?.rest)
		6 | 7 | 12 => Ok(read_unsigned(start, 4)?.rest)
		8 | 9 | 13 => Ok(read_unsigned(start, 8)?.rest)
		10 | 11 | 14 => Ok(read_unsigned(start, 16)?.rest)
		15 => Ok(start)
		20 | 21 | 22 | 23 | 24 => {
			named = if (tag == 23) read_string(start)?.rest else start
			count = read_count(named)?
			var $current = count.rest
			var $index = 0
			while $index < count.value {
				if tag == 21 {
					$current = read_string($current)?.rest
				}
				$current = skip_value($current)?
				if tag == 24 {
					$current = skip_value($current)?
				}
				$index = $index + 1
			}
			Ok($current)
		}
		_ => Err(MalformedInput)
	}
}

expect {
	value : { bytes : List(U8), radix : U8 }
	value = { bytes: [0, 127, 255], radix: 10 }
	decoded : Try({ bytes : List(U8), radix : U8 }, _)
	decoded = Binary.decode(Binary.encode(value))
	decoded == Ok(value)
}

expect {
	value : (I128, U64, Dec, Bool, Str)
	value = (I128.lowest, U64.highest, -0.25, True, "🦊")
	decoded : Try((I128, U64, Dec, Bool, Str), _)
	decoded = Binary.decode(Binary.encode(value))
	decoded == Ok(value)
}

expect {
	value : [Empty, Pair(Str, U64)]
	value = Pair("hello", 42)
	decoded : Try([Empty, Pair(Str, U64)], _)
	decoded = Binary.decode(Binary.encode(value))
	decoded == Ok(value)
}

expect {
	value = Dict.from_list([("first", 1.U64), ("second", 2.U64)])
	decoded : Try(Dict(Str, U64), _)
	decoded = Binary.decode(Binary.encode(value))
	decoded == Ok(value)
}

RoundTripInput := { bytes : List(U8), radix : U8 }.{
	parser_for : _
	encoder_for : _
	is_eq : _
}

expect {
	value = RoundTripInput.{ bytes: [1, 2, 3], radix: 16 }
	decoded : Try(RoundTripInput, _)
	decoded = Binary.decode(Binary.encode(value))
	decoded == Ok(value)
}

expect {
	# Reordered fields and unknown fields are parsed structurally. The skipped
	# field contains containers, tags and dictionary entries rather than a scalar.
	encoded = Binary.encode({ known: 7.U64, unknown: [Pair(Dict.from_list([("key", [1.U8, 2])]))] })
	decoded : Try({ known : U64 }, _)
	decoded = Binary.decode(encoded)
	decoded == Ok({ known: 7 })
}

expect {
	encoded = Binary.encode({ values: [1.U64, 2, 3], text: "some text" })
	var $length = 0
	var $all_rejected = True
	while $length < encoded.len() {
		decoded : Try({ values : List(U64), text : Str }, _)
		decoded = Binary.decode(encoded.take_first($length))
		match decoded {
			Ok(_) => {
				$all_rejected = False
			}
			Err(_) => {}
		}
		$length = $length + 1
	}
	$all_rejected
}

expect {
	decoded : Try(List(U8), _)
	decoded = Binary.decode([82, 70, 90, 1, 1, 20, 255, 255, 255, 255, 255, 255, 255, 255])
	decoded == Err(BudgetExceeded)
}

expect {
	decoded : Try(Str, _)
	decoded = Binary.decode([82, 70, 90, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 255])
	decoded == Err(MalformedInput)
}

expect {
	decoded : Try(U8, _)
	decoded = Binary.decode(Binary.encode(42.U8).append(0))
	decoded == Err(MalformedInput)
}

expect Binary.form([82, 70, 90, 2, 1]) == Err(MalformedInput)
expect Binary.form([82, 70, 90, 1, 2]) == Err(MalformedInput)
expect Binary.form([3, 2, 1]) == Ok(Entropy([3, 2, 1]))
expect Binary.form(Binary.entropy([3, 2, 1])) == Ok(Entropy([3, 2, 1]))

expect {
	Ok(known) = Binary.Format.encode_u64(7, write_string(write_count([82, 70, 90, 1, 1, 21], 2), "known"))
	encoded = write_string(known, "unknown").concat([1, 2])
	decoded : Try({ known : U64 }, _)
	decoded = Binary.decode(encoded)
	decoded == Err(MalformedInput)
}

expect {
	value = (F32.from_bits(0x80000000), F64.from_bits(0x8000000000000000), F64.infinity, F64.nan)
	decoded : Try((F32, F64, F64, F64), _)
	decoded = Binary.decode(Binary.encode(value))
	match decoded {
		Ok((a, b, c, d)) => F32.to_bits(a) == 0x80000000 and F64.to_bits(b) == 0x8000000000000000 and c == F64.infinity and F64.is_nan(d)
		Err(_) => False
	}
}
