import Core
import Wire

## The format of port messages: JSON text for JavaScript the platform did not
## write, with bulk bytes carried raw beside it.
##
## A port's other end is app-authored JavaScript, which knows nothing of Roc's
## types, so a message is JSON: the one encoding every JavaScript value maps
## onto without a codec. Roc's `encoder_for` and `parser_for` derivation drives
## it, so records, tuples, tag unions, lists, sets, dictionaries, strings,
## numbers and `Bool` need no codec written by hand, exactly as with `Wire`.
##
## Bytes never become text. A message is the JSON text plus a list of *blobs*:
## a `Wire.Bytes` value is written as the marker `{"$bytes":N}`, where `N` is
## its index in the blob list, and the bytes themselves travel beside the text.
## The runtime hands JavaScript a `Uint8Array` where the marker stood, and
## turns a `Uint8Array` or `ArrayBuffer` in an answer back into a marker and a
## blob, so a payload of megabytes is copied, never base64-encoded.
##
## The encoding, for the JavaScript side and for a second implementation:
##
## - `U8` to `U32` and `I8` to `I32` are JSON numbers. `U64`, `I64`, `U128` and
##   `I128` are JSON strings of their decimal digits, because a JavaScript
##   number holds integers exactly only up to 2^53 (use `BigInt(text)`).
##   Decoding accepts either form for every width: a string of decimal digits,
##   or a JSON number without fraction or exponent, which for the 64- and
##   128-bit widths must also be a safe integer (at most 2^53 - 1 in
##   magnitude), since a larger JavaScript number was already rounded.
## - `F32` and `F64` are JSON numbers, in the shortest form that reads back
##   to the same value. A NaN or an infinity, which JSON has no number for, is
##   the string `"NaN"`, `"Infinity"` or `"-Infinity"`, and decoding accepts
##   those strings as well as numbers.
## - `Dec` is a JSON string of its decimal digits, so no digit is lost to a
##   JavaScript number. Decoding accepts a string or a number.
## - `Bool` is `true` or `false`; `Str` is a JSON string. Characters other
##   than the quote, the backslash and the controls are written as they are.
## - `List(a)` and `Set(a)` are arrays; a tuple is an array of its items.
## - A record is an object whose keys are the field names as written in Roc,
##   in ascending byte order. A field of type `Try(a, [Missing])` is optional:
##   it is left out when `Missing`. Decoding ignores keys the type does not
##   have, reads a key whose value is `null` as absent, and reads `null` in
##   place of a record as a record with no fields, so JavaScript's
##   `undefined` (sent as `null`) answers a request whose reply is `{}`.
## - A tag without payloads is its name as a string (`"Red"`); a tag with one
##   payload is an object with one key (`{"Some":1}`); a tag with several is
##   an object whose value is an array (`{"Rgb":[1,2,3]}`).
## - `Dict(k, v)` is an object, its entries in ascending byte order of their
##   keys. A key is a string: a `Str` as it is, a number or `Bool` as its
##   JSON text (`"5"`, `"true"`), and a tag without payloads as its name. A
##   dictionary keyed by anything else is not `Sendable`. A key that begins
##   with `$` is written with one more `$`, so no key can be mistaken for a
##   marker; decoding removes it again.
## - `Wire.Bytes` is the marker `{"$bytes":N}`. A plain `List(U8)` is an
##   array of numbers like any other list, so send bulk bytes as
##   `Wire.Bytes`.
## - A file (`Engine.File`) is the marker `{"$file":N}`, where `N` is its
##   index in the message's file list; the runtime hands JavaScript the
##   browser's own `File` (sliced to the range the value holds) where the
##   marker stood, and turns a `File` or `Blob` in an answer back into a
##   marker and a file handle. A file's bytes never cross.
##
## Encoding cannot fail. Decoding is total: input that does not follow the
## grammar of RFC 8259 or does not fit the type is an `Err`, never a crash,
## containers nest at most 512 deep, and nothing is allocated for input that
## is not there. JavaScript is not trusted to be canonical: whitespace, key
## order and the escapes it chooses do not matter.
PortJson := [].{

	## Why a message did not decode. Offsets count bytes of the JSON text.
	##
	## - `Syntax(at)`: the text is not JSON there.
	## - `Expected(what, at)`: JSON of another kind than the type needs.
	## - `OutOfRange(at)`: a number outside its type's range, a fraction where
	##   an integer belongs, or an integer JavaScript cannot hold exactly.
	## - `UnknownTag(name)`: a tag the type does not have.
	## - `MissingRequiredField(name)`: a required record field is absent.
	## - `NoSuchBlob(n)`: a bytes marker names a blob the message does not
	##   carry.
	## - `NoSuchFile(n)`: a file marker names a file the message does not
	##   carry.
	## - `TooDeep`: containers nested more than 512 deep.
	## - `Trailing(at)`: text after the value.
	Error : [Syntax(U64), Expected(Str, U64), OutOfRange(U64), UnknownTag(Str), MissingRequiredField(Str), NoSuchBlob(U64), NoSuchFile(U64), TooDeep, Trailing(U64)]

	## A message: the JSON text, the blobs its bytes markers index and the
	## files its file markers index. It is `Engine.PortMessage`.
	Message : { json : Str, blobs : List(List(U8)), files : List(Core.File) }

	## A type whose values can be sent to and received from JavaScript:
	## everything derivation covers, and nominal types that declare
	## `parser_for : _` and `encoder_for : _`. Functions, `Try` (other than an
	## optional record field), and dictionaries keyed by records, tuples or
	## tags with payloads are excluded, and the compiler reports the use that
	## needs them.
	a.Sendable :
		where [
			a.encoder_for : Format -> (a, Out -> Try(Out, [])),
			a.parser_for : Format -> (State -> Try({ value : a, rest : State }, Error)),
		]

	## Encode a value as a message. It cannot fail, and equal values encode to
	## equal text, with two exceptions the compiler gives a format no way to
	## close: a `Set` is written in its iteration order, and a dictionary's
	## blobs are numbered in the order its entries were visited.
	encode : a -> Message where [a.Sendable]
	encode = |value| {
		## The caller's type, named so its derived codec can be asked for.
		Shape : a
		encode_shape = Shape.encoder_for(Format.Default)
		match encode_shape(value, Out.{ text: [], blobs: [], files: [] }) {
			Ok(out) => { json: Str.from_utf8(out.text) ?? crash "internal: PortJson wrote text that is not UTF-8", blobs: out.blobs, files: out.files }
		}
	}

	## Decode a message as a value of the type the caller expects. The text
	## must hold exactly one value, with nothing but whitespace after it.
	## Decoded `Wire.Bytes` share the blob they name instead of copying it.
	decode : Message -> Try(a, Error) where [a.Sendable]
	decode = |{ json, blobs, files }| {
		## The caller's type, named so its derived codec can be asked for.
		Shape : a
		parse_shape = Shape.parser_for(Format.Default)
		text = Str.to_utf8(json)
		read = parse_shape(State.{ text, pos: 0, blobs, files, depth: 0, null_record: False })?
		end = skip_ws(read.rest)
		if (end.pos == text.len()) Ok(read.value) else Err(Trailing(end.pos))
	}

	## A sentence for an `Error`, for diagnostics and for the typed port
	## layer's `Undecodable` text.
	describe : Error -> Str
	describe = |error|
		match error {
			Syntax(at) => "not JSON at byte ${at.to_str()}"
			Expected(what, at) => "expected ${what} at byte ${at.to_str()}"
			OutOfRange(at) => "number out of range for its type at byte ${at.to_str()}"
			UnknownTag(name) => "unknown tag \"${name}\""
			MissingRequiredField(name) => "missing field \"${name}\""
			NoSuchBlob(n) => "bytes marker names blob ${n.to_str()}, which the message does not carry"
			NoSuchFile(n) => "file marker names file ${n.to_str()}, which the message does not carry"
			TooDeep => "containers nested more than ${max_depth.to_str()} deep"
			Trailing(at) => "text after the value at byte ${at.to_str()}"
		}

	## The encoder's output: JSON text so far, and the blobs it has written.
	## Applications never construct one.
	Out := { text : List(U8), blobs : List(List(U8)), files : List(Core.File) }

	## The decoder's cursor: the text, the position, the message's blobs, how
	## deep the open containers are, and whether a `null` is standing in for
	## the record being read. Applications never construct one.
	State := { text : List(U8), pos : U64, blobs : List(List(U8)), files : List(Core.File), depth : U64, null_record : Bool }

	## The format marker the compiler dispatches on. Its methods are the
	## derivation hooks; applications call `encode` and `decode` instead.
	Format := [Default].{

		## A key of an enumeration dictionary named a tag the type lacks.
		invalid_value : Format, State -> Error
		invalid_value = |_, state| Expected("a known tag", state.pos)

		## A record lacked a required field.
		missing_record_field : Format, Str, State -> Error
		missing_record_field = |_, name, _| MissingRequiredField(name)

		## Field names are used as they are written in Roc.
		rename_field : Format, Str -> Str
		rename_field = |_, name| name

		## A JSON string.
		encode_str : Str, Out -> Try(Out, [])
		encode_str = |value, out| Ok(write(out, |t| write_string(t, value)))

		## A JSON string.
		parse_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_str = |_, state| read_string(skip_ws(state))

		## `true` or `false`.
		encode_bool : Bool, Out -> Try(Out, [])
		encode_bool = |value, out| Ok(write(out, |t| t.concat(Str.to_utf8(if (value) "true" else "false"))))

		## `true` or `false`.
		parse_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_bool = |_, state| {
			s = skip_ws(state)
			if literal(s, "true") {
				Ok({ value: True, rest: advance(s, 4) })
			} else if literal(s, "false") {
				Ok({ value: False, rest: advance(s, 5) })
			} else {
				Err(Expected("true or false", s.pos))
			}
		}

		## A JSON number.
		encode_u8 : U8, Out -> Try(Out, [])
		encode_u8 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_u8 = |_, state| parse_int(state, Narrow, U8.from_str)

		## A JSON number.
		encode_i8 : I8, Out -> Try(Out, [])
		encode_i8 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_i8 = |_, state| parse_int(state, Narrow, I8.from_str)

		## A JSON number.
		encode_u16 : U16, Out -> Try(Out, [])
		encode_u16 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_u16 = |_, state| parse_int(state, Narrow, U16.from_str)

		## A JSON number.
		encode_i16 : I16, Out -> Try(Out, [])
		encode_i16 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_i16 = |_, state| parse_int(state, Narrow, I16.from_str)

		## A JSON number.
		encode_u32 : U32, Out -> Try(Out, [])
		encode_u32 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_u32 = |_, state| parse_int(state, Narrow, U32.from_str)

		## A JSON number.
		encode_i32 : I32, Out -> Try(Out, [])
		encode_i32 = |value, out| Ok(write_number(out, value.to_str()))

		## A JSON number or a string of digits.
		parse_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_i32 = |_, state| parse_int(state, Narrow, I32.from_str)

		## A string of digits: JavaScript numbers cannot hold every `U64`.
		encode_u64 : U64, Out -> Try(Out, [])
		encode_u64 = |value, out| Ok(write_digits(out, value.to_str()))

		## A string of digits, or a safe-integer JSON number.
		parse_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_u64 = |_, state| parse_int(state, Wide, U64.from_str)

		## A string of digits: JavaScript numbers cannot hold every `I64`.
		encode_i64 : I64, Out -> Try(Out, [])
		encode_i64 = |value, out| Ok(write_digits(out, value.to_str()))

		## A string of digits, or a safe-integer JSON number.
		parse_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_i64 = |_, state| parse_int(state, Wide, I64.from_str)

		## A string of digits.
		encode_u128 : U128, Out -> Try(Out, [])
		encode_u128 = |value, out| Ok(write_digits(out, value.to_str()))

		## A string of digits, or a safe-integer JSON number.
		parse_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_u128 = |_, state| parse_int(state, Wide, U128.from_str)

		## A string of digits.
		encode_i128 : I128, Out -> Try(Out, [])
		encode_i128 = |value, out| Ok(write_digits(out, value.to_str()))

		## A string of digits, or a safe-integer JSON number.
		parse_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_i128 = |_, state| parse_int(state, Wide, I128.from_str)

		## The shortest JSON number that reads back to the value; `"NaN"`,
		## `"Infinity"` or `"-Infinity"` for the values JSON has no number for.
		encode_f32 : F32, Out -> Try(Out, [])
		encode_f32 = |value, out| {
			text =
				if F32.is_nan(value) {
					"\"NaN\""
				} else if value > F32.highest {
					"\"Infinity\""
				} else if value < F32.lowest {
					"\"-Infinity\""
				} else {
					value.to_str()
				}
			Ok(write_number(out, text))
		}

		## A JSON number, or one of the strings for NaN and the infinities.
		parse_f32 : Format, State -> Try({ value : F32, rest : State }, Error)
		parse_f32 = |_, state| parse_float(state, F32.from_str)

		## The shortest JSON number that reads back to the value; `"NaN"`,
		## `"Infinity"` or `"-Infinity"` for the values JSON has no number for.
		encode_f64 : F64, Out -> Try(Out, [])
		encode_f64 = |value, out| {
			text =
				if F64.is_nan(value) {
					"\"NaN\""
				} else if value > F64.highest {
					"\"Infinity\""
				} else if value < F64.lowest {
					"\"-Infinity\""
				} else {
					value.to_str()
				}
			Ok(write_number(out, text))
		}

		## A JSON number, or one of the strings for NaN and the infinities.
		parse_f64 : Format, State -> Try({ value : F64, rest : State }, Error)
		parse_f64 = |_, state| parse_float(state, F64.from_str)

		## A string of decimal digits: no digit is lost to a JavaScript number.
		encode_dec : Dec, Out -> Try(Out, [])
		encode_dec = |value, out| Ok(write_digits(out, value.to_str()))

		## A string of decimal digits, or a JSON number.
		parse_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_dec = |_, state| {
			s = skip_ws(state)
			token = number_text(s)?
			value = Dec.from_str(token.text) ? |_| OutOfRange(s.pos)
			Ok({ value, rest: token.rest })
		}

		## An array.
		encode_list : Out, U64, (Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)
		encode_list = |out, _, write_items| {
			opened = write(out, |t| t.append(open_square))
			done = write_items(opened, |current, write_value| write_value(separate(current, open_square)))?
			Ok(write(done, |t| t.append(close_square)))
		}

		## Open an array. JSON arrays carry no count, so items are read one by
		## one and nothing is reserved for them in advance.
		parse_list_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_list_start = |_, state| {
			s = skip_ws(state)
			if byte_at(s) != open_square {
				return Err(Expected("an array", s.pos))
			}
			Ok(Uncounted(deeper(advance(s, 1))?))
		}

		## The next item, or the end of the array.
		parse_list_next : Format, State -> Try([Item(State), Done(State)], Error)
		parse_list_next = |_, state| {
			s = skip_ws(state)
			if (byte_at(s) == close_square) Ok(Done(shallower(advance(s, 1)))) else Ok(Item(s))
		}

		## After an item: a comma and another, or the end of the array.
		parse_list_after_item : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_list_after_item = |_, state| after_entry(state, close_square)

		## An object of the fields present, in the order derivation visits
		## them (ascending byte order of their names).
		encode_record : Out, U64, (Out, (Out, Str, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)
		encode_record = |out, _, write_fields| {
			opened = write(out, |t| t.append(open_curly))
			done = write_fields(
				opened,
				|current, name, write_value| write_value(write(separate(current, open_curly), |t| write_string(t, name).append(colon))),
			)?
			Ok(write(done, |t| t.append(close_curly)))
		}

		## Open an object, or take `null` as an object with no fields.
		parse_record_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_record_start = |_, state| {
			s = skip_ws(state)
			if literal(s, "null") {
				return Ok(Uncounted(with_null(advance(s, 4), True)))
			}
			if byte_at(s) != open_curly {
				return Err(Expected("an object", s.pos))
			}
			Ok(Uncounted(deeper(advance(s, 1))?))
		}

		## The next key, or the end of the object. A key whose value is `null`
		## is consumed here and reads as absent.
		parse_record_field : Format, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Error)
		parse_record_field = |_, _, state| {
			if state.null_record {
				return Ok(Done(with_null(state, False)))
			}
			s = skip_ws(state)
			if byte_at(s) == close_curly {
				return Ok(Done(shallower(advance(s, 1))))
			}
			key = read_string(s)?
			value_at = expect_byte(key.rest, colon)?
			v = skip_ws(value_at)
			if literal(v, "null") {
				# Consumed whole: the cursor moves past the comma, or stops
				# at the closing brace, which the next event then reads.
				return match after_entry(advance(v, 4), close_curly)? {
					Continue(next) => Ok(Continue(next))
					Done(next) => Ok(Done(next))
				}
			}
			Ok(TryField({ name: key.value, rest: v }))
		}

		## After a field: a comma and another, or the end of the object.
		parse_record_after_field : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_record_after_field = |_, state| after_entry(state, close_curly)

		## A key the type does not have: its value is skipped, whatever it is.
		skip_record_field : Format, State -> Try(State, Error)
		skip_record_field = |_, state| skip_value(state)

		## An array of the items.
		encode_tuple : Out, U64, (Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)
		encode_tuple = |out, count, write_items| PortJson.Format.encode_list(out, count, write_items)

		## Open a tuple's array.
		parse_tuple_start : Format, State, U64 -> Try(State, Error)
		parse_tuple_start = |_, state, _| {
			s = skip_ws(state)
			if byte_at(s) != open_square {
				return Err(Expected("an array of ${"a tuple's"} items", s.pos))
			}
			deeper(advance(s, 1))
		}

		## The comma before every item but the first.
		parse_tuple_next : Format, State, U64, U64 -> Try(State, Error)
		parse_tuple_next = |_, state, index, _| if (index == 0) Ok(state) else expect_byte(state, comma)

		## Close a tuple's array: it holds exactly the type's items.
		parse_tuple_end : Format, State, U64 -> Try(State, Error)
		parse_tuple_end = |_, state, _| {
			s = skip_ws(state)
			if byte_at(s) != close_square {
				return Err(Expected("the end of a tuple", s.pos))
			}
			Ok(shallower(advance(s, 1)))
		}

		## A name alone, an object holding the one payload, or an object
		## holding an array of the payloads.
		encode_tag : Out, Str, U64, (Out, (Out, (Out -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)) -> Try(Out, err)
		encode_tag = |out, name, count, write_payloads| {
			if count == 0 {
				return Ok(write(out, |t| write_string(t, name)))
			}
			if count == 1 {
				opened = write(out, |t| write_string(t.append(open_curly), name).append(colon))
				done = write_payloads(opened, |current, write_value| write_value(current))?
				return Ok(write(done, |t| t.append(close_curly)))
			}
			opened = write(out, |t| write_string(t.append(open_curly), name).append(colon).append(open_square))
			done = write_payloads(opened, |current, write_value| write_value(separate(current, open_square)))?
			Ok(write(done, |t| t.append(close_square).append(close_curly)))
		}

		## A tag in either form; `UnknownTag` when the type has no such tag.
		parse_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, Error)
		parse_tag_union = |encoding, spec, state| {
			s = skip_ws(state)
			if byte_at(s) == quote {
				name = read_string(s)?
				return bare_tag(encoding, spec, name.value, name.rest)
			}
			if byte_at(s) != open_curly {
				return Err(Expected("a tag", s.pos))
			}
			opened = deeper(advance(s, 1))?
			name = read_string(skip_ws(opened))?
			payload_at = expect_byte(name.rest, colon)?
			tag = name.value
			Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag,
					encoding,
					state: payload_at,
					start_payloads: |current, count|
						if count == 0 {
							Err(Expected("a tag with payloads, not ${tag}", current.pos))
						} else if count == 1 {
							Ok(current)
						} else {
							expect_byte(current, open_square)
						},
					next_payload: |current, _, _| expect_byte(current, comma),
					finish_payloads: |current, count| {
						closed = if (count > 1) expect_byte(current, close_square)? else current
						Ok(shallower(expect_byte(closed, close_curly)?))
					},
					missing: UnknownTag(tag),
				},
			)
		}

		## An object of the entries, sorted by key so equal dictionaries agree.
		encode_dict : Out, U64, (Entries, (Entries, (Out -> Try(Out, err)), (Out -> Try(Out, err)) -> Try(Entries, err)) -> Try(Entries, err)) -> Try(Out, err)
		encode_dict = |out, count, write_entries| {
			start = Entries.{ items: List.with_capacity(count), blobs: out.blobs, files: out.files }
			collected = write_entries(
				start,
				|current, write_key, write_value| {
					key = write_key(Out.{ text: [], blobs: current.blobs, files: current.files })?
					value = write_value(Out.{ text: [], blobs: key.blobs, files: key.files })?
					Ok(Entries.{ items: current.items.append((key.text, value.text)), blobs: value.blobs, files: value.files })
				},
			)?
			var $text = out.text.append(open_curly)
			for (key, value) in collected.items.sort_with(|(a, _), (b, _)| compare_bytes(a, b)) {
				if $text.last() != Ok(open_curly) {
					$text = $text.append(comma)
				}
				$text = $text.concat(key).append(colon).concat(value)
			}
			Ok(Out.{ text: $text.append(close_curly), blobs: collected.blobs, files: collected.files })
		}

		## Open a dictionary's object.
		parse_dict_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_dict_start = |_, state| {
			s = skip_ws(state)
			if byte_at(s) != open_curly {
				return Err(Expected("an object", s.pos))
			}
			Ok(Uncounted(deeper(advance(s, 1))?))
		}

		## The next entry, or the end of the object.
		parse_dict_next : Format, State -> Try([Entry(State), Done(State)], Error)
		parse_dict_next = |_, state| {
			s = skip_ws(state)
			if (byte_at(s) == close_curly) Ok(Done(shallower(advance(s, 1)))) else Ok(Entry(s))
		}

		## The colon between a key and its value.
		parse_dict_after_key : Format, State -> Try(State, Error)
		parse_dict_after_key = |_, state| expect_byte(state, colon)

		## After an entry: a comma and another, or the end of the object.
		parse_dict_after_entry : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_dict_after_entry = |_, state| after_entry(state, close_curly)

		## A `Str` key, with a leading `$` doubled.
		encode_key_str : Format, Str, Out -> Try(Out, [])
		encode_key_str = |_, value, out| Ok(write(out, |t| write_string(t, if (Str.starts_with(value, "$")) "$${value}" else value)))

		## A `Str` key; a single leading `$` would be a marker, not a key.
		parse_key_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_key_str = |_, state| {
			s = skip_ws(state)
			read = read_string(s)?
			if Str.starts_with(read.value, "$$") {
				Ok({ value: Str.drop_prefix(read.value, "$"), rest: read.rest })
			} else if Str.starts_with(read.value, "$") {
				Err(Expected("a key, not a marker", s.pos))
			} else {
				Ok(read)
			}
		}

		## A `Bool` key, as `"true"` or `"false"`.
		encode_key_bool : Format, Bool, Out -> Try(Out, [])
		encode_key_bool = |_, value, out| Ok(write(out, |t| write_string(t, if (value) "true" else "false")))

		## A `Bool` key.
		parse_key_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_key_bool = |_, state| {
			s = skip_ws(state)
			read = read_string(s)?
			if read.value == "true" {
				Ok({ value: True, rest: read.rest })
			} else if read.value == "false" {
				Ok({ value: False, rest: read.rest })
			} else {
				Err(Expected("\"true\" or \"false\"", s.pos))
			}
		}

		## A `U8` key, as its digits.
		encode_key_u8 : Format, U8, Out -> Try(Out, [])
		encode_key_u8 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `U8` key.
		parse_key_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_key_u8 = |_, state| parse_key_int(state, U8.from_str)

		## An `I8` key, as its digits.
		encode_key_i8 : Format, I8, Out -> Try(Out, [])
		encode_key_i8 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## An `I8` key.
		parse_key_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_key_i8 = |_, state| parse_key_int(state, I8.from_str)

		## A `U16` key, as its digits.
		encode_key_u16 : Format, U16, Out -> Try(Out, [])
		encode_key_u16 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `U16` key.
		parse_key_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_key_u16 = |_, state| parse_key_int(state, U16.from_str)

		## An `I16` key, as its digits.
		encode_key_i16 : Format, I16, Out -> Try(Out, [])
		encode_key_i16 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## An `I16` key.
		parse_key_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_key_i16 = |_, state| parse_key_int(state, I16.from_str)

		## A `U32` key, as its digits.
		encode_key_u32 : Format, U32, Out -> Try(Out, [])
		encode_key_u32 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `U32` key.
		parse_key_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_key_u32 = |_, state| parse_key_int(state, U32.from_str)

		## An `I32` key, as its digits.
		encode_key_i32 : Format, I32, Out -> Try(Out, [])
		encode_key_i32 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## An `I32` key.
		parse_key_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_key_i32 = |_, state| parse_key_int(state, I32.from_str)

		## A `U64` key, as its digits.
		encode_key_u64 : Format, U64, Out -> Try(Out, [])
		encode_key_u64 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `U64` key.
		parse_key_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_key_u64 = |_, state| parse_key_int(state, U64.from_str)

		## An `I64` key, as its digits.
		encode_key_i64 : Format, I64, Out -> Try(Out, [])
		encode_key_i64 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## An `I64` key.
		parse_key_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_key_i64 = |_, state| parse_key_int(state, I64.from_str)

		## A `U128` key, as its digits.
		encode_key_u128 : Format, U128, Out -> Try(Out, [])
		encode_key_u128 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `U128` key.
		parse_key_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_key_u128 = |_, state| parse_key_int(state, U128.from_str)

		## An `I128` key, as its digits.
		encode_key_i128 : Format, I128, Out -> Try(Out, [])
		encode_key_i128 = |_, value, out| Ok(write_digits(out, value.to_str()))

		## An `I128` key.
		parse_key_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_key_i128 = |_, state| parse_key_int(state, I128.from_str)

		## A `Dec` key, as its digits.
		encode_key_dec : Format, Dec, Out -> Try(Out, [])
		encode_key_dec = |_, value, out| Ok(write_digits(out, value.to_str()))

		## A `Dec` key.
		parse_key_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_key_dec = |_, state| {
			s = skip_ws(state)
			read = read_string(s)?
			if !is_number(Str.to_utf8(read.value)) {
				return Err(Expected("a decimal key", s.pos))
			}
			value = Dec.from_str(read.value) ? |_| OutOfRange(s.pos)
			Ok({ value, rest: read.rest })
		}

		## A tag key without payloads, as its name.
		encode_key_tag : Format, Out, Str -> Try(Out, [])
		encode_key_tag = |_, out, name| Ok(write(out, |t| write_string(t, name)))

		## A tag key, by name.
		parse_key_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, Error)
		parse_key_tag_union = |encoding, spec, state| {
			name = read_string(skip_ws(state))?
			bare_tag(encoding, spec, name.value, name.rest)
		}

		## `Wire.Bytes`: a marker naming the blob, which travels beside the
		## text.
		encode_bytes : Format, List(U8), Out -> Try(Out, [])
		encode_bytes = |_, bytes, out| {
			index = out.blobs.len()
			text = out.text.concat(Str.to_utf8("{\"$bytes\":${index.to_str()}}"))
			Ok(Out.{ text, blobs: out.blobs.append(bytes), files: out.files })
		}

		## `Wire.Bytes`: the blob a marker names, shared, not copied.
		parse_bytes : Format, State -> Try({ value : List(U8), rest : State }, Error)
		parse_bytes = |_, state| {
			s = skip_ws(state)
			if byte_at(s) != open_curly {
				return Err(Expected("a bytes marker", s.pos))
			}
			key = read_string(skip_ws(advance(s, 1)))?
			if key.value != "$bytes" {
				return Err(Expected("a bytes marker", s.pos))
			}
			index_at = skip_ws(expect_byte(key.rest, colon)?)
			index = parse_int(index_at, Narrow, U64.from_str)?
			end = expect_byte(index.rest, close_curly)?
			blob = s.blobs.get(index.value) ? |_| NoSuchBlob(index.value)
			Ok({ value: blob, rest: end })
		}

		## A file: a marker naming its place in the message's file list,
		## which travels beside the text.
		encode_file : Format, Core.File, Out -> Try(Out, [])
		encode_file = |_, file, out| {
			index = out.files.len()
			text = out.text.concat(Str.to_utf8("{\"$file\":${index.to_str()}}"))
			Ok(Out.{ text, blobs: out.blobs, files: out.files.append(file) })
		}

		## A file: the one a marker names.
		parse_file : Format, State -> Try({ value : Core.File, rest : State }, Error)
		parse_file = |_, state| {
			s = skip_ws(state)
			if byte_at(s) != open_curly {
				return Err(Expected("a file marker", s.pos))
			}
			key = read_string(skip_ws(advance(s, 1)))?
			if key.value != "$file" {
				return Err(Expected("a file marker", s.pos))
			}
			index_at = skip_ws(expect_byte(key.rest, colon)?)
			index = parse_int(index_at, Narrow, U64.from_str)?
			end = expect_byte(index.rest, close_curly)?
			file = s.files.get(index.value) ? |_| NoSuchFile(index.value)
			Ok({ value: file, rest: end })
		}
	}

	## A dictionary being encoded: each entry's key and value text, and the
	## blobs written so far. Applications never construct one.
	Entries := { items : List((List(U8), List(U8))), blobs : List(List(U8)), files : List(Core.File) }
}

## How deep containers may nest in a decoded message: the bound on the
## decoder's recursion.
max_depth : U64
max_depth = 512

## The largest integer a JavaScript number holds exactly: 2^53 - 1.
max_safe : U128
max_safe = 9007199254740991

quote : U8
quote = 34

backslash : U8
backslash = 92

open_curly : U8
open_curly = 123

close_curly : U8
close_curly = 125

open_square : U8
open_square = 91

close_square : U8
close_square = 93

colon : U8
colon = 58

comma : U8
comma = 44

minus : U8
minus = 45

## The byte under the cursor, or 0 at the end (0 never begins JSON).
byte_at : PortJson.State -> U8
byte_at = |state| state.text.get(state.pos) ?? 0

advance : PortJson.State, U64 -> PortJson.State
advance = |state, width| PortJson.State.{ text: state.text, pos: state.pos + width, blobs: state.blobs, files: state.files, depth: state.depth, null_record: state.null_record }

move_to : PortJson.State, U64 -> PortJson.State
move_to = |state, pos| PortJson.State.{ text: state.text, pos, blobs: state.blobs, files: state.files, depth: state.depth, null_record: state.null_record }

with_null : PortJson.State, Bool -> PortJson.State
with_null = |state, null_record| PortJson.State.{ text: state.text, pos: state.pos, blobs: state.blobs, files: state.files, depth: state.depth, null_record }

## Open a container, refusing one past the nesting bound.
deeper : PortJson.State -> Try(PortJson.State, PortJson.Error)
deeper = |state| {
	if state.depth >= max_depth {
		return Err(TooDeep)
	}
	Ok(PortJson.State.{ text: state.text, pos: state.pos, blobs: state.blobs, files: state.files, depth: state.depth + 1, null_record: state.null_record })
}

shallower : PortJson.State -> PortJson.State
shallower = |state| PortJson.State.{ text: state.text, pos: state.pos, blobs: state.blobs, files: state.files, depth: state.depth - 1, null_record: state.null_record }

## Skip JSON whitespace: space, tab, line feed, carriage return.
skip_ws : PortJson.State -> PortJson.State
skip_ws = |state| {
	var $pos = state.pos
	var $more = True
	while $more {
		match state.text.get($pos) {
			Ok(b) if b == 32 or b == 9 or b == 10 or b == 13 => {
				$pos = $pos + 1
			}
			_ => {
				$more = False
			}
		}
	}
	if ($pos == state.pos) state else move_to(state, $pos)
}

## Whether the text at the cursor begins with `word`.
literal : PortJson.State, Str -> Bool
literal = |state, word| {
	bytes = Str.to_utf8(word)
	state.text.sublist({ start: state.pos, len: bytes.len() }) == bytes
}

## Skip whitespace, then require `byte` and step over it.
expect_byte : PortJson.State, U8 -> Try(PortJson.State, PortJson.Error)
expect_byte = |state, byte| {
	s = skip_ws(state)
	if byte_at(s) == byte {
		Ok(advance(s, 1))
	} else {
		Err(Syntax(s.pos))
	}
}

## After an array item or an object entry: a comma, which must be followed by
## another (no trailing comma), or the closing bracket.
after_entry : PortJson.State, U8 -> Try([Continue(PortJson.State), Done(PortJson.State)], PortJson.Error)
after_entry = |state, close| {
	s = skip_ws(state)
	b = byte_at(s)
	if b == comma {
		next = skip_ws(advance(s, 1))
		if (byte_at(next) == close) Err(Syntax(next.pos)) else Ok(Continue(next))
	} else if b == close {
		Ok(Done(shallower(advance(s, 1))))
	} else {
		Err(Syntax(s.pos))
	}
}

## A tag written as its name alone: one without payloads.
bare_tag : PortJson.Format, Encoding.ParseTagUnionSpec(a), Str, PortJson.State -> Try({ value : a, rest : PortJson.State }, PortJson.Error)
bare_tag = |encoding, spec, tag, state|
	Encoding.ParseTagUnionSpec.parse(
		spec,
		{
			tag,
			encoding,
			state,
			start_payloads: |current, count| if (count == 0) Ok(current) else Err(Expected("an object holding the payloads of ${tag}", current.pos)),
			next_payload: |current, _, _| Err(Syntax(current.pos)),
			finish_payloads: |current, _| Ok(current),
			missing: UnknownTag(tag),
		},
	)

## Read a JSON string at the cursor (which must be at its opening quote).
read_string : PortJson.State -> Try({ value : Str, rest : PortJson.State }, PortJson.Error)
read_string = |state| {
	if byte_at(state) != quote {
		return Err(Expected("a string", state.pos))
	}
	text = state.text
	start = state.pos + 1
	# Most strings have no escape: find the closing quote and take the run.
	var $i = start
	var $plain = True
	var $scanning = True
	while $scanning {
		b = text.get($i) ? |_| Syntax($i)
		if b == quote {
			$scanning = False
		} else if b == backslash {
			$plain = False
			$scanning = False
		} else if b < 32 {
			return Err(Syntax($i))
		} else {
			$i = $i + 1
		}
	}
	if $plain {
		value = Str.from_utf8(text.sublist({ start, len: $i - start })) ? |_| Syntax(start)
		return Ok({ value, rest: move_to(state, $i + 1) })
	}
	var $out = text.sublist({ start, len: $i - start })
	var $done = False
	while !$done {
		b = text.get($i) ? |_| Syntax($i)
		if b == quote {
			$done = True
		} else if b < 32 {
			return Err(Syntax($i))
		} else if b != backslash {
			$out = $out.append(b)
			$i = $i + 1
		} else {
			e = text.get($i + 1) ? |_| Syntax($i)
			if e == 117 {
				first = hex4(text, $i + 2)?
				if first >= 0xDC00 and first <= 0xDFFF {
					return Err(Syntax($i))
				}
				if first >= 0xD800 and first <= 0xDBFF {
					# A high surrogate must be followed by an escaped low one.
					if text.get($i + 6) != Ok(backslash) or text.get($i + 7) != Ok(117) {
						return Err(Syntax($i))
					}
					second = hex4(text, $i + 8)?
					if second < 0xDC00 or second > 0xDFFF {
						return Err(Syntax($i + 6))
					}
					$out = put_utf8($out, 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00))
					$i = $i + 12
				} else {
					$out = put_utf8($out, first)
					$i = $i + 6
				}
			} else {
				unescaped =
					match e {
						34 => 34
						92 => 92
						47 => 47
						98 => 8
						102 => 12
						110 => 10
						114 => 13
						116 => 9
						_ => return Err(Syntax($i))
					}
				$out = $out.append(unescaped)
				$i = $i + 2
			}
		}
	}
	value = Str.from_utf8($out) ? |_| Syntax(start)
	Ok({ value, rest: move_to(state, $i + 1) })
}

## Four hex digits at `at`, as a code unit.
hex4 : List(U8), U64 -> Try(U32, PortJson.Error)
hex4 = |text, at| {
	var $value = 0.U32
	var $k = 0.U64
	while $k < 4 {
		b = text.get(at + $k) ? |_| Syntax(at)
		digit =
			if b >= 48 and b <= 57 {
				b - 48
			} else if b >= 97 and b <= 102 {
				b - 87
			} else if b >= 65 and b <= 70 {
				b - 55
			} else {
				return Err(Syntax(at + $k))
			}
		$value = $value * 16 + digit.to_u32()
		$k = $k + 1
	}
	Ok($value)
}

## Append a code point as UTF-8.
put_utf8 : List(U8), U32 -> List(U8)
put_utf8 = |out, cp| {
	if cp < 0x80 {
		out.append(cp.to_u8_wrap())
	} else if cp < 0x800 {
		out.append((0xC0 + cp.shr_zf_wrap(6)).to_u8_wrap()).append((0x80 + cp.bitwise_and(0x3F)).to_u8_wrap())
	} else if cp < 0x10000 {
		out.append((0xE0 + cp.shr_zf_wrap(12)).to_u8_wrap()).append((0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap()).append((0x80 + cp.bitwise_and(0x3F)).to_u8_wrap())
	} else {
		out
			.append((0xF0 + cp.shr_zf_wrap(18)).to_u8_wrap())
			.append((0x80 + cp.shr_zf_wrap(12).bitwise_and(0x3F)).to_u8_wrap())
			.append((0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap())
			.append((0x80 + cp.bitwise_and(0x3F)).to_u8_wrap())
	}
}

## Whether `bytes` follow JSON's number grammar:
## `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
is_number : List(U8) -> Bool
is_number = |bytes| number_end(bytes, 0) == Ok(bytes.len())

## Whether `bytes` are an integer in JSON's grammar: `-? (0 | [1-9][0-9]*)`.
is_integer : List(U8) -> Bool
is_integer = |bytes| match int_end(bytes, 0) {
	Ok(end) => end == bytes.len()
	Err(_) => False
}

## Where a JSON integer part starting at `at` ends.
int_end : List(U8), U64 -> Try(U64, [NotANumber])
int_end = |bytes, at| {
	start = if (bytes.get(at) == Ok(minus)) at + 1 else at
	match bytes.get(start) {
		Ok(48) => Ok(start + 1)
		Ok(b) if b >= 49 and b <= 57 => Ok(digits_end(bytes, start + 1))
		_ => Err(NotANumber)
	}
}

digits_end : List(U8), U64 -> U64
digits_end = |bytes, at| {
	var $i = at
	while is_digit(bytes.get($i) ?? 0) {
		$i = $i + 1
	}
	$i
}

is_digit : U8 -> Bool
is_digit = |b| b >= 48 and b <= 57

## Where a JSON number starting at `at` ends, or `Err` if none starts there.
number_end : List(U8), U64 -> Try(U64, [NotANumber])
number_end = |bytes, at| {
	var $i = int_end(bytes, at)?
	if bytes.get($i) == Ok(46) {
		frac = digits_end(bytes, $i + 1)
		if frac == $i + 1 {
			return Err(NotANumber)
		}
		$i = frac
	}
	match bytes.get($i) {
		Ok(e) if e == 101 or e == 69 => {
			sign = match bytes.get($i + 1) {
				Ok(s) if s == 43 or s == minus => $i + 2
				_ => $i + 1
			}
			exp = digits_end(bytes, sign)
			if exp == sign {
				return Err(NotANumber)
			}
			Ok(exp)
		}
		_ => Ok($i)
	}
}

## A number's text: a JSON number, or a JSON string holding one.
number_text : PortJson.State -> Try({ text : Str, rest : PortJson.State }, PortJson.Error)
number_text = |s| {
	if byte_at(s) == quote {
		read = read_string(s)?
		if !is_number(Str.to_utf8(read.value)) {
			return Err(Expected("a number", s.pos))
		}
		return Ok({ text: read.value, rest: read.rest })
	}
	end = number_end(s.text, s.pos) ? |_| Expected("a number", s.pos)
	text = Str.from_utf8(s.text.sublist({ start: s.pos, len: end - s.pos })) ? |_| Syntax(s.pos)
	Ok({ text, rest: move_to(s, end) })
}

## Read an integer: a string of digits, or a JSON number without fraction or
## exponent; a `Wide` one given as a number must be a safe integer.
parse_int : PortJson.State, [Narrow, Wide], (Str -> Try(a, _)) -> Try({ value : a, rest : PortJson.State }, PortJson.Error)
parse_int = |state, width, from_str| {
	s = skip_ws(state)
	(text, rest, quoted) =
		if byte_at(s) == quote {
			read = read_string(s)?
			if !is_integer(Str.to_utf8(read.value)) {
				return Err(Expected("an integer", s.pos))
			}
			(read.value, read.rest, True)
		} else {
			end = number_end(s.text, s.pos) ? |_| Expected("an integer", s.pos)
			whole = s.text.sublist({ start: s.pos, len: end - s.pos })
			if !is_integer(whole) {
				return Err(OutOfRange(s.pos))
			}
			(Str.from_utf8(whole) ? |_| Syntax(s.pos), move_to(s, end), False)
		}
	if !quoted and width == Wide {
		magnitude = U128.from_str(Str.drop_prefix(text, "-")) ? |_| OutOfRange(s.pos)
		if magnitude > max_safe {
			return Err(OutOfRange(s.pos))
		}
	}
	value = from_str(text) ? |_| OutOfRange(s.pos)
	Ok({ value, rest })
}

## Read an integer dictionary key: a string of digits.
parse_key_int : PortJson.State, (Str -> Try(a, _)) -> Try({ value : a, rest : PortJson.State }, PortJson.Error)
parse_key_int = |state, from_str| {
	s = skip_ws(state)
	read = read_string(s)?
	if !is_integer(Str.to_utf8(read.value)) {
		return Err(Expected("an integer key", s.pos))
	}
	value = from_str(read.value) ? |_| OutOfRange(s.pos)
	Ok({ value, rest: read.rest })
}

## Read a float: a JSON number, or `"NaN"`, `"Infinity"` or `"-Infinity"`.
parse_float : PortJson.State, (Str -> Try(a, _)) -> Try({ value : a, rest : PortJson.State }, PortJson.Error)
parse_float = |state, from_str| {
	s = skip_ws(state)
	if byte_at(s) == quote {
		read = read_string(s)?
		if read.value == "NaN" or read.value == "Infinity" or read.value == "-Infinity" {
			value = from_str(read.value) ? |_| OutOfRange(s.pos)
			return Ok({ value, rest: read.rest })
		}
		return Err(Expected("a number", s.pos))
	}
	end = number_end(s.text, s.pos) ? |_| Expected("a number", s.pos)
	text = Str.from_utf8(s.text.sublist({ start: s.pos, len: end - s.pos })) ? |_| Syntax(s.pos)
	value = from_str(text) ? |_| OutOfRange(s.pos)
	Ok({ value, rest: move_to(s, end) })
}

## Skip one value of any kind, within the nesting bound.
skip_value : PortJson.State -> Try(PortJson.State, PortJson.Error)
skip_value = |state| {
	s = skip_ws(state)
	b = byte_at(s)
	if b == quote {
		read = read_string(s)?
		Ok(read.rest)
	} else if b == open_square or b == open_curly {
		close = if (b == open_square) close_square else close_curly
		var $cur = deeper(advance(s, 1))?
		first = skip_ws($cur)
		if byte_at(first) == close {
			return Ok(shallower(advance(first, 1)))
		}
		var $more = True
		while $more {
			if b == open_curly {
				key = read_string(skip_ws($cur))?
				$cur = expect_byte(key.rest, colon)?
			}
			$cur = skip_value($cur)?
			match after_entry($cur, close)? {
				Continue(next) => {
					$cur = next
				}
				Done(next) => {
					$cur = next
					$more = False
				}
			}
		}
		Ok($cur)
	} else if literal(s, "true") or literal(s, "null") {
		Ok(advance(s, 4))
	} else if literal(s, "false") {
		Ok(advance(s, 5))
	} else {
		end = number_end(s.text, s.pos) ? |_| Syntax(s.pos)
		Ok(move_to(s, end))
	}
}

## Apply `f` to the encoder's text.
write : PortJson.Out, (List(U8) -> List(U8)) -> PortJson.Out
write = |out, f| PortJson.Out.{ text: f(out.text), blobs: out.blobs, files: out.files }

## A comma, unless the container was just opened with `open`.
separate : PortJson.Out, U8 -> PortJson.Out
separate = |out, open| if (out.text.last() == Ok(open)) out else write(out, |t| t.append(comma))

## A number's text as it is.
write_number : PortJson.Out, Str -> PortJson.Out
write_number = |out, text| write(out, |t| t.concat(Str.to_utf8(text)))

## A number's digits as a JSON string.
write_digits : PortJson.Out, Str -> PortJson.Out
write_digits = |out, text| write(out, |t| t.append(quote).concat(Str.to_utf8(text)).append(quote))

## A JSON string: the quote, the backslash and the controls escaped, every
## other character as it is.
write_string : List(U8), Str -> List(U8)
write_string = |text, value| {
	bytes = Str.to_utf8(value)
	if !bytes.any(|b| b == quote or b == backslash or b < 32) {
		return text.append(quote).concat(bytes).append(quote)
	}
	var $out = text.append(quote)
	for b in bytes {
		$out =
			if b == quote {
				$out.append(backslash).append(quote)
			} else if b == backslash {
				$out.append(backslash).append(backslash)
			} else if b == 10 {
				$out.append(backslash).append(110)
			} else if b == 13 {
				$out.append(backslash).append(114)
			} else if b == 9 {
				$out.append(backslash).append(116)
			} else if b < 32 {
				$out.concat(Str.to_utf8("\\u00")).append(hex_digit(b.shr_zf_wrap(4))).append(hex_digit(b.bitwise_and(15)))
			} else {
				$out.append(b)
			}
	}
	$out.append(quote)
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) 48 + n else 87 + n

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

## The JSON text a value encodes to.
json_of : a -> Str where [a.PortJson.Sendable]
json_of = |value| PortJson.encode(value).json

## Whether a value comes back from its own message unchanged.
round_trips : a -> Bool where [a.PortJson.Sendable, a.is_eq : a, a -> Bool]
round_trips = |value|
	match PortJson.decode(PortJson.encode(value)) {
		Ok(decoded) => decoded == value
		Err(_) => False
	}

## Decode text that carries no blobs.
from_text : Str -> Try(a, PortJson.Error) where [a.PortJson.Sendable]
from_text = |json| PortJson.decode({ json, blobs: [], files: [] })

Profile : { name : Str, nick : Try(Str, [Missing]), age : Try(U8, [Missing]) }

Shape : [Dot, Circle(F64), Rect({ w : U32, h : U32 }), Path(List((I16, I16)))]

Nested := { kids : List(Nested) }.{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## Narrow integers are numbers; 64- and 128-bit integers and `Dec` are
## strings, so JavaScript loses no digit.
expect {
	actual = [
		json_of((U8.highest, I8.lowest, U16.highest, I16.lowest, U32.highest, I32.lowest)),
		json_of((U64.highest, I64.lowest, U128.highest, I128.lowest)),
		json_of((0.1.Dec, -12.5.Dec, 3.Dec)),
	]
	expected = [
		"[255,-128,65535,-32768,4294967295,-2147483648]",
		"[\"18446744073709551615\",\"-9223372036854775808\",\"340282366920938463463374607431768211455\",\"-170141183460469231731687303715884105728\"]",
		"[\"0.1\",\"-12.5\",\"3.0\"]",
	]
	actual == expected
}

## Every integer width round trips at both ends.
expect {
	unsigned = round_trips((0.U8, U8.highest, U16.highest, U32.highest, U64.highest, U128.highest))
	signed = round_trips((I8.lowest, I8.highest, I16.lowest, I32.lowest, I64.lowest, I64.highest, I128.lowest, I128.highest))
	unsigned and signed and round_trips((Dec.lowest, Dec.highest, -1.5.Dec))
}

## Either form decodes for every width, but a 64-bit integer sent as a number
## must be one JavaScript held exactly, and an integer has no fraction.
expect {
	small : Try((U8, I32, U64), PortJson.Error)
	small = from_text("[\"7\",-3,\"9007199254740993\"]")
	safe : Try(I64, PortJson.Error)
	safe = from_text("-9007199254740991")
	unsafe : Try(U64, PortJson.Error)
	unsafe = from_text("9007199254740992")
	fraction : Try(U8, PortJson.Error)
	fraction = from_text("1.5")
	exponent : Try(U32, PortJson.Error)
	exponent = from_text("1e3")
	over : Try(U8, PortJson.Error)
	over = from_text("256")
	padded : Try(U8, PortJson.Error)
	padded = from_text("\"007\"")
	small == Ok((7, -3, 9007199254740993)) and safe == Ok(-9007199254740991) and unsafe == Err(OutOfRange(0)) and fraction == Err(OutOfRange(0)) and exponent == Err(OutOfRange(0)) and over == Err(OutOfRange(0)) and padded == Err(Expected("an integer", 0))
}

## Floats are shortest JSON numbers; NaN and the infinities are strings, and
## every one of them reads back.
expect {
	values = (0.1.F64, 2.0.F64, -0.0.F64, 1.0e300.F64, F64.nan, F64.infinity, -F64.infinity, 1.5.F32)
	text = json_of(values)
	decoded : Try((F64, F64, F64, F64, F64, F64, F64, F32), PortJson.Error)
	decoded = from_text(text)
	same = match decoded {
		Ok((a, b, c, d, e, f, g, h)) => [F64.to_bits(a), F64.to_bits(b), F64.to_bits(c), F64.to_bits(d), F64.to_bits(f), F64.to_bits(g)] == [F64.to_bits(values.0), F64.to_bits(values.1), F64.to_bits(values.2), F64.to_bits(values.3), F64.to_bits(values.5), F64.to_bits(values.6)] and F64.is_nan(e) and F32.to_bits(h) == F32.to_bits(1.5)
		Err(_) => False
	}
	text == "[0.1,2,-0,1e300,\"NaN\",\"Infinity\",\"-Infinity\",1.5]" and same
}

## Numbers from JavaScript in any JSON form decode; what is not a JSON
## number does not.
expect {
	exp : Try((Dec, Dec), PortJson.Error)
	exp = from_text("[1e-7, \"12.50\"]")
	floats : Try(F64, PortJson.Error)
	floats = from_text(" 1e3 ")
	lax : Try(F64, PortJson.Error)
	lax = from_text("01")
	word : Try(F64, PortJson.Error)
	word = from_text("\"inf\"")
	exp == Ok((0.0000001, 12.5)) and floats.map_ok(|f| F64.to_bits(f)) == Ok(F64.to_bits(1000.0)) and lax == Err(Trailing(1)) and word == Err(Expected("a number", 0))
}

## Strings escape only the quote, the backslash and the controls, and read
## back every escape JSON has, surrogate pairs included.
expect {
	text = json_of("q\" b\\ n\n t\t c\u(0001) é 😀 /")
	decoded : Try(Str, PortJson.Error)
	decoded = from_text("\"a\\\"b\\\\c\\/d\\n\\u00e9\\ud83d\\ude00\\b\\f\\r\\t\"")
	lone : Try(Str, PortJson.Error)
	lone = from_text("\"\\ud800\"")
	raw : Try(Str, PortJson.Error)
	raw = from_text("\"a\nb\"")
	text == "\"q\\\" b\\\\ n\\n t\\t c\\u0001 é 😀 /\"" and decoded == Ok("a\"b\\c/d\né😀\u(8)\u(C)\r\t") and lone.is_err() and raw == Err(Syntax(2)) and round_trips("") and round_trips("héllo 🦊\u(0)")
}

## Records are objects with keys in field order; an absent optional field is
## left out, and absent or `null` reads back as `Missing`.
expect {
	some : Profile
	some = { name: "n", nick: Err(Missing), age: Ok(9) }
	text = json_of(some)
	from_js : Try(Profile, PortJson.Error)
	from_js = from_text("{ \"nick\": null, \"extra\": [1, {\"q\": \"}\"}], \"name\": \"n\", \"age\": 9 }")
	missing : Try(Profile, PortJson.Error)
	missing = from_text("{\"age\":1}")
	text == "{\"age\":9,\"name\":\"n\"}" and from_js == Ok(some) and missing == Err(MissingRequiredField("name")) and round_trips({ zeta: 1.U8, alpha: [2.U8], mid: { inner: ("m", -4.I16) } })
}

## `null` stands for a record with no fields, which is what JavaScript's
## `undefined` becomes.
expect {
	empty : Try({}, PortJson.Error)
	empty = from_text("null")
	json_of({}) == "{}" and empty == Ok({})
}

## Tags are a name, an object holding one payload, or an object holding an
## array of payloads.
expect {
	shapes : List(Shape)
	shapes = [Dot, Circle(1.5), Rect({ w: 3, h: 4 }), Path([(1, -1)])]
	text = json_of(shapes)
	unknown : Try(Shape, PortJson.Error)
	unknown = from_text("\"Blob\"")
	misplaced : Try(Shape, PortJson.Error)
	misplaced = from_text("\"Circle\"")
	text == "[\"Dot\",{\"Circle\":1.5},{\"Rect\":{\"h\":4,\"w\":3}},{\"Path\":[[1,-1]]}]" and unknown == Err(UnknownTag("Blob")) and misplaced.is_err()
}

## A multi-payload tag carries its payloads in an array.
expect {
	tag : [Pair(U8, Str), Single(Bool)]
	tag = Pair(1, "x")
	json_of(tag) == "{\"Pair\":[1,\"x\"]}" and round_trips(tag)
}

## Dictionaries are objects sorted by key; number and tag keys are strings,
## and a key beginning with `$` cannot pass for a marker.
expect {
	words = json_of(Dict.from_list([("b", 2.U8), ("a", 1), ("$x", 3)]))
	numbers = json_of(Dict.from_list([(10.U32, Bool.True), (2, Bool.False)]))
	colors = Dict.from_list([(Red, [1.U8]), (Green, [])])
	marker : Try(Dict(Str, U8), PortJson.Error)
	marker = from_text("{\"$bytes\":0}")
	words == "{\"$$x\":3,\"a\":1,\"b\":2}" and numbers == "{\"10\":true,\"2\":false}" and round_trips(colors) and round_trips(Dict.from_list([("$x", 3.U8), ("a", 1)])) and marker.is_err()
}

## Lists, sets, empty containers and nested lists.
expect {
	empty : List(U64)
	empty = []
	round_trips(empty) and round_trips([[], ["a"], ["b", ""]]) and round_trips([{}, {}]) and round_trips(Set.from_list(["x", "y"])) and json_of([[1.U8, 2], []]) == "[[1,2],[]]"
}

## Bytes travel beside the text as blobs, named by markers, and are shared on
## the way back, never turned into text.
expect {
	message = PortJson.encode({ name: "report.docx", contents: Wire.Bytes.from_list([0, 255, 128]), thumb: Wire.Bytes.from_list([]) })
	decoded : Try({ name : Str, contents : Wire.Bytes, thumb : Wire.Bytes }, PortJson.Error)
	decoded = PortJson.decode(message)
	shape = message.json == "{\"contents\":{\"$bytes\":0},\"name\":\"report.docx\",\"thumb\":{\"$bytes\":1}}" and message.blobs == [[0, 255, 128], []]
	back = match decoded {
		Ok(v) => v.contents.to_list() == [0, 255, 128] and v.thumb.to_list() == [] and v.name == "report.docx"
		Err(_) => False
	}
	shape and back
}

## A marker for a blob the message does not carry is refused, and markers
## may be spaced like any JSON.
expect {
	absent : Try(Wire.Bytes, PortJson.Error)
	absent = PortJson.decode({ json: "{\"$bytes\":1}", blobs: [[1]], files: [] })
	spaced : Try(Wire.Bytes, PortJson.Error)
	spaced = PortJson.decode({ json: " { \"$bytes\" : 0 } ", blobs: [[7]], files: [] })
	absent == Err(NoSuchBlob(1)) and spaced.map_ok(|b| b.to_list()) == Ok([7])
}

## Whitespace anywhere JSON allows it; text after the value and trailing
## commas are refused.
expect {
	spaced : Try({ a : List(U8) }, PortJson.Error)
	spaced = from_text(" \n{ \"a\" :\t[ 1 , 2 ] }\r\n")
	trailing : Try(U8, PortJson.Error)
	trailing = from_text("1 2")
	dangling : Try(List(U8), PortJson.Error)
	dangling = from_text("[1,]")
	spaced == Ok({ a: [1, 2] }) and trailing == Err(Trailing(2)) and dangling.is_err()
}

## Nesting is bounded, in values the type reads and in values it skips.
expect {
	deep : Try(Nested, PortJson.Error)
	deep = from_text(Str.repeat("{\"kids\":[", 600))
	skipped : Try({ a : U8 }, PortJson.Error)
	skipped = from_text("{\"x\":${Str.repeat("[", 600)}${Str.repeat("]", 600)},\"a\":1}")
	deep == Err(TooDeep) and skipped == Err(TooDeep)
}

## Every strict prefix of a message is refused.
expect {
	text = json_of({ shapes: [Rect({ w: 1, h: 2 })], words: ["a\"b"], n: 7.U64 })
	bytes = Str.to_utf8(text)
	var $all = True
	var $len = 0
	while $len < bytes.len() {
		decoded : Try({ shapes : List(Shape), words : List(Str), n : U64 }, PortJson.Error)
		decoded = PortJson.decode({ json: Str.from_utf8_lossy(bytes.take_first($len)), blobs: [], files: [] })
		if decoded.is_ok() {
			$all = False
		}
		$len = $len + 1
	}
	$all
}

## A file travels beside the text as a marker naming its place in the file
## list, and decodes to the file it names; a marker naming no file is an
## error, not a crash.
expect {
	file = match Core.placed_file(Core.held_file(Box.box(1)), { name: "a.txt", mime: "text/plain", size: 2, start: 0, len: 2 }) {
		Ok(f) => f
		Err(_) => crash "a range outside its file"
	}
	message = PortJson.encode({ doc: file, name: "a" })
	back : Try({ doc : Core.File, name : Str }, PortJson.Error)
	back = PortJson.decode(message)
	missing : Try({ doc : Core.File }, PortJson.Error)
	missing = PortJson.decode({ json: "{\"doc\":{\"$file\":3}}", blobs: [], files: [file] })
	message.json == "{\"doc\":{\"$file\":0},\"name\":\"a\"}" and message.files == [file] and back == Ok({ doc: file, name: "a" }) and missing == Err(NoSuchFile(3))
}
