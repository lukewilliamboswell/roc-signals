import Core

## The binary format for values a page and its workers send each other.
##
## Both ends of a worker message are the same compiled module, so both know
## the type of every payload, and the format carries no type information,
## header or version: a payload is exactly the encoding of one value. Roc's
## `encoder_for` and `parser_for` derivation drives it, so records, tuples, tag
## unions, lists, sets, dictionaries, strings, numbers and `Bool` need no codec
## written by hand. A nominal type opts in by declaring `parser_for : _` and
## `encoder_for : _`, and is then encoded as its backing type. A type with a
## function in it, a nominal type without those declarations, or a `Try` is
## not `Sendable`, and using it is a compile-time error. (A record field of
## type `Try(a, [Missing])` is the exception: derivation reads it as an
## optional field, `name ?: a`.)
##
## Layout, for a second implementation:
##
## - A *count* is an unsigned LEB128 `U64`: seven bits per byte, least
##   significant group first, the high bit set on every byte but the last.
##   It is minimal (no final `0x00` byte after the first) and at most ten
##   bytes, the tenth being `0x01` at most.
## - `U8` to `U128` and `I8` to `I128` are fixed width, little-endian, two's
##   complement. `F32` and `F64` are their IEEE 754 bit patterns as `U32` and
##   `U64`. `Dec` is `Dec.to_attos` as an `I128`. `Bool` is one byte, `0` or
##   `1`.
## - `Str` is a count of UTF-8 bytes, then those bytes. `Wire.Bytes` is laid
##   out exactly as `List(U8)`.
## - `List(a)` and `Set(a)` are a count, then each item. A set's items are in
##   its iteration order.
## - A tuple is its items in order, with nothing before or between them.
## - A tag is its name as a `Str`, then its payloads in order.
## - A record is a count of the fields present, then its fields in ascending
##   byte order of their names (the order derivation visits them). When every
##   field of the record type is present, each field is its value alone. When
##   an optional field (`name ?: a`) is absent, each present field is its name
##   as a `Str` and then its value, and the count says how many follow.
## - `Dict(k, v)` is a count, then each entry as its key and then its value,
##   the entries in strictly ascending byte order of their encoded keys. A
##   key that is a tag without payloads is its name as a `Str`.
##
## Every value takes at least one byte (`{}` is the count `0`), so a count is
## checked against the rest of the input before anything is allocated for it.
## Decoding is strict: it accepts only what the encoder produces, and refuses
## anything else with an `Err`, never a crash. A payload that decodes is
## consumed completely, its containers nest at most 512 deep, and the
## decoder's memory is the decoded value, which each item of took at least one
## input byte, plus a stack bounded by that depth.
Wire := [].{

	## Why `decode` refused a payload.
	##
	## - `Truncated`: the input ends inside a value, or a count is larger than
	##   the rest of the input could hold.
	## - `TrailingBytes`: a value decoded but input remained after it.
	## - `InvalidUtf8`: a string, tag name or field name is not UTF-8.
	## - `UnknownTag`: a tag name the type does not have.
	## - `Malformed`: a `Bool` byte other than `0` or `1`; a count that is not
	##   minimal or does not fit a `U64`; a record count above the type's
	##   field count; a field name the type does not have, or out of order;
	##   dictionary keys not strictly ascending.
	## - `TooDeep`: containers nested more than 512 deep.
	## - `MissingRequiredField(name)`: a record in the named form lacks a
	##   required field.
	Error : [Truncated, TrailingBytes, InvalidUtf8, UnknownTag, Malformed, TooDeep, MissingRequiredField(Str)]

	## A type whose values can cross between a page and a worker: everything
	## derivation covers, and nominal types that declare `parser_for : _` and
	## `encoder_for : _` (or implement them over this format's methods).
	## Functions, `Try`, and nominal types without those declarations are
	## excluded; the compiler reports the missing `encoder_for` and
	## `parser_for` methods at the use that needs them.
	a.Sendable :
		where [
			a.encoder_for : Format -> (a, Enc -> Try(Enc, [])),
			a.parser_for : Format -> (State -> Try({ value : a, rest : State }, Error)),
		]

	## Encode a value as a payload. It cannot fail.
	##
	## Equal values encode to equal bytes, with two exceptions the compiler
	## gives a format no way to close: a `Set` is written in its iteration
	## order, so equal sets built in different orders can differ; and a float
	## is its bit pattern, so `0.0` and `-0.0`, which compare equal, differ. A
	## dictionary's entries are sorted, so equal dictionaries agree. A value
	## nesting containers deeper than `decode` accepts still encodes, and its
	## payload is refused with `TooDeep`; `try_encode` refuses it instead.
	encode : a -> List(U8) where [a.Sendable]
	encode = |value| {
		state = Wire.encode_state(value)
		if !state.files.is_empty() {
			crash "contract: Wire.encode was given a value holding a File; a file crosses only in a worker program's input or output"
		}
		state.bytes
	}

	## Encode a value as a payload, or `Err(TooDeep)` when it nests containers
	## deeper than `decode` accepts, so the side that built the value learns
	## that its payload would be refused before sending it.
	try_encode : a -> Try(List(U8), [TooDeep]) where [a.Sendable]
	try_encode = |value| {
		state = Wire.encode_state(value)
		if !state.files.is_empty() {
			crash "contract: Wire.try_encode was given a value holding a File; a file crosses only in a worker program's input or output"
		}
		if (state.deep) Err(TooDeep) else Ok(state.bytes)
	}

	## For the worker layer: encode a value that may hold files. The payload
	## refers to each file by its place in `files`, which travel beside it
	## (design.md, Appendix B).
	encode_with_files : a -> { bytes : List(U8), files : List(Core.File), deep : Bool } where [a.Sendable]
	encode_with_files = |value| {
		{ bytes, depth: _, deep, files } = Wire.encode_state(value)
		{ bytes, files, deep }
	}

	## The encoder's final state for a value: its bytes and whether it nested
	## too deep.
	encode_state : a -> Enc where [a.Sendable]
	encode_state = |value| {
		## The caller's type, named so its derived codec can be asked for.
		Shape : a
		encode_shape = Shape.encoder_for(Format.Default)
		match encode_shape(value, { bytes: [], depth: 0, deep: Bool.False, files: [] }) {
			Ok(state) => state
		}
	}

	## Decode a payload as a value of the type the caller expects.
	##
	## The whole input must be one value: input left over is `TrailingBytes`.
	## Malformed input of any kind is an `Err` (see `Error`), never a crash,
	## and no count is trusted beyond what the remaining input can hold.
	## Decoded strings and `Bytes` may share the input's buffer instead of
	## copying it.
	decode : List(U8) -> Try(a, Error) where [a.Sendable]
	decode = |bytes| {
		## The caller's type, named so its derived codec can be asked for.
		Shape : a
		parse_shape = Shape.parser_for(Format.Default)
		read = parse_shape(State.{ bytes, pos: 0, top: empty_frame, outer: [], names: [], files: [] })?
		if (read.rest.pos == bytes.len()) Ok(read.value) else Err(TrailingBytes)
	}

	## For the worker layer: decode a payload whose files arrived beside it,
	## each the bytes of the file or range at its place in the payload's file
	## list. A file the payload refers to that is not there, or whose bytes
	## are not its length, is `Malformed`.
	decode_with_files : List(U8), List(List(U8)) -> Try(a, Error) where [a.Sendable]
	decode_with_files = |bytes, files| {
		## The caller's type, named so its derived codec can be asked for.
		Shape : a
		parse_shape = Shape.parser_for(Format.Default)
		read = parse_shape(State.{ bytes, pos: 0, top: empty_frame, outer: [], names: [], files })?
		if (read.rest.pos == bytes.len()) Ok(read.value) else Err(TrailingBytes)
	}

	## A byte payload with a bulk codec. It encodes exactly as the `List(U8)`
	## it wraps, so either end may use either type, but it is written and read
	## as one block instead of byte by byte, and decoding it shares the
	## input's buffer.
	Bytes := { list : List(U8) }.{

		## Equal when the wrapped bytes are equal.
		is_eq : _

		## Wrap bytes for sending.
		from_list : List(U8) -> Bytes
		from_list = |list| Bytes.{ list }

		## The wrapped bytes.
		to_list : Bytes -> List(U8)
		to_list = |bytes| bytes.list

		## Write the bytes with the format's `encode_bytes`.
		encoder_for : encoding -> (Bytes, state -> Try(state, err))
			where [encoding.encode_bytes : encoding, List(U8), state -> Try(state, err)]
		encoder_for = |encoding| {
			## The format's type, named so its methods can be called.
			Encoding : encoding
			|bytes, state| Encoding.encode_bytes(encoding, bytes.list, state)
		}

		## Read the bytes with the format's `parse_bytes`.
		parser_for : encoding -> (state -> Try({ value : Bytes, rest : state }, err))
			where [encoding.parse_bytes : encoding, state -> Try({ value : List(U8), rest : state }, err)]
		parser_for = |encoding| {
			## The format's type, named so its methods can be called.
			Encoding : encoding
			|state| {
				parsed = Encoding.parse_bytes(encoding, state)?
				Ok({ value: Bytes.{ list: parsed.value }, rest: parsed.rest })
			}
		}
	}

	## A dictionary's entries as they are written, and whether any nested too
	## deep.
	Entries : { entries : List(List(U8)), deep : Bool, files : List(Core.File) }

	## One open container in the decoder: how many entries remain, and
	## per-kind bookkeeping (a record's field count and cached names, or a
	## dictionary's current and previous key).
	Frame : { remaining : U64, total : U64, prev_start : U64, prev_end : U64 }

	## A record being encoded, with how many of its fields were present.
	Fields : { enc : Enc, present : U64 }

	## The encoder's state: the bytes so far, how many containers are open
	## around the value being written, and whether that ever exceeded the
	## depth `decode` accepts. Applications never construct one.
	## The files the value holds, in the order the payload refers to them.
	Enc : { bytes : List(U8), depth : U64, deep : Bool, files : List(Core.File) }

	## The decoder's cursor: the input, the position, the open container and
	## those around it, and the field names positional records have cached.
	## Applications never construct one.
	State := { bytes : List(U8), pos : U64, top : Frame, outer : List(Frame), names : List(Str), files : List(List(U8)) }

	## The format marker the compiler dispatches on. Its methods are the
	## derivation hooks; applications call `encode` and `decode` instead.
	Format := [Default].{

		## An enumeration dictionary key named a tag the type does not have.
		invalid_value : Format, State -> Error
		invalid_value = |_, _| UnknownTag

		## A named-form record lacked a required field.
		missing_record_field : Format, Str, State -> Error
		missing_record_field = |_, name, _| MissingRequiredField(name)

		## Field names are used as they are.
		rename_field : Format, Str -> Str
		rename_field = |_, name| name

		## A count of UTF-8 bytes, then the bytes.
		encode_str : Str, Enc -> Try(Enc, [])
		encode_str = |value, state| Ok(put(state, |b| write_str(b, value)))

		## A string; `InvalidUtf8` when the bytes are not UTF-8.
		parse_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_str = |_, state| read_str(state)

		## One byte, `0` or `1`.
		encode_bool : Bool, Enc -> Try(Enc, [])
		encode_bool = |value, state| Ok(put(state, |b| b.append(if (value) 1 else 0)))

		## A `Bool`; any byte but `0` or `1` is `Malformed`.
		parse_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_bool = |_, state|
			match state.bytes.get(state.pos) {
				Ok(0) => Ok({ value: False, rest: advance(state, 1) })
				Ok(1) => Ok({ value: True, rest: advance(state, 1) })
				Ok(_) => Err(Malformed)
				Err(_) => Err(Truncated)
			}

		## One byte.
		encode_u8 : U8, Enc -> Try(Enc, [])
		encode_u8 = |value, state| Ok(put(state, |b| b.append(value)))

		## One byte.
		parse_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_u8 = |_, state|
			match state.bytes.get(state.pos) {
				Ok(byte) => Ok({ value: byte, rest: advance(state, 1) })
				Err(_) => Err(Truncated)
			}

		## One byte, two's complement.
		encode_i8 : I8, Enc -> Try(Enc, [])
		encode_i8 = |value, state| Ok(put(state, |b| b.append(I8.to_u8_wrap(value))))

		## One byte, two's complement.
		parse_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_i8 = |_, state| {
			read = read_fixed(state, 1)?
			Ok({ value: U128.to_i8_wrap(read.value), rest: read.rest })
		}

		## Two bytes, little-endian.
		encode_u16 : U16, Enc -> Try(Enc, [])
		encode_u16 = |value, state| Ok(put(state, |b| write_fixed(b, U16.to_u128(value), 2)))

		## Two bytes, little-endian.
		parse_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_u16 = |_, state| {
			read = read_fixed(state, 2)?
			Ok({ value: U128.to_u16_wrap(read.value), rest: read.rest })
		}

		## Two bytes, little-endian, two's complement.
		encode_i16 : I16, Enc -> Try(Enc, [])
		encode_i16 = |value, state| Ok(put(state, |b| write_fixed(b, I16.to_u128_wrap(value), 2)))

		## Two bytes, little-endian, two's complement.
		parse_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_i16 = |_, state| {
			read = read_fixed(state, 2)?
			Ok({ value: U128.to_i16_wrap(read.value), rest: read.rest })
		}

		## Four bytes, little-endian.
		encode_u32 : U32, Enc -> Try(Enc, [])
		encode_u32 = |value, state| Ok(put(state, |b| write_fixed(b, U32.to_u128(value), 4)))

		## Four bytes, little-endian.
		parse_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_u32 = |_, state| {
			read = read_fixed(state, 4)?
			Ok({ value: U128.to_u32_wrap(read.value), rest: read.rest })
		}

		## Four bytes, little-endian, two's complement.
		encode_i32 : I32, Enc -> Try(Enc, [])
		encode_i32 = |value, state| Ok(put(state, |b| write_fixed(b, I32.to_u128_wrap(value), 4)))

		## Four bytes, little-endian, two's complement.
		parse_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_i32 = |_, state| {
			read = read_fixed(state, 4)?
			Ok({ value: U128.to_i32_wrap(read.value), rest: read.rest })
		}

		## Eight bytes, little-endian.
		encode_u64 : U64, Enc -> Try(Enc, [])
		encode_u64 = |value, state| Ok(put(state, |b| write_fixed(b, U64.to_u128(value), 8)))

		## Eight bytes, little-endian.
		parse_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_u64 = |_, state| {
			read = read_fixed(state, 8)?
			Ok({ value: U128.to_u64_wrap(read.value), rest: read.rest })
		}

		## Eight bytes, little-endian, two's complement.
		encode_i64 : I64, Enc -> Try(Enc, [])
		encode_i64 = |value, state| Ok(put(state, |b| write_fixed(b, I64.to_u128_wrap(value), 8)))

		## Eight bytes, little-endian, two's complement.
		parse_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_i64 = |_, state| {
			read = read_fixed(state, 8)?
			Ok({ value: U128.to_i64_wrap(read.value), rest: read.rest })
		}

		## Sixteen bytes, little-endian.
		encode_u128 : U128, Enc -> Try(Enc, [])
		encode_u128 = |value, state| Ok(put(state, |b| write_fixed(b, value, 16)))

		## Sixteen bytes, little-endian.
		parse_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_u128 = |_, state| read_fixed(state, 16)

		## Sixteen bytes, little-endian, two's complement.
		encode_i128 : I128, Enc -> Try(Enc, [])
		encode_i128 = |value, state| Ok(put(state, |b| write_fixed(b, I128.to_u128_wrap(value), 16)))

		## Sixteen bytes, little-endian, two's complement.
		parse_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_i128 = |_, state| {
			read = read_fixed(state, 16)?
			Ok({ value: U128.to_i128_wrap(read.value), rest: read.rest })
		}

		## The IEEE 754 bit pattern, four bytes, little-endian.
		encode_f32 : F32, Enc -> Try(Enc, [])
		encode_f32 = |value, state| Ok(put(state, |b| write_fixed(b, U32.to_u128(F32.to_bits(value)), 4)))

		## The IEEE 754 bit pattern, four bytes, little-endian.
		parse_f32 : Format, State -> Try({ value : F32, rest : State }, Error)
		parse_f32 = |_, state| {
			read = read_fixed(state, 4)?
			Ok({ value: F32.from_bits(U128.to_u32_wrap(read.value)), rest: read.rest })
		}

		## The IEEE 754 bit pattern, eight bytes, little-endian.
		encode_f64 : F64, Enc -> Try(Enc, [])
		encode_f64 = |value, state| Ok(put(state, |b| write_fixed(b, U64.to_u128(F64.to_bits(value)), 8)))

		## The IEEE 754 bit pattern, eight bytes, little-endian.
		parse_f64 : Format, State -> Try({ value : F64, rest : State }, Error)
		parse_f64 = |_, state| {
			read = read_fixed(state, 8)?
			Ok({ value: F64.from_bits(U128.to_u64_wrap(read.value)), rest: read.rest })
		}

		## The attos as sixteen bytes, little-endian, two's complement.
		encode_dec : Dec, Enc -> Try(Enc, [])
		encode_dec = |value, state| Ok(put(state, |b| write_fixed(b, I128.to_u128_wrap(Dec.to_attos(value)), 16)))

		## The attos as sixteen bytes, little-endian, two's complement.
		parse_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_dec = |_, state| {
			read = read_fixed(state, 16)?
			Ok({ value: Dec.from_attos(U128.to_i128_wrap(read.value)), rest: read.rest })
		}

		## A count, then each item.
		encode_list : Enc, U64, (Enc, (Enc, (Enc -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)
		encode_list = |state, count, write_items| {
			inner = write_items(enter(put(state, |b| write_count(b, count))), |current, write_value| write_value(current))?
			Ok(leave(inner))
		}

		## Open a list after checking its count against the input. Lists are
		## driven uncounted, so nothing is preallocated from a claimed count:
		## memory follows the items actually decoded, even when every level of
		## a deep recursive payload claims as many items as the input has bytes.
		parse_list_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_list_start = |_, state| {
			read = read_count(state, 1)?
			Ok(Uncounted(push(read.rest, read.value)?))
		}

		## The next item, or the end of the list.
		parse_list_next : Format, State -> Try([Item(State), Done(State)], Error)
		parse_list_next = |_, state| Ok(if (top(state).remaining == 0) Done(pop(state)) else Item(state))

		## After an item: another, or the end of the list.
		parse_list_after_item : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_list_after_item = |_, state| Ok(after_entry(state))

		## A count of present fields, then the fields: values alone when all
		## are present, otherwise names and values. The positional attempt is
		## rewound in place when an absent field shows the named form is due.
		encode_record : Enc, U64, (Fields, (Fields, Str, (Enc -> Try(Enc, err)) -> Try(Fields, err)) -> Try(Fields, err)) -> Try(Enc, err)
		encode_record = |state, count, write_fields| {
			start = state.bytes.len()
			positional = write_fields(
				{ enc: enter(put(state, |b| write_count(b, count))), present: 0 },
				|current, _, write_value| Ok({ enc: write_value(current.enc)?, present: current.present + 1 }),
			)?
			if positional.present == count {
				return Ok(leave(positional.enc))
			}
			present = positional.present
			rewound = put(positional.enc, |b| b.drop_last(b.len() - start))
			named = write_fields(
				{ enc: put(rewound, |b| write_count(b, present)), present: 0 },
				|current, name, write_value| Ok({ enc: write_value(put(current.enc, |b| write_str(b, name)))?, present: current.present + 1 }),
			)?
			Ok(leave(named.enc))
		}

		## Open a record after checking its count against the input. Its form
		## is settled by its first field event, which knows the type's fields.
		parse_record_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_record_start = |_, state| {
			read = read_count(state, 1)?
			opened = push(read.rest, read.value)?
			Ok(Uncounted(set_top(opened, { ..top(opened), total: unknown_total })))
		}

		## The next field, or the end of the record. The first event counts
		## the type's fields: a count equal to it is the positional form, whose
		## names are cached for the record's lifetime so later fields are
		## found without walking the names again; a smaller count is the named
		## form; a larger one is `Malformed`.
		parse_record_field : Format, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Error)
		parse_record_field = |_, names, state| {
			frame = top(state)
			if frame.total != unknown_total {
				return next_field(state, frame)
			}
			base = state.names.len()
			var $names = state.names
			for name in names.iter() {
				$names = $names.append(name.name())
			}
			total = $names.len() - base
			if frame.remaining > total {
				return Err(Malformed)
			}
			if frame.remaining == total {
				next_field(with_names(state, $names), { ..frame, total, prev_start: base })
			} else {
				next_field(with_names(state, $names.drop_last(total)), { ..frame, total: named_total })
			}
		}

		## After a field: another, or the end of the record.
		parse_record_after_field : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_record_after_field = |_, state| {
			frame = top(state)
			if frame.remaining <= 1 {
				Ok(Done(close_record(state)))
			} else {
				Ok(Continue(set_top(state, { ..frame, remaining: frame.remaining - 1 })))
			}
		}

		## A field the type does not have cannot be skipped: nothing in the
		## format says how long its value is.
		skip_record_field : Format, State -> Try(State, Error)
		skip_record_field = |_, _| Err(Malformed)

		## Each item, with nothing before or between them.
		encode_tuple : Enc, U64, (Enc, (Enc, (Enc -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)
		encode_tuple = |state, _, write_items| {
			inner = write_items(enter(state), |current, write_value| write_value(current))?
			Ok(leave(inner))
		}

		## Open a tuple; its arity is the type's.
		parse_tuple_start : Format, State, U64 -> Try(State, Error)
		parse_tuple_start = |_, state, _| push(state, 0)

		## Nothing separates items.
		parse_tuple_next : Format, State, U64, U64 -> Try(State, Error)
		parse_tuple_next = |_, state, _, _| Ok(state)

		## Close the tuple.
		parse_tuple_end : Format, State, U64 -> Try(State, Error)
		parse_tuple_end = |_, state, _| Ok(pop(state))

		## The tag's name, then its payloads.
		encode_tag : Enc, Str, U64, (Enc, (Enc, (Enc -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)) -> Try(Enc, err)
		encode_tag = |state, name, _, write_payloads| {
			inner = write_payloads(enter(put(state, |b| write_str(b, name))), |current, write_value| write_value(current))?
			Ok(leave(inner))
		}

		## A tag by name; `UnknownTag` when the type has no such tag.
		parse_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, Error)
		parse_tag_union = |encoding, spec, state| {
			name = read_str(state)?
			opened = push(name.rest, 0)?
			parsed = Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag: name.value,
					encoding,
					state: opened,
					start_payloads: |current, _| Ok(current),
					next_payload: |current, _, _| Ok(current),
					finish_payloads: |current, _| Ok(current),
					missing: UnknownTag,
				},
			)?
			Ok({ value: parsed.value, rest: pop(parsed.rest) })
		}

		## A count, then each entry as key and value, sorted by the encoded
		## entry. Encoded keys are distinct and none is a prefix of another,
		## so this is the order of the encoded keys.
		## Each entry is written on its own, inside the dictionary, and keeps
		## whether it nested too deep.
		encode_dict : Enc, U64, (Entries, (Entries, (Enc -> Try(Enc, err)), (Enc -> Try(Enc, err)) -> Try(Entries, err)) -> Try(Entries, err)) -> Try(Enc, err)
		encode_dict = |state, count, write_entries| {
			{ bytes, depth: outer, deep, files } = state
			depth = outer + 1
			written = write_entries(
				{ entries: List.with_capacity(count), deep: deep or depth > max_depth, files },
				|current, write_key, write_value| {
					key = write_key({ bytes: [], depth, deep: current.deep, files: current.files })?
					entry = write_value(key)?
					Ok({ entries: current.entries.append(entry.bytes), deep: entry.deep, files: entry.files })
				},
			)?
			var $out = write_count(bytes, count)
			for entry in written.entries.sort_with(compare_bytes) {
				$out = $out.concat(entry)
			}
			Ok({ bytes: $out, depth: outer, deep: written.deep, files: written.files })
		}

		## Open a dictionary after checking its count against the input.
		parse_dict_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_dict_start = |_, state| {
			read = read_count(state, 2)?
			opened = push(read.rest, read.value)?
			Ok(Uncounted(mark_entry(opened)))
		}

		## The next entry, or the end of the dictionary.
		parse_dict_next : Format, State -> Try([Entry(State), Done(State)], Error)
		parse_dict_next = |_, state| Ok(if (top(state).remaining == 0) Done(pop(state)) else Entry(mark_entry(state)))

		## Between a key and its value: the key must sort strictly after the
		## previous one, which rejects duplicates and keeps decoding canonical.
		parse_dict_after_key : Format, State -> Try(State, Error)
		parse_dict_after_key = |_, state| {
			frame = top(state)
			key_start = frame.total
			if frame.prev_end > frame.prev_start {
				if compare_bytes(slice(state, frame.prev_start, frame.prev_end), slice(state, key_start, state.pos)) != Before {
					return Err(Malformed)
				}
			}
			Ok(set_top(state, { ..frame, prev_start: key_start, prev_end: state.pos }))
		}

		## After an entry: another, or the end of the dictionary.
		parse_dict_after_entry : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_dict_after_entry = |_, state|
			match after_entry(state) {
				Continue(next) => Ok(Continue(mark_entry(next)))
				Done(next) => Ok(Done(next))
			}

		## A structured key is its own encoding, with nothing before it.
		encode_key_start : Format, Enc -> Try(Enc, [])
		encode_key_start = |_, state| Ok(state)

		## A structured key is its own encoding, with nothing before it.
		parse_key_start : Format, State -> Try(State, Error)
		parse_key_start = |_, state| Ok(state)

		## A `Str` key, as a `Str`.
		encode_key_str : Format, Str, Enc -> Try(Enc, [])
		encode_key_str = |_, value, state| Format.encode_str(value, state)

		## A `Str` key, as a `Str`.
		parse_key_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_key_str = |encoding, state| Format.parse_str(encoding, state)

		## A `Bool` key, as a `Bool`.
		encode_key_bool : Format, Bool, Enc -> Try(Enc, [])
		encode_key_bool = |_, value, state| Format.encode_bool(value, state)

		## A `Bool` key, as a `Bool`.
		parse_key_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_key_bool = |encoding, state| Format.parse_bool(encoding, state)

		## A `U8` key, as a `U8`.
		encode_key_u8 : Format, U8, Enc -> Try(Enc, [])
		encode_key_u8 = |_, value, state| Format.encode_u8(value, state)

		## A `U8` key, as a `U8`.
		parse_key_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_key_u8 = |encoding, state| Format.parse_u8(encoding, state)

		## An `I8` key, as an `I8`.
		encode_key_i8 : Format, I8, Enc -> Try(Enc, [])
		encode_key_i8 = |_, value, state| Format.encode_i8(value, state)

		## An `I8` key, as an `I8`.
		parse_key_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_key_i8 = |encoding, state| Format.parse_i8(encoding, state)

		## A `U16` key, as a `U16`.
		encode_key_u16 : Format, U16, Enc -> Try(Enc, [])
		encode_key_u16 = |_, value, state| Format.encode_u16(value, state)

		## A `U16` key, as a `U16`.
		parse_key_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_key_u16 = |encoding, state| Format.parse_u16(encoding, state)

		## An `I16` key, as an `I16`.
		encode_key_i16 : Format, I16, Enc -> Try(Enc, [])
		encode_key_i16 = |_, value, state| Format.encode_i16(value, state)

		## An `I16` key, as an `I16`.
		parse_key_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_key_i16 = |encoding, state| Format.parse_i16(encoding, state)

		## A `U32` key, as a `U32`.
		encode_key_u32 : Format, U32, Enc -> Try(Enc, [])
		encode_key_u32 = |_, value, state| Format.encode_u32(value, state)

		## A `U32` key, as a `U32`.
		parse_key_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_key_u32 = |encoding, state| Format.parse_u32(encoding, state)

		## An `I32` key, as an `I32`.
		encode_key_i32 : Format, I32, Enc -> Try(Enc, [])
		encode_key_i32 = |_, value, state| Format.encode_i32(value, state)

		## An `I32` key, as an `I32`.
		parse_key_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_key_i32 = |encoding, state| Format.parse_i32(encoding, state)

		## A `U64` key, as a `U64`.
		encode_key_u64 : Format, U64, Enc -> Try(Enc, [])
		encode_key_u64 = |_, value, state| Format.encode_u64(value, state)

		## A `U64` key, as a `U64`.
		parse_key_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_key_u64 = |encoding, state| Format.parse_u64(encoding, state)

		## An `I64` key, as an `I64`.
		encode_key_i64 : Format, I64, Enc -> Try(Enc, [])
		encode_key_i64 = |_, value, state| Format.encode_i64(value, state)

		## An `I64` key, as an `I64`.
		parse_key_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_key_i64 = |encoding, state| Format.parse_i64(encoding, state)

		## A `U128` key, as a `U128`.
		encode_key_u128 : Format, U128, Enc -> Try(Enc, [])
		encode_key_u128 = |_, value, state| Format.encode_u128(value, state)

		## A `U128` key, as a `U128`.
		parse_key_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_key_u128 = |encoding, state| Format.parse_u128(encoding, state)

		## An `I128` key, as an `I128`.
		encode_key_i128 : Format, I128, Enc -> Try(Enc, [])
		encode_key_i128 = |_, value, state| Format.encode_i128(value, state)

		## An `I128` key, as an `I128`.
		parse_key_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_key_i128 = |encoding, state| Format.parse_i128(encoding, state)

		## An `F32` key, as an `F32`.
		encode_key_f32 : Format, F32, Enc -> Try(Enc, [])
		encode_key_f32 = |_, value, state| Format.encode_f32(value, state)

		## An `F32` key, as an `F32`.
		parse_key_f32 : Format, State -> Try({ value : F32, rest : State }, Error)
		parse_key_f32 = |encoding, state| Format.parse_f32(encoding, state)

		## An `F64` key, as an `F64`.
		encode_key_f64 : Format, F64, Enc -> Try(Enc, [])
		encode_key_f64 = |_, value, state| Format.encode_f64(value, state)

		## An `F64` key, as an `F64`.
		parse_key_f64 : Format, State -> Try({ value : F64, rest : State }, Error)
		parse_key_f64 = |encoding, state| Format.parse_f64(encoding, state)

		## A `Dec` key, as a `Dec`.
		encode_key_dec : Format, Dec, Enc -> Try(Enc, [])
		encode_key_dec = |_, value, state| Format.encode_dec(value, state)

		## A `Dec` key, as a `Dec`.
		parse_key_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_key_dec = |encoding, state| Format.parse_dec(encoding, state)

		## A tag key without payloads, as its name.
		encode_key_tag : Format, Enc, Str -> Try(Enc, [])
		encode_key_tag = |_, state, name| Ok(leave(put(enter(state), |b| write_str(b, name))))

		## A tag key, as a tag.
		parse_key_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, Error)
		parse_key_tag_union = |encoding, spec, state| Format.parse_tag_union(encoding, spec, state)

		## `Bytes`: a count, then the bytes in one block.
		encode_bytes : Format, List(U8), Enc -> Try(Enc, [])
		encode_bytes = |_, value, state| Ok(put(state, |b| write_count(b, value.len()).concat(value)))

		## A file: its place in the payload's file list, then its name, type,
		## size, and the range of it the value holds. The file itself travels
		## beside the payload.
		encode_file : Format, Core.File, Enc -> Try(Enc, [])
		encode_file = |_, file, { bytes, depth, deep, files }| {
			{ name, mime, size, start, len } = Core.file_parts(file)
			written = write_count(write_count(write_count(write_str(write_str(write_count(bytes, files.len()), name), mime), size), start), len)
			Ok({ bytes: written, depth, deep, files: files.append(file) })
		}

		## A file, holding the bytes that arrived beside the payload at its
		## place, which must be as many as its range.
		parse_file : Format, State -> Try({ value : Core.File, rest : State }, Error)
		parse_file = |_, state| {
			index = read_count(state, 0)?
			name = read_str(index.rest)?
			mime = read_str(name.rest)?
			size = read_count(mime.rest, 0)?
			start = read_count(size.rest, 0)?
			len = read_count(start.rest, 0)?
			contents = state.files.get(index.value) ? |_| Malformed
			if contents.len() != len.value or start.value > size.value or len.value > size.value - start.value {
				return Err(Malformed)
			}
			Ok({ value: Core.worker_file(contents, { name: name.value, mime: mime.value, size: size.value, start: start.value, len: len.value }), rest: len.rest })
		}

		## `Bytes`: a count, then the bytes, shared with the input.
		parse_bytes : Format, State -> Try({ value : List(U8), rest : State }, Error)
		parse_bytes = |_, state| {
			read = read_count(state, 1)?
			Ok({ value: slice(read.rest, read.rest.pos, read.rest.pos + read.value), rest: advance(read.rest, read.value) })
		}
	}
}

## How deep containers may nest in a decoded payload: the bound on the
## decoder's recursion.
max_depth : U64
max_depth = 512

## The encoder's state with `write` applied to its bytes. The state is taken
## apart first so the bytes are written in place.
put : Wire.Enc, (List(U8) -> List(U8)) -> Wire.Enc
put = |{ bytes, depth, deep, files }, write| { bytes: write(bytes), depth, deep, files }

## Open a container in the encoder, noting a depth `decode` would refuse.
enter : Wire.Enc -> Wire.Enc
enter = |{ bytes, depth, deep, files }| { bytes, depth: depth + 1, deep: deep or depth >= max_depth, files }

## Close a container in the encoder.
leave : Wire.Enc -> Wire.Enc
leave = |{ bytes, depth, deep, files }| { bytes, depth: depth - 1, deep, files }

## A record frame whose first field event has not yet counted the type.
unknown_total : U64
unknown_total = U64.highest

## A record frame in the named form.
named_total : U64
named_total = U64.highest - 1

empty_frame : Wire.Frame
empty_frame = { remaining: 0, total: 0, prev_start: 0, prev_end: 0 }

slice : Wire.State, U64, U64 -> List(U8)
slice = |state, start, end| state.bytes.sublist({ start, len: end - start })

advance : Wire.State, U64 -> Wire.State
advance = |state, width| Wire.State.{ bytes: state.bytes, pos: state.pos + width, top: state.top, outer: state.outer, names: state.names, files: state.files }

top : Wire.State -> Wire.Frame
top = |state| state.top

set_top : Wire.State, Wire.Frame -> Wire.State
set_top = |state, frame| Wire.State.{ bytes: state.bytes, pos: state.pos, top: frame, outer: state.outer, names: state.names, files: state.files }

with_names : Wire.State, List(Str) -> Wire.State
with_names = |state, names| Wire.State.{ bytes: state.bytes, pos: state.pos, top: state.top, outer: state.outer, names, files: state.files }

## Open a container holding `remaining` entries. The open frame lives in the
## state itself, so per-entry updates never touch the stack of outer frames.
push : Wire.State, U64 -> Try(Wire.State, Wire.Error)
push = |state, remaining| {
	if state.outer.len() >= max_depth {
		return Err(TooDeep)
	}
	Ok(Wire.State.{ bytes: state.bytes, pos: state.pos, top: { ..empty_frame, remaining }, outer: state.outer.append(state.top), names: state.names, files: state.files })
}

pop : Wire.State -> Wire.State
pop = |state| Wire.State.{ bytes: state.bytes, pos: state.pos, top: state.outer.last() ?? empty_frame, outer: state.outer.drop_last(1), names: state.names, files: state.files }

## The next field event of the open record, whose form is settled.
next_field : Wire.State, Wire.Frame -> Try([Field(_field), TryField({ name : Str, rest : Wire.State }), TryFieldCaseless({ name : Str, rest : Wire.State }), Continue(Wire.State), Done(Wire.State)], Wire.Error)
next_field = |state, frame| {
	if frame.remaining == 0 {
		return Ok(Done(close_record(set_top(state, frame))))
	}
	if frame.total == named_total {
		name = read_str(state)?
		end = name.rest.pos
		start = end - Str.count_utf8_bytes(name.value)
		if frame.prev_end > frame.prev_start and compare_bytes(slice(state, frame.prev_start, frame.prev_end), slice(state, start, end)) != Before {
			return Err(Malformed)
		}
		return Ok(TryField({ name: name.value, rest: set_top(name.rest, { ..frame, prev_start: start, prev_end: end }) }))
	}
	# The cached names hold this record's fields from prev_start, so the
	# index is always in range.
	name = state.names.get(frame.prev_start + frame.total - frame.remaining) ?? ""
	Ok(TryField({ name, rest: set_top(state, frame) }))
}

## Close the open record, releasing the names its positional form cached.
close_record : Wire.State -> Wire.State
close_record = |state| {
	frame = top(state)
	if frame.total == named_total {
		pop(state)
	} else {
		pop(with_names(state, state.names.drop_last(state.names.len() - frame.prev_start)))
	}
}

## Remember where a dictionary entry, and so its key, starts.
mark_entry : Wire.State -> Wire.State
mark_entry = |state| set_top(state, { ..top(state), total: state.pos })

after_entry : Wire.State -> [Continue(Wire.State), Done(Wire.State)]
after_entry = |state| {
	frame = top(state)
	if frame.remaining <= 1 {
		Done(pop(state))
	} else {
		Continue(set_top(state, { ..frame, remaining: frame.remaining - 1 }))
	}
}

write_fixed : List(U8), U128, U64 -> List(U8)
write_fixed = |state, value, width| {
	var $output = state
	var $remaining = value
	var $index = 0
	while $index < width {
		$output = $output.append(U128.to_u8_wrap($remaining))
		$remaining = U128.shr_zf_wrap($remaining, 8)
		$index = $index + 1
	}
	$output
}

read_fixed : Wire.State, U64 -> Try({ value : U128, rest : Wire.State }, Wire.Error)
read_fixed = |state, width| {
	if state.bytes.len() - state.pos < width {
		return Err(Truncated)
	}
	var $value = U128.to_u128(0)
	var $index = width
	while $index > 0 {
		$index = $index - 1
		# In range: the width was checked against the input above.
		$value = U128.bitwise_or(U128.shl_wrap($value, 8), U8.to_u128(state.bytes.get(state.pos + $index) ?? 0))
	}
	Ok({ value: $value, rest: advance(state, width) })
}

write_count : List(U8), U64 -> List(U8)
write_count = |state, value| {
	var $output = state
	var $remaining = value
	while $remaining >= 0x80 {
		$output = $output.append(U8.bitwise_or(U64.to_u8_wrap($remaining), 0x80))
		$remaining = U64.shr_zf_wrap($remaining, 7)
	}
	$output.append(U64.to_u8_wrap($remaining))
}

## Read a count of entries that each take at least `min_size` bytes, refusing
## a count the rest of the input cannot hold before anything is allocated. A
## `min_size` of 0 reads a number that counts nothing in the input (a file's
## size), which is not bounded by it.
read_count : Wire.State, U64 -> Try({ value : U64, rest : Wire.State }, Wire.Error)
read_count = |state, min_size| {
	var $value = 0
	var $shift = 0
	var $pos = state.pos
	var $done = False
	while !$done {
		byte = state.bytes.get($pos) ? |_| Truncated
		# The tenth byte holds bit 63 alone; a zero byte after the first
		# would make the count non-minimal.
		if ($shift == 63 and byte > 1) or ($shift > 0 and byte == 0) {
			return Err(Malformed)
		}
		$value = U64.bitwise_or($value, U64.shl_wrap(U8.to_u64(U8.bitwise_and(byte, 0x7F)), $shift))
		$pos = $pos + 1
		if byte < 0x80 {
			$done = True
		} else {
			$shift = $shift + 7
		}
	}
	if min_size > 0 and $value > (state.bytes.len() - $pos) / min_size {
		return Err(Truncated)
	}
	Ok({ value: $value, rest: Wire.State.{ bytes: state.bytes, pos: $pos, top: state.top, outer: state.outer, names: state.names, files: state.files } })
}

write_str : List(U8), Str -> List(U8)
write_str = |state, value| write_count(state, Str.count_utf8_bytes(value)).concat(Str.to_utf8(value))

read_str : Wire.State -> Try({ value : Str, rest : Wire.State }, Wire.Error)
read_str = |state| {
	read = read_count(state, 1)?
	value = Str.from_utf8(slice(read.rest, read.rest.pos, read.rest.pos + read.value)) ? |_| InvalidUtf8
	Ok({ value, rest: advance(read.rest, read.value) })
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |left, right| {
	var $index = 0
	while $index < left.len() and $index < right.len() {
		# In range: both indices are below the lengths checked above.
		l = left.get($index) ?? 0
		r = right.get($index) ?? 0
		if l < r {
			return Before
		}
		if l > r {
			return After
		}
		$index = $index + 1
	}
	if left.len() < right.len() {
		Before
	} else if left.len() > right.len() {
		After
	} else {
		Same
	}
}

## Whether a value comes back from its own payload unchanged.
round_trips : a -> Bool where [a.Wire.Sendable, a.is_eq : a, a -> Bool]
round_trips = |value|
	match Wire.decode(Wire.encode(value)) {
		Ok(decoded) => decoded == value
		Err(_) => False
	}

## Whether a value's payload, decoded and encoded again, is the same bytes.
## Floats are compared this way, since a NaN is not equal to itself.
same_bytes : a -> Bool where [a.Wire.Sendable]
same_bytes = |value| {
	payload = Wire.encode(value)
	decoded : Try(a, Wire.Error)
	decoded = Wire.decode(payload)
	match decoded {
		Ok(back) => Wire.encode(back) == payload
		Err(_) => False
	}
}

## Whether every strict prefix of a payload is refused.
prefixes_refused : List(U8), (List(U8) -> Bool) -> Bool
prefixes_refused = |payload, accepted| {
	var $length = 0
	var $all = True
	while $length < payload.len() {
		if accepted(payload.take_first($length)) {
			$all = False
		}
		$length = $length + 1
	}
	$all
}

Profile : { name : Str, nick ?: Str, age ?: U8 }

Sample : { shapes : List(Shape), text : Str, index : Dict(Str, List(U64)), who : Profile }

Shape : [Dot, Circle(F64), Rect({ w : U32, h : U32 }), Path(List((I16, I16)))]

Tree := [Leaf, Node(Tree, U64, Tree)].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

Nested := { children : List(Nested) }.{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## A tree nested `depth` levels down its left branch.
left_spine : U64 -> Tree
left_spine = |depth| {
	var $tree = Tree.Leaf
	var $level = 0
	while $level < depth {
		$tree = Tree.Node($tree, $level, Tree.Leaf)
		$level = $level + 1
	}
	$tree
}

## Unsigned integers round trip at both ends of every width.
expect {
	round_trips(0.U8) and round_trips(U8.highest) and round_trips(U16.highest) and round_trips(U32.highest) and round_trips(U64.highest) and round_trips(U128.highest)
}

## Signed integers round trip at both ends of every width.
expect {
	ends_8 = round_trips(I8.lowest) and round_trips(I8.highest)
	ends_16 = round_trips(I16.lowest) and round_trips(I16.highest)
	ends_32 = round_trips(I32.lowest) and round_trips(I32.highest)
	ends_64 = round_trips(I64.lowest) and round_trips(I64.highest)
	ends_128 = round_trips(I128.lowest) and round_trips(I128.highest) and round_trips(-1.I128)
	ends_8 and ends_16 and ends_32 and ends_64 and ends_128
}

## Dec round trips at both ends and in between.
expect round_trips(Dec.lowest) and round_trips(Dec.highest) and round_trips(-1.5.Dec) and round_trips(0.0.Dec)

## Floats keep their bit patterns: signed zero, infinities, the largest
## values and NaN.
expect {
	values = (F64.from_bits(0x8000000000000000), F64.infinity, -F64.infinity, F64.nan, F64.highest, F32.from_bits(0x80000000), F32.infinity, F32.nan)
	payload = Wire.encode(values)
	decoded : Try((F64, F64, F64, F64, F64, F32, F32, F32), Wire.Error)
	decoded = Wire.decode(payload)
	match decoded {
		Ok((a, b, c, d, e, f, g, h)) => {
			doubles = [F64.to_bits(a), F64.to_bits(b), F64.to_bits(c), F64.to_bits(d), F64.to_bits(e)] == [F64.to_bits(values.0), F64.to_bits(values.1), F64.to_bits(values.2), F64.to_bits(values.3), F64.to_bits(values.4)]
			singles = [F32.to_bits(f), F32.to_bits(g), F32.to_bits(h)] == [F32.to_bits(values.5), F32.to_bits(values.6), F32.to_bits(values.7)]
			doubles and singles and F64.is_nan(d) and same_bytes(values)
		}
		Err(_) => False
	}
}

## Bool, and strings including the empty string and multibyte characters.
expect round_trips(Bool.True) and round_trips(Bool.False) and round_trips("") and round_trips("héllo 🦊")

## Lists, including empty ones and lists of empty records.
expect {
	empty : List(U64)
	empty = []
	round_trips(empty) and round_trips([1.U8, 2, 3]) and round_trips([[], ["a"], ["b", ""]]) and round_trips([{}, {}, {}])
}

## Tuples, records and empty records, nested in each other.
expect round_trips((1.U8, "x", [Bool.True])) and round_trips({ zeta: 1.U64, alpha: [2.U8], mid: { inner: ("m", -4.I16) } }) and round_trips({})

## Tag unions with and without payloads, and payloads holding records,
## lists and tuples.
expect {
	shapes : List(Shape)
	shapes = [Dot, Circle(1.5), Rect({ w: 3, h: 4 }), Path([(1, -1), (I16.lowest, I16.highest)])]
	edges : List(Shape)
	edges = [Path([]), Rect({ w: 0, h: U32.highest })]
	same_bytes(shapes) and same_bytes(edges)
}

## `Try` fields, including the `Missing` error derivation treats as optional.
expect {
	value : { t : Try(Str, [Missing]), u : Try(U8, [Missing]) }
	value = { t: Err(Missing), u: Ok(3) }
	round_trips(value)
}

## Optional fields round trip present, absent and partly present.
expect {
	all : Profile
	all = { name: "n", nick: "k", age: 3 }
	none : Profile
	none = { name: "n" }
	some : Profile
	some = { name: "n", age: 9 }
	round_trips(all) and round_trips(none) and round_trips(some)
}

## Optional fields nested in lists and other records.
expect {
	inner : List(Profile)
	inner = [{ name: "a" }, { name: "b", nick: "c" }]
	value : { people : List(Profile), lead : Profile }
	value = { people: inner, lead: { name: "z", age: 1 } }
	round_trips(value)
}

## Dictionaries, including the empty one, enumeration keys and number keys;
## sets.
expect {
	empty : Dict(Str, U8)
	empty = Dict.empty()
	words = round_trips(Dict.from_list([("b", 2.U64), ("a", 1), ("c", 3)]))
	tags = round_trips(Dict.from_list([(Red, [1.U8]), (Green, [])]))
	numbers = round_trips(Dict.from_list([(-1.I32, "x"), (2, "y")]))
	words and tags and numbers and round_trips(empty) and round_trips(Set.from_list(["x", "y"]))
}

## Equal dictionaries encode alike, however they were built.
expect Wire.encode(Dict.from_list([("b", 2.U8), ("a", 1)])) == Wire.encode(Dict.from_list([("a", 1.U8), ("b", 2)]))

## Nominal types that opt in, recursive ones included.
expect round_trips(Tree.Node(Tree.Leaf, 3, Tree.Node(Tree.Leaf, 4, Tree.Leaf))) and round_trips(Nested.{ children: [Nested.{ children: [] }, Nested.{ children: [Nested.{ children: [] }] }] })

## `Bytes` round trips, and is laid out exactly as the `List(U8)` it wraps.
expect {
	bytes = Wire.Bytes.from_list([0, 1, 255])
	decoded : Try(List(U8), Wire.Error)
	decoded = Wire.decode(Wire.encode(bytes))
	round_trips(bytes) and Wire.encode(bytes) == Wire.encode([0.U8, 1, 255]) and decoded == Ok([0, 1, 255])
}

## Exact bytes pin the layout of numbers, Bool and strings.
expect {
	actual =
		\\u16: ${Str.inspect(Wire.encode(258.U16))}
		\\i32: ${Str.inspect(Wire.encode(-2.I32))}
		\\f64: ${Str.inspect(Wire.encode(1.0.F64))}
		\\dec: ${Str.inspect(Wire.encode(0.000000000000000001.Dec))}
		\\bool: ${Str.inspect(Wire.encode((Bool.True, Bool.False)))}
		\\str: ${Str.inspect(Wire.encode("hé"))}
	expected =
		\\u16: [2, 1]
		\\i32: [254, 255, 255, 255]
		\\f64: [0, 0, 0, 0, 0, 0, 240, 63]
		\\dec: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
		\\bool: [1, 0]
		\\str: [3, 104, 195, 169]
	actual == expected
}

## Exact bytes pin the layout of containers: field order, both record forms,
## tags, sorted dictionary entries and a two-byte count.
expect {
	some : Profile
	some = { name: "n", age: 9 }
	tag : [Small, Large(U8)]
	tag = Large(7)
	long = Wire.encode(List.repeat(0.U8, 300)).take_first(3)
	actual =
		\\record: ${Str.inspect(Wire.encode({ b9: 1.U8, b10: 2.U8, a_b: 3.U8, a1: 4.U8, a: 5.U8 }))}
		\\named: ${Str.inspect(Wire.encode(some))}
		\\empty: ${Str.inspect(Wire.encode({}))}
		\\tag: ${Str.inspect(Wire.encode(tag))}
		\\dict: ${Str.inspect(Wire.encode(Dict.from_list([("b", 2.U8), ("a", 1)])))}
		\\count: ${Str.inspect(long)}
	expected =
		\\record: [5, 5, 4, 3, 2, 1]
		\\named: [2, 3, 97, 103, 101, 9, 4, 110, 97, 109, 101, 1, 110]
		\\empty: [0]
		\\tag: [5, 76, 97, 114, 103, 101, 7]
		\\dict: [2, 1, 97, 1, 1, 98, 2]
		\\count: [172, 2, 0]
	actual == expected
}

## Every strict prefix of a payload is refused, for every shape at once.
expect {
	value : Sample
	value = { shapes: [Rect({ w: 1, h: 2 }), Path([(3, 4)])], text: "some text", index: Dict.from_list([("k", [1])]), who: { name: "n", age: 2 } }
	accepted = |bytes| {
		decoded : Try(Sample, Wire.Error)
		decoded = Wire.decode(bytes)
		decoded.is_ok()
	}
	prefixes_refused(Wire.encode(value), accepted)
}

## Input left after the value is refused.
expect {
	decoded : Try({ a : U8 }, Wire.Error)
	decoded = Wire.decode(Wire.encode({ a: 1.U8 }).append(0))
	decoded == Err(TrailingBytes)
}

## A tag name the type does not have is refused.
expect {
	decoded : Try([Small, Large(U8)], Wire.Error)
	decoded = Wire.decode([4, 72, 117, 103, 101, 1])
	decoded == Err(UnknownTag)
}

## A count larger than the rest of the input is refused before anything is
## allocated for it, however large it claims to be.
expect {
	text : Try(Str, Wire.Error)
	text = Wire.decode([5, 97])
	huge : Try(List(U64), Wire.Error)
	huge = Wire.decode([255, 255, 255, 255, 255, 255, 255, 255, 255, 1])
	units : Try(List({}), Wire.Error)
	units = Wire.decode([3, 0, 0])
	text == Err(Truncated) and huge == Err(Truncated) and units == Err(Truncated)
}

## Invalid UTF-8 in a string is refused.
expect {
	decoded : Try(Str, Wire.Error)
	decoded = Wire.decode([2, 195, 40])
	decoded == Err(InvalidUtf8)
}

## Non-canonical scalars and counts are refused: a Bool byte above 1, a
## count with a redundant zero group, and one that overflows a U64.
expect {
	flag : Try(Bool, Wire.Error)
	flag = Wire.decode([2])
	padded : Try(Str, Wire.Error)
	padded = Wire.decode([0x80, 0x00])
	overflow : Try(List(U8), Wire.Error)
	overflow = Wire.decode([255, 255, 255, 255, 255, 255, 255, 255, 255, 2])
	flag == Err(Malformed) and padded == Err(Malformed) and overflow == Err(Malformed)
}

## A record count above the type's field count, a named field out of order,
## a named field the type lacks, and a missing required field are refused.
expect {
	wide : Try({ a : U8, b : U8 }, Wire.Error)
	wide = Wire.decode([3, 1, 2, 3])
	unordered : Try(Profile, Wire.Error)
	unordered = Wire.decode([2, 4, 110, 97, 109, 101, 1, 110, 3, 97, 103, 101, 9])
	unknown : Try(Profile, Wire.Error)
	unknown = Wire.decode([1, 3, 122, 122, 122, 9])
	missing : Try(Profile, Wire.Error)
	missing = Wire.decode([1, 3, 97, 103, 101, 9])
	wide == Err(Malformed) and unordered == Err(Malformed) and unknown == Err(Malformed) and missing == Err(MissingRequiredField("name"))
}

## Dictionary keys out of order, or repeated, are refused.
expect {
	unordered : Try(Dict(Str, U8), Wire.Error)
	unordered = Wire.decode([2, 1, 98, 2, 1, 97, 1])
	repeated : Try(Dict(Str, U8), Wire.Error)
	repeated = Wire.decode([2, 1, 97, 1, 1, 97, 2])
	unordered.is_err() and repeated.is_err() and unordered == Err(Malformed) and repeated == Err(Malformed)
}

## Nesting is bounded: 512 levels decode, deeper payloads are refused, whether
## the recursion goes through tags or through lists alone.
expect {
	deep_tree : Try(Tree, Wire.Error)
	deep_tree = Wire.decode(Wire.encode(left_spine(511)))
	too_deep_tree : Try(Tree, Wire.Error)
	too_deep_tree = Wire.decode(Wire.encode(left_spine(513)))
	too_deep_list : Try(Nested, Wire.Error)
	too_deep_list = Wire.decode(List.repeat([1, 1], 600).join().append(0))
	deep_tree == Ok(left_spine(511)) and too_deep_tree == Err(TooDeep) and too_deep_list == Err(TooDeep)
}

## The encoder knows the same bound: `try_encode` accepts exactly the values
## whose payloads decode, at the edge of the bound and on either side of it,
## through tags, lists, records and dictionaries alike, and `encode` still
## encodes the rest.
expect {
	decodes = |tree| {
		decoded : Try(Tree, Wire.Error)
		decoded = Wire.decode(Wire.encode(tree))
		decoded.is_ok()
	}
	agree = |depth| {
		tree = left_spine(depth)
		Wire.try_encode(tree).is_ok() == decodes(tree)
	}
	edge = agree(510) and agree(511) and agree(512) and agree(600)
	refused = Wire.try_encode(left_spine(512)) == Err(TooDeep) and Wire.try_encode(left_spine(511)) == Ok(Wire.encode(left_spine(511)))
	nest = |depth| {
		var $value = Nested.{ children: [] }
		var $level = 1
		while $level < depth {
			$value = Nested.{ children: [$value] }
			$level = $level + 1
		}
		$value
	}
	nested_agree = |depth| {
		value = nest(depth)
		decoded : Try(Nested, Wire.Error)
		decoded = Wire.decode(Wire.encode(value))
		Wire.try_encode(value).is_ok() == decoded.is_ok()
	}
	lists = nested_agree(255) and nested_agree(256) and nested_agree(257) and Wire.try_encode(nest(256)).is_ok() and Wire.try_encode(nest(257)).is_err()
	wrapped_agree = |depth| {
		in_dict = Dict.from_list([("k", left_spine(depth))])
		dict_decoded : Try(Dict(Str, Tree), Wire.Error)
		dict_decoded = Wire.decode(Wire.encode(in_dict))
		in_record = { inner: left_spine(depth) }
		record_decoded : Try({ inner : Tree }, Wire.Error)
		record_decoded = Wire.decode(Wire.encode(in_record))
		Wire.try_encode(in_dict).is_ok() == dict_decoded.is_ok() and Wire.try_encode(in_record).is_ok() == record_decoded.is_ok()
	}
	wrapped = wrapped_agree(509) and wrapped_agree(510) and wrapped_agree(511) and Wire.try_encode({ inner: left_spine(511) }).is_err()
	edge and refused and lists and wrapped
}

## Files travel beside the payload: decoding with the file list gives each
## file the bytes at its place, and a payload naming a file that is not
## there, or whose bytes are not its range, is refused.
expect {
	a = Core.worker_file([1, 2, 3], { name: "a.bin", mime: "", size: 10, start: 4, len: 3 })
	b = Core.worker_file([], { name: "b.txt", mime: "text/plain", size: 0, start: 0, len: 0 })
	sent = Wire.encode_with_files({ note: "x", docs: [a, b] })
	contents = sent.files.map(|f| f.contents())
	back : Try({ note : Str, docs : List(Core.File) }, Wire.Error)
	back = Wire.decode_with_files(sent.bytes, contents)
	missing : Try({ note : Str, docs : List(Core.File) }, Wire.Error)
	missing = Wire.decode_with_files(sent.bytes, contents.take_first(1))
	short : Try({ note : Str, docs : List(Core.File) }, Wire.Error)
	short = Wire.decode_with_files(sent.bytes, [[1, 2], []])
	back == Ok({ note: "x", docs: [a, b] }) and missing == Err(Malformed) and short == Err(Malformed) and contents == [[1, 2, 3], []]
}
