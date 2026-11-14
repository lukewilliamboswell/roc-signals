import Core
import Engine
import cbor.Cbor

## The unexposed worker payload implementation. Wire gives applications
## public aliases for the codec vocabulary; only this module carries files
## beside encoded bytes and opens or finishes payload state.
##
## CBOR owns item grammar, preferred numeric forms, container checks and map
## ordering. File references are the one protocol-specific six-item array;
## the actual owned files travel beside the bytes between instances.
WorkerCodec := [].{

	## A malformed payload's byte position, or a missing required field name.
	Error : [InvalidCbor(U64), MissingRequiredField(Str)]

	## Values whose codecs can carry them between instances of this module.
	## Functions and types without the required codecs are not Sendable.
	a.Sendable :
		where [
			a.encoder_for : Format -> (a, Enc -> Try(Enc, [])),
			a.parser_for : Format -> (State -> Try({ value : a, rest : State }, Error)),
		]

	## One value's opaque encoder state. Custom codecs pass it to the supplied
	## item writer; they neither construct it nor retain an earlier state.
	##
	## `Enc`, `Items` and `State` are opaque, so an application can name them
	## and can neither build nor open them, and each wraps a transparent body
	## that only this module names, rather than being the record itself. An
	## opaque record with a function anywhere in its fields (here each
	## `Engine.File`'s job effects) loses its unique hold on the writer or
	## the value being decoded at every item under `--opt=speed` and
	## `--opt=size`: each append copies the whole output, quadratic in the
	## payload. The same state behind a transparent body is updated in place.
	## This is a compiler defect, listed in design.md's compiler limitations;
	## each body goes back into its opaque type once the compiler is fixed.
	Enc :: EncBody

	## The writer and the files met so far, behind `Enc`.
	EncBody := { writer : Cbor.Writer, held : Held }

	## What an encode carries beside its writer: the files met so far, how
	## many containers enclose the item being written, and whether a
	## container was met at the nesting bound (`max_nesting`).
	Held : { files : List(Engine.File), depth : U64, over : Bool }

	## An open list, tuple or tag's accumulator. Its add callback creates an
	## Enc for each value. These are different states: a container cannot be
	## used where its next item writer is required.
	Items :: ItemsBody

	## The open container and the files met so far, behind `Items`.
	ItemsBody := { container : Cbor.Container, held : Held }

	## The opaque accumulator supplied to a record's field callback.
	Fields : Items

	## The opaque accumulator supplied to a dictionary's entry callback.
	Entries : Items

	## One checked payload's cursor and accompanying owned file values, and
	## the dictionaries the parse has open, innermost last.
	## Custom parsers return the next cursor and never open its representation.
	State :: StateBody

	## The reader's configuration, cursor, the files handed to it and the
	## open dictionaries, behind `State`.
	StateBody := { cbor : Cbor, reader : Cbor.Reader, files : List(Engine.File), dicts : List(OpenDict) }

	## A dictionary a parse has opened: the keys it still has to read, and
	## the sign of a float zero key it has read. Builtin float equality makes
	## `0.0` and `-0.0` one key, so a dictionary holding both is refused
	## rather than losing an entry (https://github.com/roc-lang/roc/issues/13057).
	OpenDict : { keys : [Left(U64), UntilDone], zero : [Unseen, Positive, Negative] }

	## The opaque format each derived or handwritten codec dispatches on. Its
	## hooks forward representation work to the pinned CBOR implementation.
	## It holds nothing: a write's rules travel in its writer and a read's in
	## its parser state.
	Format :: {}.{

		## Reject a value that does not belong to the expected derived type.
		invalid_value : Format, State -> Error
		invalid_value = |_, state| Cbor.invalid_value(config_of(state), reader_of(state))

		## The missing required field, as the CBOR reader names one.
		missing_field : Format, Str -> Error
		missing_field = |_, name| MissingRequiredField(name)

		## A field's key is its Roc name: the writer and the reader both use
		## roc-cbor's default snake_case field names.
		rename_field : Format, Str -> Str
		rename_field = |_, name| name

		## Write one Str item while moving the accompanying files unchanged.
		encode_str : Str, Enc -> Try(Enc, [])
		encode_str = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_str(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one Str using the checked cursor and this payload's strict rules.
		parse_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_str = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_str(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one Bool item while moving the accompanying files unchanged.
		encode_bool : Bool, Enc -> Try(Enc, [])
		encode_bool = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_bool(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one Bool using the checked cursor and this payload's strict rules.
		parse_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_bool = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_bool(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one U8 item while moving the accompanying files unchanged.
		encode_u8 : U8, Enc -> Try(Enc, [])
		encode_u8 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u8(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one U8 using the checked cursor and this payload's strict rules.
		parse_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_u8 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_u8(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one I8 item while moving the accompanying files unchanged.
		encode_i8 : I8, Enc -> Try(Enc, [])
		encode_i8 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i8(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one I8 using the checked cursor and this payload's strict rules.
		parse_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_i8 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_i8(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one U16 item while moving the accompanying files unchanged.
		encode_u16 : U16, Enc -> Try(Enc, [])
		encode_u16 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u16(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one U16 using the checked cursor and this payload's strict rules.
		parse_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_u16 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_u16(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one I16 item while moving the accompanying files unchanged.
		encode_i16 : I16, Enc -> Try(Enc, [])
		encode_i16 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i16(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one I16 using the checked cursor and this payload's strict rules.
		parse_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_i16 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_i16(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one U32 item while moving the accompanying files unchanged.
		encode_u32 : U32, Enc -> Try(Enc, [])
		encode_u32 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one U32 using the checked cursor and this payload's strict rules.
		parse_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_u32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_u32(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one I32 item while moving the accompanying files unchanged.
		encode_i32 : I32, Enc -> Try(Enc, [])
		encode_i32 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one I32 using the checked cursor and this payload's strict rules.
		parse_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_i32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_i32(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one U64 item while moving the accompanying files unchanged.
		encode_u64 : U64, Enc -> Try(Enc, [])
		encode_u64 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one U64 using the checked cursor and this payload's strict rules.
		parse_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_u64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_u64(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one I64 item while moving the accompanying files unchanged.
		encode_i64 : I64, Enc -> Try(Enc, [])
		encode_i64 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one I64 using the checked cursor and this payload's strict rules.
		parse_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_i64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_i64(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one U128 item while moving the accompanying files unchanged.
		encode_u128 : U128, Enc -> Try(Enc, [])
		encode_u128 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u128(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one U128 using the checked cursor and this payload's strict rules.
		parse_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_u128 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_u128(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one I128 item while moving the accompanying files unchanged.
		encode_i128 : I128, Enc -> Try(Enc, [])
		encode_i128 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i128(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one I128 using the checked cursor and this payload's strict rules.
		parse_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_i128 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_i128(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one F32 item while moving the accompanying files unchanged.
		encode_f32 : F32, Enc -> Try(Enc, [])
		encode_f32 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_f32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one F32 using the checked cursor and this payload's strict rules.
		parse_f32 : Format, State -> Try({ value : F32, rest : State }, Error)
		parse_f32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_f32(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one F64 item while moving the accompanying files unchanged.
		encode_f64 : F64, Enc -> Try(Enc, [])
		encode_f64 = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_f64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one F64 using the checked cursor and this payload's strict rules.
		parse_f64 : Format, State -> Try({ value : F64, rest : State }, Error)
		parse_f64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_f64(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Write one Dec item while moving the accompanying files unchanged.
		encode_dec : Dec, Enc -> Try(Enc, [])
		encode_dec = |value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_dec(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read one Dec using the checked cursor and this payload's strict rules.
		parse_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_dec = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_dec(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## Let CBOR open a list and count each callback item. The file list moves
		## through each callback with its writer, including nested containers.
		encode_list : Enc, U64, (Items, (Items, (Enc -> Try(Enc, err)) -> Try(Items, err)) -> Try(Items, err)) -> Try(Enc, err)
		encode_list = |Enc.(EncBody.({ writer: output, held })), count, write| if held.depth >= max_nesting {
			too_deep(output, held)
		} else {
			outer = held.depth
			Cbor.encode_list_carry(
				{ writer: output, state: { ..held, depth: held.depth + 1 } },
				count,
				|items, add| write(
					Items.(ItemsBody.{ container: items.container, held: items.state }),
					|Items.(ItemsBody.({ container: item_container, held: item_held })), write_value| add({ container: item_container, state: item_held }, |entry| write_value(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held })).map_ok(|done| Items.(ItemsBody.{ container: done.container, held: done.state })),
				).map_ok(|Items.(ItemsBody.({ container: done_container, held: done_held }))| { container: done_container, state: done_held }),
			).map_ok(|done| Enc.(EncBody.{ writer: done.writer, held: { ..done.state, depth: outer } }))
		}

		## Let CBOR open a tuple and count each callback item. The file list moves
		## through each callback with its writer, including nested containers.
		encode_tuple : Enc, U64, (Items, (Items, (Enc -> Try(Enc, err)) -> Try(Items, err)) -> Try(Items, err)) -> Try(Enc, err)
		encode_tuple = |Enc.(EncBody.({ writer: output, held })), count, write| if held.depth >= max_nesting {
			too_deep(output, held)
		} else {
			outer = held.depth
			Cbor.encode_tuple_carry(
				{ writer: output, state: { ..held, depth: held.depth + 1 } },
				count,
				|items, add| write(
					Items.(ItemsBody.{ container: items.container, held: items.state }),
					|Items.(ItemsBody.({ container: item_container, held: item_held })), write_value| add({ container: item_container, state: item_held }, |entry| write_value(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held })).map_ok(|done| Items.(ItemsBody.{ container: done.container, held: done.state })),
				).map_ok(|Items.(ItemsBody.({ container: done_container, held: done_held }))| { container: done_container, state: done_held }),
			).map_ok(|done| Enc.(EncBody.{ writer: done.writer, held: { ..done.state, depth: outer } }))
		}

		## Let CBOR open a tag and count each callback item. The file list moves
		## through each callback with its writer, including nested containers.
		encode_tag : Enc, Str, U64, (Items, (Items, (Enc -> Try(Enc, err)) -> Try(Items, err)) -> Try(Items, err)) -> Try(Enc, err)
		encode_tag = |Enc.(EncBody.({ writer: output, held })), name, count, write| if count > 0 and held.depth >= max_nesting {
			too_deep(output, held)
		} else {
			outer = held.depth
			Cbor.encode_tag_carry(
				{ writer: output, state: { ..held, depth: if (count == 0) held.depth else held.depth + 1 } },
				name,
				count,
				|items, add| write(
					Items.(ItemsBody.{ container: items.container, held: items.state }),
					|Items.(ItemsBody.({ container: item_container, held: item_held })), write_value| add({ container: item_container, state: item_held }, |entry| write_value(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held })).map_ok(|done| Items.(ItemsBody.{ container: done.container, held: done.state })),
				).map_ok(|Items.(ItemsBody.({ container: done_container, held: done_held }))| { container: done_container, state: done_held }),
			).map_ok(|done| Enc.(EncBody.{ writer: done.writer, held: { ..done.state, depth: outer } }))
		}

		## Let CBOR open a record and count each callback item. The file list moves
		## through each callback with its writer, including nested containers.
		encode_record : Enc, U64, (Fields, (Fields, Str, (Enc -> Try(Enc, err)) -> Try(Fields, err)) -> Try(Fields, err)) -> Try(Enc, err)
		encode_record = |Enc.(EncBody.({ writer: output, held })), count, write| if held.depth >= max_nesting {
			too_deep(output, held)
		} else {
			outer = held.depth
			Cbor.encode_record_carry(
				{ writer: output, state: { ..held, depth: held.depth + 1 } },
				count,
				|items, add| write(
					Items.(ItemsBody.{ container: items.container, held: items.state }),
					|Items.(ItemsBody.({ container: item_container, held: item_held })), name, write_value| add({ container: item_container, state: item_held }, name, |entry| write_value(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held })).map_ok(|done| Items.(ItemsBody.{ container: done.container, held: done.state })),
				).map_ok(|Items.(ItemsBody.({ container: done_container, held: done_held }))| { container: done_container, state: done_held }),
			).map_ok(|done| Enc.(EncBody.{ writer: done.writer, held: { ..done.state, depth: outer } }))
		}

		## Let CBOR open a dict and count each callback item. The file list moves
		## through each callback with its writer, including nested containers.
		encode_dict : Enc, U64, (Entries, (Entries, (Enc -> Try(Enc, err)), (Enc -> Try(Enc, err)) -> Try(Entries, err)) -> Try(Entries, err)) -> Try(Enc, err)
		encode_dict = |Enc.(EncBody.({ writer: output, held })), count, write| if held.depth >= max_nesting {
			too_deep(output, held)
		} else {
			outer = held.depth
			Cbor.encode_dict_carry(
				{ writer: output, state: { ..held, depth: held.depth + 1 } },
				count,
				|items, add| write(
					Items.(ItemsBody.{ container: items.container, held: items.state }),
					|Items.(ItemsBody.({ container: item_container, held: item_held })), write_key, write_value| add({ container: item_container, state: item_held }, |entry| write_key(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held }), |entry| write_value(Enc.(EncBody.{ writer: entry.writer, held: entry.state })).map_ok(|Enc.(EncBody.({ writer: done_writer, held: done_held }))| { writer: done_writer, state: done_held })).map_ok(|done| Items.(ItemsBody.{ container: done.container, held: done.state })),
				).map_ok(|Items.(ItemsBody.({ container: done_container, held: done_held }))| { container: done_container, state: done_held }),
			).map_ok(|done| Enc.(EncBody.{ writer: done.writer, held: { ..done.state, depth: outer } }))
		}

		## Open the checked list; CBOR owns its count and end position.
		parse_list_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_list_start = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_list_start(config, cursor)? {
			Counted({ len, rest }) => Ok(Counted({ len, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts }) }))
			Uncounted(rest) => Ok(Uncounted(State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts })))
		}

		## Open the checked dict; CBOR owns its count and end position. The
		## parse notes the open dictionary until its keys are read, so a
		## handwritten parser that opens one here calls `parse_dict_after_key`
		## after each key, as a derived parser does.
		parse_dict_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_dict_start = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_dict_start(config, cursor)? {
			Counted({ len, rest }) => Ok(Counted({ len, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: opened_dict(dicts, Left(len)) }) }))
			Uncounted(rest) => Ok(Uncounted(State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: opened_dict(dicts, UntilDone) })))
		}

		## Open the checked record; CBOR owns its count and end position.
		parse_record_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Error)
		parse_record_start = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_record_start(config, cursor)? {
			Counted({ len, rest }) => Ok(Counted({ len, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts }) }))
			Uncounted(rest) => Ok(Uncounted(State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts })))
		}

		## Advance within the checked container, preserving its associated files.
		parse_list_next : Format, State -> Try([Item(State), Done(State)], Error)
		parse_list_next = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_list_next(config, cursor)? {
			Item(reader) => Ok(Item(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
		}

		## Advance within the checked container, preserving its associated files.
		parse_list_after_item : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_list_after_item = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_list_after_item(config, cursor)? {
			Continue(reader) => Ok(Continue(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
		}

		## Advance within the checked container, preserving its associated files.
		parse_dict_next : Format, State -> Try([Entry(State), Done(State)], Error)
		parse_dict_next = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_dict_next(config, cursor)? {
			Entry(reader) => Ok(Entry(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: closed_dict(dicts) })))
		}

		## Advance within the checked container, preserving its associated files.
		parse_dict_after_entry : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_dict_after_entry = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_dict_after_entry(config, cursor)? {
			Continue(reader) => Ok(Continue(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: closed_dict(dicts) })))
		}

		## Advance within the checked container, preserving its associated files.
		parse_record_after_field : Format, State -> Try([Continue(State), Done(State)], Error)
		parse_record_after_field = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_record_after_field(config, cursor)? {
			Continue(reader) => Ok(Continue(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
		}

		## Preserve the compiler's field shape in this wrapper. The explicit
		## annotation avoids https://github.com/roc-lang/roc/issues/13052.
		parse_record_field : Format, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Error)
		parse_record_field = |_, names, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| match Cbor.parse_record_field(config, names, cursor)? {
			Field({ field, rest }) => Ok(Field({ field, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts }) }))
			TryField({ name, rest }) => Ok(TryField({ name, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts }) }))
			TryFieldCaseless({ name, rest }) => Ok(TryFieldCaseless({ name, rest: State.(StateBody.{ cbor: config, reader: rest, files: files, dicts: dicts }) }))
			Continue(reader) => Ok(Continue(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
			Done(reader) => Ok(Done(State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts })))
		}

		## Delegate the checked cursor transition without reading bytes here.
		skip_record_field : Format, State -> Try(State, Error)
		skip_record_field = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.skip_record_field(config, cursor).map_ok(|reader| State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts }))

		## Delegate the checked cursor transition without reading bytes here,
		## and count the key against the innermost open dictionary.
		parse_dict_after_key : Format, State -> Try(State, Error)
		parse_dict_after_key = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_dict_after_key(config, cursor).map_ok(|reader| State.(StateBody.{ cbor: config, reader, files: files, dicts: read_key(dicts) }))

		## Delegate the checked cursor transition without reading bytes here.
		parse_tuple_start : Format, State, U64 -> Try(State, Error)
		parse_tuple_start = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts })), count| Cbor.parse_tuple_start(config, cursor, count).map_ok(|reader| State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts }))

		## Delegate the checked cursor transition without reading bytes here.
		parse_tuple_next : Format, State, U64, U64 -> Try(State, Error)
		parse_tuple_next = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts })), index, count| Cbor.parse_tuple_next(config, cursor, index, count).map_ok(|reader| State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts }))

		## Delegate the checked cursor transition without reading bytes here.
		parse_tuple_end : Format, State, U64 -> Try(State, Error)
		parse_tuple_end = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts })), count| Cbor.parse_tuple_end(config, cursor, count).map_ok(|reader| State.(StateBody.{ cbor: config, reader, files: files, dicts: dicts }))

		## Read the external union through CBOR tokens and checked containers;
		## the caller's spec keeps the typed payload parsers.
		parse_tag_union : Format, Encoding.ParseTagUnionSpec(a, Format, State, Error), State -> Try({ value : a, rest : State }, Error)
		parse_tag_union = |encoding, spec, state| {
			failure = Cbor.invalid_value(config_of(state), reader_of(state))
			match Cbor.peek(config_of(state), reader_of(state))? {
				Text => {
					tag = Format.parse_str(encoding, state)?
					Encoding.ParseTagUnionSpec.parse(
						spec,
						{
							tag: tag.value,
							encoding,
							state: tag.rest,
							start_payloads: |current, count| if (count == 0) Ok(current) else Err(failure),
							next_payload: |_, _, _| Err(failure),
							finish_payloads: |current, _| Ok(current),
							missing: failure,
						},
					)
				}
				Map => {
					# A tag's one-entry map is not a dictionary: its name is
					# read as text, with no key hooks, so it is not noted.
					current = match Cbor.parse_dict_start(config_of(state), reader_of(state))? {
						Counted({ len: 1, rest }) => with_reader(state, rest)
						_ => return Err(failure)
					}
					tag = Format.parse_str(encoding, current)?
					Encoding.ParseTagUnionSpec.parse(
						spec,
						{
							tag: tag.value,
							encoding,
							state: tag.rest,
							start_payloads: |cursor, count| if count == 1 {
								Ok(cursor)
							} else if count > 1 {
								Format.parse_tuple_start(encoding, cursor, count)
							} else Err(failure),
							next_payload: |cursor, _, _| Ok(cursor),
							finish_payloads: |cursor, count| if (count == 1) Ok(cursor) else Format.parse_tuple_end(encoding, cursor, count),
							missing: failure,
						},
					)
				}
				_ => Err(failure)
			}
		}

		# There is deliberately no `encode_key_start` or `parse_key_start`: a
		# dictionary key that is a tuple, a record or a nominal type is then a
		# `roc check` error naming the missing method. With the hooks such a
		# key passes `roc check` and crashes the compiler when it is built
		# (https://github.com/roc-lang/roc/issues/12919), and a derived parser
		# would merge two keys its type equates with no hook that sees them
		# (https://github.com/roc-lang/roc/issues/13057).

		## The same CBOR scalar form at a dictionary key position.
		encode_key_str : Format, Str, Enc -> Try(Enc, [])
		encode_key_str = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_str(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_str : Format, State -> Try({ value : Str, rest : State }, Error)
		parse_key_str = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_str(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_bool : Format, Bool, Enc -> Try(Enc, [])
		encode_key_bool = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_bool(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_bool : Format, State -> Try({ value : Bool, rest : State }, Error)
		parse_key_bool = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_bool(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_u8 : Format, U8, Enc -> Try(Enc, [])
		encode_key_u8 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u8(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_u8 : Format, State -> Try({ value : U8, rest : State }, Error)
		parse_key_u8 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_u8(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_i8 : Format, I8, Enc -> Try(Enc, [])
		encode_key_i8 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i8(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_i8 : Format, State -> Try({ value : I8, rest : State }, Error)
		parse_key_i8 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_i8(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_u16 : Format, U16, Enc -> Try(Enc, [])
		encode_key_u16 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u16(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_u16 : Format, State -> Try({ value : U16, rest : State }, Error)
		parse_key_u16 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_u16(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_i16 : Format, I16, Enc -> Try(Enc, [])
		encode_key_i16 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i16(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_i16 : Format, State -> Try({ value : I16, rest : State }, Error)
		parse_key_i16 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_i16(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_u32 : Format, U32, Enc -> Try(Enc, [])
		encode_key_u32 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_u32 : Format, State -> Try({ value : U32, rest : State }, Error)
		parse_key_u32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_u32(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_i32 : Format, I32, Enc -> Try(Enc, [])
		encode_key_i32 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_i32 : Format, State -> Try({ value : I32, rest : State }, Error)
		parse_key_i32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_i32(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_u64 : Format, U64, Enc -> Try(Enc, [])
		encode_key_u64 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_u64 : Format, State -> Try({ value : U64, rest : State }, Error)
		parse_key_u64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_u64(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_i64 : Format, I64, Enc -> Try(Enc, [])
		encode_key_i64 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_i64 : Format, State -> Try({ value : I64, rest : State }, Error)
		parse_key_i64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_i64(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_u128 : Format, U128, Enc -> Try(Enc, [])
		encode_key_u128 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_u128(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_u128 : Format, State -> Try({ value : U128, rest : State }, Error)
		parse_key_u128 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_u128(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_i128 : Format, I128, Enc -> Try(Enc, [])
		encode_key_i128 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_i128(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_i128 : Format, State -> Try({ value : I128, rest : State }, Error)
		parse_key_i128 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_i128(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## The same CBOR scalar form at a dictionary key position.
		encode_key_f32 : Format, F32, Enc -> Try(Enc, [])
		encode_key_f32 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_f32(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor, and refuse
		## a zero whose other sign this dictionary already has as a key.
		parse_key_f32 : Format, State -> Try({ value : F32, rest : State }, Error)
		parse_key_f32 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| {
			parsed = Cbor.parse_key_f32(config, cursor)?
			zero = if (parsed.value != 0.0) NotZero else if (parsed.value.to_bits() == 0) Positive else Negative
			noted = float_key(dicts, zero) ? |BothZeros| Cbor.invalid_value(config, cursor)
			Ok({ value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: noted }) })
		}

		## The same CBOR scalar form at a dictionary key position.
		encode_key_f64 : Format, F64, Enc -> Try(Enc, [])
		encode_key_f64 = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_f64(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor, and refuse
		## a zero whose other sign this dictionary already has as a key.
		parse_key_f64 : Format, State -> Try({ value : F64, rest : State }, Error)
		parse_key_f64 = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| {
			parsed = Cbor.parse_key_f64(config, cursor)?
			zero = if (parsed.value != 0.0) NotZero else if (parsed.value.to_bits() == 0) Positive else Negative
			noted = float_key(dicts, zero) ? |BothZeros| Cbor.invalid_value(config, cursor)
			Ok({ value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: noted }) })
		}

		## The same CBOR scalar form at a dictionary key position.
		encode_key_dec : Format, Dec, Enc -> Try(Enc, [])
		encode_key_dec = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_dec(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Apply CBOR's exact scalar-key rule to the checked cursor.
		parse_key_dec : Format, State -> Try({ value : Dec, rest : State }, Error)
		parse_key_dec = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_key_dec(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## A payload-free tag key uses the library's bare-text form.
		encode_key_tag : Format, Enc, Str -> Try(Enc, [])
		encode_key_tag = |_, Enc.(EncBody.({ writer: output, held })), name| Cbor.encode_str(name, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## A typed tag key uses the same external-union bridge as a value.
		parse_key_tag_union : Format, Encoding.ParseTagUnionSpec(a, Format, State, Error), State -> Try({ value : a, rest : State }, Error)
		parse_key_tag_union = |encoding, spec, state| Format.parse_tag_union(encoding, spec, state)

		## Write a bulk byte string without exposing the writer's representation.
		encode_bytes : Format, List(U8), Enc -> Try(Enc, [])
		encode_bytes = |_, value, Enc.(EncBody.({ writer: output, held }))| Cbor.encode_bytes(value, output).map_ok(|writer| Enc.(EncBody.{ writer, held: held }))

		## Read a bulk byte string, which may share the checked input buffer.
		parse_bytes : Format, State -> Try({ value : List(U8), rest : State }, Error)
		parse_bytes = |_, State.(StateBody.({ cbor: config, reader: cursor, files, dicts }))| Cbor.parse_bytes(config, cursor).map_ok(|parsed| { value: parsed.value, rest: State.(StateBody.{ cbor: config, reader: parsed.rest, files: files, dicts: dicts }) })

		## A file's bytes stay behind its handle. Only its index and range
		## metadata enter the six-item CBOR array beside that owned file list.
		encode_file : Format, Engine.File, Enc -> Try(Enc, [])
		encode_file = |_, file, Enc.(EncBody.({ writer: output, held }))| {
			{ name, mime, size, start, len } = Core.file_parts(file)
			index = held.files.len()
			opened = Enc.(EncBody.{ writer: output, held: { ..held, files: held.files.append(file) } })
			Format.encode_tuple(
				opened,
				6,
				|items, add| {
					a = add(items, |entry| Format.encode_u64(index, entry))?
					b = add(a, |entry| Format.encode_str(name, entry))?
					c = add(b, |entry| Format.encode_str(mime, entry))?
					d = add(c, |entry| Format.encode_u64(size, entry))?
					e = add(d, |entry| Format.encode_u64(start, entry))?
					add(e, |entry| Format.encode_u64(len, entry))
				},
			)
		}

		## Resolve the declared file index against the files this instance
		## owns, then let the engine validate its exact declared range.
		parse_file : Format, State -> Try({ value : Engine.File, rest : State }, Error)
		parse_file = |encoding, current| {
			opened = Format.parse_tuple_start(encoding, current, 6)?
			at_index = Cbor.invalid_value(config_of(opened), reader_of(opened))
			{ value: index, rest: after_index } = Format.parse_u64(encoding, opened)?
			source = files_of(after_index).get(index) ? |_| at_index
			{ value: name, rest: after_name } = Format.parse_str(encoding, after_index)?
			{ value: mime, rest: after_mime } = Format.parse_str(encoding, after_name)?
			{ value: size, rest: after_size } = Format.parse_u64(encoding, after_mime)?
			{ value: start, rest: after_start } = Format.parse_u64(encoding, after_size)?
			{ value: len, rest: after_len } = Format.parse_u64(encoding, after_start)?
			rest = Format.parse_tuple_end(encoding, after_len, 6)?
			file = Core.placed_file(source, { name, mime, size, start, len }) ? |_| Cbor.invalid_value(config_of(rest), reader_of(rest))
			Ok({ value: file, rest })
		}
	}

	## Encode a worker input or answer, keeping the actual owned files beside
	## its bytes. A malformed custom encoder is a contract fault naming the task.
	encode_with_files : Str, a -> { bytes : List(U8), files : List(Engine.File), deep : Bool } where [a.Sendable]
	encode_with_files = |name, value| match encode_payload(value) {
		Ok(encoded) => encoded
		Err(CountMismatch) => crash "contract: worker task \"${name}\" encoded the wrong number of CBOR items"
		Err(DuplicateMapKey) => crash "contract: worker task \"${name}\" encoded duplicate CBOR map keys"
	}

	## Decode an input or answer with the file values owned by its receiving
	## instance. The worker layer supplies its task-specific failure message.
	decode_with_held : List(U8), List(Engine.File) -> Try(a, Error) where [a.Sendable]
	decode_with_held = |bytes, files| decode_payload(bytes, files)

	## Encode an ordinary no-file value for platform tests of the derived format.
	encode : a -> List(U8) where [a.Sendable]
	encode = |value| {
		encoded = WorkerCodec.encode_with_files("payload", value)
		if !encoded.files.is_empty() {
			crash "contract: a file crosses only in a worker task's input or answer"
		}
		if encoded.deep {
			crash "internal: a platform test encoded a value nested past the bound with encode; use try_encode"
		}
		encoded.bytes
	}

	## Expose the reader's depth refusal to platform tests of own-encoded values.
	try_encode : a -> Try(List(U8), [TooDeep]) where [a.Sendable]
	try_encode = |value| {
		encoded = WorkerCodec.encode_with_files("payload", value)
		if !encoded.files.is_empty() {
			crash "contract: a file crosses only in a worker task's input or answer"
		}
		if (encoded.deep) Err(TooDeep) else Ok(encoded.bytes)
	}

	## Decode an ordinary no-file value for platform format tests.
	decode : List(U8) -> Try(a, Error) where [a.Sendable]
	decode = |bytes| decode_payload(bytes, [])

}

## The unexposed codec's writer entrypoint. The format types alone receive
## public aliases; applications cannot reach this module or its worker functions.
encode_payload : a -> Try({ bytes : List(U8), files : List(Engine.File), deep : Bool }, [CountMismatch, DuplicateMapKey]) where [a.WorkerCodec.Sendable]
encode_payload = |value| {
	Shape : a
	encoding = WorkerCodec.Format.{}
	WorkerCodec.Enc.(WorkerCodec.EncBody.({ writer, held })) = Shape.encoder_for(encoding)(value, WorkerCodec.Enc.(WorkerCodec.EncBody.{ writer: Cbor.Writer.new({ key_order: Sorted }), held: { files: [], depth: 0, over: Bool.False } }))?
	if held.over {
		Ok({ bytes: [], files: [], deep: Bool.True })
	} else {
		bytes = Cbor.Writer.finish(writer)?
		Ok({ bytes, files: held.files, deep: Bool.False })
	}
}

## Package-local checked reader entrypoint. The complete CBOR walk happens
## before typed callbacks, which carry the actual owned files unchanged.
decode_payload : List(U8), List(Engine.File) -> Try(a, WorkerCodec.Error) where [a.WorkerCodec.Sendable]
decode_payload = |bytes, files| {
	Shape : a
	opened = Cbor.Reader.new(bytes, { key_order: Sorted, unknown_fields: Reject, max_depth: max_cbor_depth, decimals: EncoderForm, floats: EncoderForm, empty_byte_lists: Reject })?
	encoding = WorkerCodec.Format.{}
	{ value, rest } = Shape.parser_for(encoding)(WorkerCodec.State.(WorkerCodec.StateBody.{ cbor: opened.cbor, reader: opened.reader, files, dicts: [] }))?
	Cbor.Reader.finish(reader_of(rest))?
	Ok(value)
}

## How many containers of the app's own data one worker input or answer may
## nest: each list, set, dictionary, record, tuple and tag with a payload is
## one level, and a file is one. A container met at the bound is not written
## (`too_deep`), so encoding cannot run out of stack, and the encode is
## refused with `TooDeep`. 128 is measured, not derived: a Chrome dedicated
## worker on a development build overflows V8's native stack encoding about
## 113 levels of a record holding a list and about 240 of a tag, and
## optimized builds and the page go about 3 to 10 times deeper, so 128 keeps
## a margin of 1.75 in the weakest configuration. Roc itself cannot drop or
## compare a recursive value much deeper than about 1,900 levels in a
## worker (https://github.com/roc-lang/roc/issues/12917), and development
## Wasm frames are about 3 times optimized ones
## (https://github.com/roc-lang/roc/issues/12922). A handwritten codec that
## recurses without the container hooks is not counted. Change the bound
## here only; the reader's backstop follows it.
max_nesting : U64
max_nesting = 128

## The deepest CBOR structure an encode within `max_nesting` writes: a tag
## with several payloads is two levels (its map and their array), and a
## `Dec` fraction leaf two more (its tag and array). The reader refuses
## anything deeper before any typed callback runs.
max_cbor_depth : U64
max_cbor_depth = 2 * max_nesting + 2

## A container met at the nesting bound: one placeholder item keeps the
## enclosing container's count whole, its contents are not visited, and the
## encode is marked to be refused.
too_deep : Cbor.Writer, WorkerCodec.Held -> Try(WorkerCodec.Enc, err)
too_deep = |output, held| Cbor.encode_null(output).map_ok(|writer| WorkerCodec.Enc.(WorkerCodec.EncBody.{ writer, held: { ..held, over: Bool.True } }))

## The reader's configuration in a parser state, which every `Cbor.parse_*`
## step takes.
config_of : WorkerCodec.State -> Cbor
config_of = |WorkerCodec.State.(WorkerCodec.StateBody.({ cbor, .. }))| cbor

## The cursor of a parser state, for a diagnostic position or the end check.
reader_of : WorkerCodec.State -> Cbor.Reader
reader_of = |WorkerCodec.State.(WorkerCodec.StateBody.({ reader, .. }))| reader

## The files a parser state was handed, which a file's place indexes.
files_of : WorkerCodec.State -> List(Engine.File)
files_of = |WorkerCodec.State.(WorkerCodec.StateBody.({ files, .. }))| files

## The same parser state at another cursor, for a tag's map read directly.
with_reader : WorkerCodec.State, Cbor.Reader -> WorkerCodec.State
with_reader = |WorkerCodec.State.(WorkerCodec.StateBody.({ cbor, files, dicts, .. })), reader| WorkerCodec.State.(WorkerCodec.StateBody.{ cbor, reader, files, dicts })

## The open dictionaries without the counted ones whose keys have all been
## read. The last one left is the dictionary whose key is being read:
## a dictionary nested in a key or a value is opened, and finishes its keys,
## between two keys of the dictionary around it.
unfinished : List(WorkerCodec.OpenDict) -> List(WorkerCodec.OpenDict)
unfinished = |dicts| match dicts.last() {
	Ok({ keys: Left(0), .. }) => unfinished(dicts.drop_last(1))
	_ => dicts
}

## Note a dictionary the parse opens. One with no entries has no keys to
## check. The finished ones are dropped first, so the list stays within the
## reader's nesting bound.
opened_dict : List(WorkerCodec.OpenDict), [Left(U64), UntilDone] -> List(WorkerCodec.OpenDict)
opened_dict = |dicts, keys| match keys {
	Left(0) => dicts
	_ => unfinished(dicts).append({ keys, zero: Unseen })
}

## Count one key read against the innermost unfinished dictionary.
read_key : List(WorkerCodec.OpenDict) -> List(WorkerCodec.OpenDict)
read_key = |dicts| {
	open = unfinished(dicts)
	match open.last() {
		Ok({ keys: Left(left), zero }) => open.drop_last(1).append({ keys: Left(left - 1), zero })
		_ => open
	}
}

## Drop an uncounted dictionary its reader has found the end of.
closed_dict : List(WorkerCodec.OpenDict) -> List(WorkerCodec.OpenDict)
closed_dict = |dicts| {
	open = unfinished(dicts)
	match open.last() {
		Ok({ keys: UntilDone, .. }) => open.drop_last(1)
		_ => open
	}
}

## Note the sign of a float zero key in its dictionary. The second sign of
## zero in one dictionary is refused: builtin float equality makes both one
## key, so inserting it would overwrite the entry of the first
## (https://github.com/roc-lang/roc/issues/13057). Every key type the
## format admits (a number, `Bool`, `Str` or a tag without payloads) has the
## builtin equality, so this is the only collision a key can have under the
## strict reader.
float_key : List(WorkerCodec.OpenDict), [NotZero, Positive, Negative] -> Try(List(WorkerCodec.OpenDict), [BothZeros])
float_key = |dicts, key| {
	open = unfinished(dicts)
	match (key, open.last()) {
		(NotZero, _) => Ok(open)
		(_, Err(ListWasEmpty)) => Ok(open)
		(Positive, Ok({ zero: Negative, .. })) => Err(BothZeros)
		(Negative, Ok({ zero: Positive, .. })) => Err(BothZeros)
		(Positive, Ok(current)) => Ok(open.drop_last(1).append({ ..current, zero: Positive }))
		(Negative, Ok(current)) => Ok(open.drop_last(1).append({ ..current, zero: Negative }))
	}
}
