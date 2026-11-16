import WorkerCodec
import Core
import Engine

## The derived payload types an app uses in worker task signatures.
## A task's types derive their codecs over the platform's payload format;
## the platform carries the resulting CBOR item and the files it owns
## between instances of one module.
Wire := [].{

	# The constraint names the unexposed format's types: derivation cannot
	# resolve a format's hooks through a re-exported alias
	# (https://github.com/roc-lang/roc/issues/13022), and an app needs no
	# name for them. A handwritten codec is generic over its format and
	# names only the hooks it calls.
	## Types that can cross between instances, with derived or handwritten
	## codecs. Functions and absent codecs are compile errors.
	a.Sendable :
		where [
			a.encoder_for : WorkerCodec.Format -> (a, WorkerCodec.Enc -> Try(WorkerCodec.Enc, [])),
			a.parser_for : WorkerCodec.Format -> (WorkerCodec.State -> Try({ value : a, rest : WorkerCodec.State }, WorkerCodec.Error)),
		]

	## A bulk byte string, written and read as one block. Decoding may share
	## the input buffer. An empty Bytes is a CBOR byte string; an ordinary
	## empty derived list is an array, so the two types are distinct at empty.
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

}

## Whether a value comes back from its own payload unchanged.
round_trips : a -> Bool where [a.Wire.Sendable, a.is_eq : a, a -> Bool]
round_trips = |value|
	match WorkerCodec.decode(WorkerCodec.encode(value)) {
		Ok(decoded) => decoded == value
		Err(_) => False
	}

## Whether a value's payload, decoded and encoded again, is the same bytes.
## Floats are compared this way, since a NaN is not equal to itself.
same_bytes : a -> Bool where [a.Wire.Sendable]
same_bytes = |value| {
	payload = WorkerCodec.encode(value)
	decoded : Try(a, WorkerCodec.Error)
	decoded = WorkerCodec.decode(payload)
	match decoded {
		Ok(back) => WorkerCodec.encode(back) == payload
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

## A payload and the files beside it, for a value within the bound.
held : a -> { bytes : List(U8), files : List(Engine.File) } where [a.Wire.Sendable]
held = |value| match WorkerCodec.encode_with_files("wire unit", value) {
	Ok(encoded) => encoded
	Err(TooDeep) => crash "internal: a platform test's value is nested past the bound"
	Err(NanKeys) => crash "internal: a platform test's value holds two NaN keys in one dictionary"
}

## A chain of tags with two payloads, ending in a payload-free tag.
Deep := [Down(Deep, Dec), Stop].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## A chain of tags with two payloads, each holding a `U128`.
Wide := [Across(Wide, U128), Edge].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## A chain of tags with two payloads, each holding a file.
Paired := [Pair(Paired, Engine.File), Unpaired].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## A chain of one-payload tags holding a file at its end.
Filed := [In(Filed), Doc(Engine.File)].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

## `levels` nested `Down`s, each holding the decimal `leaf`.
down : U64, Dec -> Deep
down = |levels, leaf| {
	var $value = Deep.Stop
	for _ in (0.U64).until(levels) {
		$value = Deep.Down($value, leaf)
	}
	$value
}

## `levels` nested `Across`es, each holding `leaf`.
across : U64, U128 -> Wide
across = |levels, leaf| {
	var $value = Wide.Edge
	for _ in (0.U64).until(levels) {
		$value = Wide.Across($value, leaf)
	}
	$value
}

## `levels` nested `Pair`s, each holding `file`.
paired : U64, Engine.File -> Paired
paired = |levels, file| {
	var $value = Paired.Unpaired
	for _ in (0.U64).until(levels) {
		$value = Paired.Pair($value, file)
	}
	$value
}

## A file inside `levels` nested `In`s and its own `Doc`.
filed : U64, Engine.File -> Filed
filed = |levels, file| {
	var $value = Filed.Doc(file)
	for _ in (0.U64).until(levels) {
		$value = Filed.In($value)
	}
	$value
}

## `levels` nested `Nested` records, the innermost with no children.
nest : U64 -> Nested
nest = |levels| {
	var $value = Nested.{ children: [] }
	for _ in (1.U64).until(levels) {
		$value = Nested.{ children: [$value] }
	}
	$value
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

## Floats retain zero signs and ordinary values; NaNs normalize to one canonical NaN.
expect {
	values = (F64.from_bits(0x8000000000000000), F64.infinity, -F64.infinity, F64.nan, F64.highest, F32.from_bits(0x80000000), F32.infinity, F32.nan)
	payload = WorkerCodec.encode(values)
	decoded : Try((F64, F64, F64, F64, F64, F32, F32, F32), WorkerCodec.Error)
	decoded = WorkerCodec.decode(payload)
	match decoded {
		Ok((a, b, c, d, e, f, g, h)) => {
			doubles = [F64.to_bits(a), F64.to_bits(b), F64.to_bits(c), F64.to_bits(e)] == [F64.to_bits(values.0), F64.to_bits(values.1), F64.to_bits(values.2), F64.to_bits(values.4)]
			singles = [F32.to_bits(f), F32.to_bits(g)] == [F32.to_bits(values.5), F32.to_bits(values.6)] and h.is_nan()
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
expect WorkerCodec.encode(Dict.from_list([("b", 2.U8), ("a", 1)])) == WorkerCodec.encode(Dict.from_list([("a", 1.U8), ("b", 2)]))

## Nominal types that opt in, recursive ones included.
expect round_trips(Tree.Node(Tree.Leaf, 3, Tree.Node(Tree.Leaf, 4, Tree.Leaf))) and round_trips(Nested.{ children: [Nested.{ children: [] }, Nested.{ children: [Nested.{ children: [] }] }] })

## `Bytes` round trips, and is laid out exactly as the `List(U8)` it wraps.
expect {
	bytes = Wire.Bytes.from_list([0, 1, 255])
	decoded : Try(List(U8), WorkerCodec.Error)
	decoded = WorkerCodec.decode(WorkerCodec.encode(bytes))
	round_trips(bytes) and WorkerCodec.encode(bytes) == WorkerCodec.encode([0.U8, 1, 255]) and decoded == Ok([0, 1, 255])
}

## Empty bulk bytes and an empty list have distinct encodings, and the
## strict reader reads each only as its own type: an empty `Bytes` is the
## empty byte string `40`, an empty `List(U8)` the empty array `80`. Both
## ends of a payload always have the same type, so neither cross-read can
## happen between two instances; a non-empty one reads as either.
expect {
	empty_bytes = WorkerCodec.encode(Wire.Bytes.from_list([]))
	no_bytes : List(U8)
	no_bytes = []
	empty_list = WorkerCodec.encode(no_bytes)
	as_list : Try(List(U8), WorkerCodec.Error)
	as_list = WorkerCodec.decode(empty_bytes)
	as_bytes : Try(Wire.Bytes, WorkerCodec.Error)
	as_bytes = WorkerCodec.decode(empty_list)
	full : Try(Wire.Bytes, WorkerCodec.Error)
	full = WorkerCodec.decode(WorkerCodec.encode([7.U8]))
	empty_bytes == [0x40] and empty_list == [0x80] and as_list.is_err() and as_bytes.is_err() and full == Ok(Wire.Bytes.from_list([7]))
}

## Exact bytes pin the layout of numbers, Bool and strings.
expect {
	actual =
		\\u16: ${Str.inspect(WorkerCodec.encode(258.U16))}
		\\i32: ${Str.inspect(WorkerCodec.encode(-2.I32))}
		\\f64: ${Str.inspect(WorkerCodec.encode(1.0.F64))}
		\\dec: ${Str.inspect(WorkerCodec.encode(0.000000000000000001.Dec))}
		\\bool: ${Str.inspect(WorkerCodec.encode((Bool.True, Bool.False)))}
		\\str: ${Str.inspect(WorkerCodec.encode("hé"))}
	expected =
		\\u16: [25, 1, 2]
		\\i32: [33]
		\\f64: [249, 60, 0]
		\\dec: [196, 130, 49, 1]
		\\bool: [130, 245, 244]
		\\str: [99, 104, 195, 169]
	actual == expected
}

## Exact CBOR bytes pin encoded-key ordering, optional-field maps, tags,
## sorted dictionary entries and a multi-byte byte-string head.
expect {
	some : Profile
	some = { name: "n", age: 9 }
	tag : [Small, Large(U8)]
	tag = Large(7)
	long = WorkerCodec.encode(List.repeat(0.U8, 300)).take_first(3)
	actual =
		\\record: ${Str.inspect(WorkerCodec.encode({ b9: 1.U8, b10: 2.U8, a_b: 3.U8, a1: 4.U8, a: 5.U8 }))}
		\\named: ${Str.inspect(WorkerCodec.encode(some))}
		\\empty: ${Str.inspect(WorkerCodec.encode({}))}
		\\tag: ${Str.inspect(WorkerCodec.encode(tag))}
		\\dict: ${Str.inspect(WorkerCodec.encode(Dict.from_list([("b", 2.U8), ("a", 1)])))}
		\\count: ${Str.inspect(long)}
	expected =
		\\record: [165, 97, 97, 5, 98, 97, 49, 4, 98, 98, 57, 1, 99, 97, 95, 98, 3, 99, 98, 49, 48, 2]
		\\named: [162, 99, 97, 103, 101, 9, 100, 110, 97, 109, 101, 97, 110]
		\\empty: [160]
		\\tag: [161, 101, 76, 97, 114, 103, 101, 7]
		\\dict: [162, 97, 97, 1, 97, 98, 2]
		\\count: [89, 1, 44]
	actual == expected
}

## Every strict prefix of a payload is refused, for every shape at once.
expect {
	value : Sample
	value = { shapes: [Rect({ w: 1, h: 2 }), Path([(3, 4)])], text: "some text", index: Dict.from_list([("k", [1])]), who: { name: "n", age: 2 } }
	accepted = |bytes| {
		decoded : Try(Sample, WorkerCodec.Error)
		decoded = WorkerCodec.decode(bytes)
		decoded.is_ok()
	}
	prefixes_refused(WorkerCodec.encode(value), accepted)
}

## Input left after the value is refused.
expect {
	decoded : Try({ a : U8 }, WorkerCodec.Error)
	decoded = WorkerCodec.decode(WorkerCodec.encode({ a: 1.U8 }).append(0))
	decoded == Err(InvalidCbor(4))
}

## A tag name the type does not have is refused.
expect {
	decoded : Try([Small, Large(U8)], WorkerCodec.Error)
	decoded = WorkerCodec.decode([161, 100, 72, 117, 103, 101, 1])
	decoded.is_err()
}

## A count larger than the rest of the input is refused before anything is
## allocated for it, however large it claims to be.
expect {
	text : Try(Str, WorkerCodec.Error)
	text = WorkerCodec.decode([0x65, 97])
	huge : Try(List(U64), WorkerCodec.Error)
	huge = WorkerCodec.decode([0x9b, 255, 255, 255, 255, 255, 255, 255, 255])
	units : Try(List({}), WorkerCodec.Error)
	units = WorkerCodec.decode([0x83, 0xa0, 0xa0])
	text.is_err() and huge.is_err() and units.is_err()
}

## Invalid UTF-8 in a string is refused.
expect {
	decoded : Try(Str, WorkerCodec.Error)
	decoded = WorkerCodec.decode([0x62, 195, 40])
	decoded.is_err()
}

## Invalid scalar forms, padded CBOR heads and impossible container counts are refused.
expect {
	flag : Try(Bool, WorkerCodec.Error)
	flag = WorkerCodec.decode([2])
	padded : Try(Str, WorkerCodec.Error)
	padded = WorkerCodec.decode([0x78, 0x00])
	overflow : Try(List(U8), WorkerCodec.Error)
	overflow = WorkerCodec.decode([255, 255, 255, 255, 255, 255, 255, 255, 255, 2])
	flag.is_err() and padded.is_err() and overflow.is_err()
}

## A record count above the type's field count, a named field out of order,
## a named field the type lacks, and a missing required field are refused.
expect {
	wide : Try({ a : U8, b : U8 }, WorkerCodec.Error)
	wide = WorkerCodec.decode([0xa3, 0x61, 97, 1, 0x61, 98, 2, 0x61, 99, 3])
	unordered : Try(Profile, WorkerCodec.Error)
	unordered = WorkerCodec.decode([0xa2, 0x64, 110, 97, 109, 101, 0x61, 110, 0x63, 97, 103, 101, 9])
	unknown : Try(Profile, WorkerCodec.Error)
	unknown = WorkerCodec.decode([0xa1, 0x63, 122, 122, 122, 9])
	missing : Try(Profile, WorkerCodec.Error)
	missing = WorkerCodec.decode([0xa1, 0x63, 97, 103, 101, 9])
	wide.is_err() and unordered.is_err() and unknown.is_err() and missing == Err(MissingRequiredField("name"))
}

## Dictionary keys out of order, or repeated, are refused.
expect {
	unordered : Try(Dict(Str, U8), WorkerCodec.Error)
	unordered = WorkerCodec.decode([0xa2, 0x61, 98, 2, 0x61, 97, 1])
	repeated : Try(Dict(Str, U8), WorkerCodec.Error)
	repeated = WorkerCodec.decode([0xa2, 0x61, 97, 1, 0x61, 97, 2])
	unordered.is_err() and repeated.is_err()
}

## Nesting is counted in containers of the app's own data, at most 128 on
## any path: each `Node` of a tree is one, a record or a dictionary around
## it one more, and each `Nested` two (its record and its list). A value at
## the bound round trips; one level more is refused with `TooDeep` before
## anything past the bound is visited.
expect {
	agrees = |value| WorkerCodec.decode(WorkerCodec.encode(value)) == Ok(value)
	tree_at = left_spine(128)
	wrapped_at = { inner: left_spine(127) }
	keyed_at = Dict.from_list([("k", left_spine(127))])
	nested_at = nest(64)
	actual =
		\\tree: ${Str.inspect([agrees(tree_at), WorkerCodec.try_encode(left_spine(129)) == Err(TooDeep)])}
		\\wrapped: ${Str.inspect([agrees(wrapped_at), WorkerCodec.try_encode({ inner: left_spine(128) }) == Err(TooDeep)])}
		\\keyed: ${Str.inspect([agrees(keyed_at), WorkerCodec.try_encode(Dict.from_list([("k", left_spine(128))])) == Err(TooDeep)])}
		\\nested: ${Str.inspect([agrees(nested_at), WorkerCodec.try_encode(nest(65)) == Err(TooDeep)])}
	expected =
		\\tree: [True, True]
		\\wrapped: [True, True]
		\\keyed: [True, True]
		\\nested: [True, True]
	actual == expected
}

## The deepest CBOR a value within the bound writes is read: 128 tags with
## two payloads are 256 levels of maps and arrays, and the deepest leaf in
## the last is three more (a `Dec` fraction whose mantissa is past 64 bits:
## tag 4, its array and a bignum's tag), the reader's backstop of 259. A
## `U128` past 64 bits is one level, a bignum's tag. A file is a level of
## its own, so it is accepted inside 127 counted levels and refused inside
## 128.
expect {
	file = match Core.placed_file(Core.held_file(Box.box(1)), { name: "a.bin", mime: "", size: 2, start: 0, len: 2 }) {
		Ok(f) => f
		Err(_) => crash "a range outside its file"
	}
	# Past 64 bits with no trailing zero digit, so the mantissa is a bignum.
	big_fraction = 100000000000.000000001
	big_u128 = 340282366920938463463374607431768211455
	filed_at = held(filed(126, file))
	filed_back : Try(Filed, WorkerCodec.Error)
	filed_back = WorkerCodec.decode_with_held(filed_at.bytes, filed_at.files)
	paired_at = held(paired(127, file))
	paired_back : Try(Paired, WorkerCodec.Error)
	paired_back = WorkerCodec.decode_with_held(paired_at.bytes, paired_at.files)
	actual =
		\\deepest: ${Str.inspect([round_trips(down(128, 0.5)), round_trips(down(128, big_fraction)), round_trips(down(128, 100.0 / 3.0)), WorkerCodec.try_encode(down(129, big_fraction)) == Err(TooDeep)])}
		\\wide: ${Str.inspect([round_trips(across(128, big_u128)), WorkerCodec.try_encode(across(129, big_u128)) == Err(TooDeep)])}
		\\filed: ${Str.inspect([filed_back == Ok(filed(126, file)), filed_at.files.len() == 1, WorkerCodec.encode_with_files("wire unit", filed(127, file)) == Err(TooDeep)])}
		\\paired: ${Str.inspect([paired_back == Ok(paired(127, file)), paired_at.files.len() == 127, WorkerCodec.encode_with_files("wire unit", paired(128, file)) == Err(TooDeep)])}
	expected =
		\\deepest: [True, True, True, True]
		\\wide: [True, True]
		\\filed: [True, True, True]
		\\paired: [True, True, True]
	actual == expected
}

## The reader's backstop is physical: 129 levels of `Nested` are 258 maps
## and arrays and are read, 130 are 260 and are refused before any typed
## callback runs.
## So the reader accepts more than the writer writes, never less.
expect {
	children = [0xa1, 0x68].concat("children".to_utf8())
	bytes = |levels| {
		var $out = []
		for _ in (1.U64).until(levels) {
			$out = $out.concat(children).append(0x81)
		}
		$out.concat(children).append(0x80)
	}
	at : Try(Nested, WorkerCodec.Error)
	at = WorkerCodec.decode(bytes(129))
	past : Try(Nested, WorkerCodec.Error)
	past = WorkerCodec.decode(bytes(130))
	at == Ok(nest(129)) and past.is_err()
}

## Files travel beside the payload as handles: decoding with the handle list
## gives each file the handle at its place with the name, type and range the
## payload carries, and a payload naming a file that is not there, or a
## range outside its file, is refused.
expect {
	file = |token, parts| match Core.placed_file(Core.held_file(Box.box(token)), parts) {
		Ok(f) => f
		Err(_) => crash "a range outside its file"
	}
	a = file(1, { name: "a.bin", mime: "", size: 10, start: 4, len: 3 })
	b = file(2, { name: "b.txt", mime: "text/plain", size: 0, start: 0, len: 0 })
	sent = held({ note: "x", docs: [a, b] })
	back : Try({ note : Str, docs : List(Engine.File) }, WorkerCodec.Error)
	back = WorkerCodec.decode_with_held(sent.bytes, sent.files)
	missing : Try({ note : Str, docs : List(Engine.File) }, WorkerCodec.Error)
	missing = WorkerCodec.decode_with_held(sent.bytes, sent.files.take_first(1))
	outside = Core.placed_file(Core.held_file(Box.box(3)), { name: "c", mime: "", size: 4, start: 2, len: 3 })
	back == Ok({ note: "x", docs: [a, b] }) and missing.is_err() and outside.is_err()
}

## Each file a payload holds is one entry of the list beside its bytes, in
## a record with an absent optional field too: the encoder that came before
## CBOR listed such a record's files twice, so 9 of them made 18 entries and
## an answer of 9 to 16 was refused at the 16-file bound. Now 9 and 16 files
## make 9 and 16 entries, an answer of 16 is within the bound (17 is past
## it, which the worker layer answers as `TooManyFiles`), and two
## occurrences of one file are still two entries.
expect {
	file = |token| match Core.placed_file(Core.held_file(Box.box(token)), { name: "f${token.to_str()}", mime: "", size: 8, start: 0, len: 8 }) {
		Ok(f) => f
		Err(_) => crash "a range outside its file"
	}
	docs = |count| {
		var $docs = []
		for token in (1.U64).until(count + 1) {
			$docs = $docs.append({ doc: file(token), note: Err(Missing) })
		}
		$docs
	}
	listed = |count| {
		value : List({ doc : Engine.File, note : Try(Str, [Missing]) })
		value = docs(count)
		sent = held(value)
		back : Try(List({ doc : Engine.File, note : Try(Str, [Missing]) }), WorkerCodec.Error)
		back = WorkerCodec.decode_with_held(sent.bytes, sent.files)
		if (back == Ok(value)) sent.files else []
	}
	twice = held([file(1), file(1)])
	answered = Core.task_answer("wire unit", [], listed(16))
	listed(9).len() == 9 and listed(16).len() == 16 and listed(17).len() == 17 and twice.files.len() == 2 and answered.len() == 4 + 8 * 16
}

## A typed numeric dictionary must refuse physical zero keys that would otherwise overwrite one entry (https://github.com/roc-lang/roc/issues/13057).
expect {
	value : Try(Dict(F64, Str), WorkerCodec.Error)
	value = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0x61, 0x61, 0xf9, 0x80, 0, 0x61, 0x62])
	value.is_err()
}

## Both zero signs are refused as `F32` keys too, and a zero of one sign
## alone is accepted as either width.
expect {
	both : Try(Dict(F32, Str), WorkerCodec.Error)
	both = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0x61, 0x61, 0xf9, 0x80, 0, 0x61, 0x62])
	negative : Try(Dict(F32, Str), WorkerCodec.Error)
	negative = WorkerCodec.decode([0xa1, 0xf9, 0x80, 0, 0x61, 0x62])
	positive : Try(Dict(F64, Str), WorkerCodec.Error)
	positive = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0x61, 0x61, 0xf9, 0x3c, 0, 0x61, 0x62])
	actual =
		\\both: ${Str.inspect(both.is_ok())}
		\\negative: ${Str.inspect(negative.map_ok(|d| d.len()))}
		\\positive: ${Str.inspect(positive.map_ok(|d| d.len()))}
	expected =
		\\both: False
		\\negative: Ok(1)
		\\positive: Ok(2)
	actual == expected
}

## Each dictionary keeps its own zero signs: the two signs in sibling
## dictionaries, or one in a dictionary nested in another's value, are
## accepted and keep their bytes, while the two signs as keys of the outer
## dictionary, around a nested one, are refused.
expect {
	positive = 0.0.F64
	negative = F64.from_bits(0x8000000000000000)
	siblings = [Dict.from_list([(positive, "a")]), Dict.from_list([(negative, "b")])]
	nested = Dict.from_list([(positive, Dict.from_list([(negative, "x")])), (1.0, Dict.empty())])
	around : Try(Dict(F64, Dict(F64, Str)), WorkerCodec.Error)
	around = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0xa1, 0xf9, 0x3c, 0, 0x61, 0x78, 0xf9, 0x80, 0, 0xa0])
	tagged : Try(Dict(F64, [Pair(Dict(F64, Str))]), WorkerCodec.Error)
	tagged = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0xa1, 0x64, 0x50, 0x61, 0x69, 0x72, 0xa0, 0xf9, 0x80, 0, 0xa1, 0x64, 0x50, 0x61, 0x69, 0x72, 0xa0])
	actual =
		\\siblings: ${Str.inspect(same_bytes(siblings))}
		\\nested: ${Str.inspect(same_bytes(nested))}
		\\around: ${Str.inspect(around.is_ok())}
		\\tagged: ${Str.inspect(tagged.is_ok())}
	expected =
		\\siblings: True
		\\nested: True
		\\around: False
		\\tagged: False
	actual == expected
}

## NaN is not equal to itself, so a dictionary can hold several NaN keys,
## but every NaN is written as the one canonical NaN. One NaN key crosses
## and is read back as a NaN key; a second NaN key in the same dictionary
## is refused as `NanKeys` at encode, for `F32` keys as for `F64`, instead
## of writing two equal map keys. Each dictionary's NaN keys are its own:
## one in each of two siblings, or one in a dictionary nested in another's
## value, cross, while two around a nested one are refused. A set of two
## NaNs is a list, not a map, and crosses with both.
expect {
	two_f64 : Dict(F64, Str)
	two_f64 = Dict.empty().insert(F64.nan, "a").insert(F64.nan, "b")
	two_f32 : Dict(F32, Str)
	two_f32 = Dict.empty().insert(F32.nan, "a").insert(F32.nan, "b")
	one : Dict(F64, Str)
	one = Dict.empty().insert(F64.nan, "a").insert(1.0, "b")
	one_back : Try(Dict(F64, Str), WorkerCodec.Error)
	one_back = WorkerCodec.decode(WorkerCodec.encode(one))
	siblings = [Dict.empty().insert(F64.nan, "a"), Dict.empty().insert(F64.nan, "b")]
	siblings_back : Try(List(Dict(F64, Str)), WorkerCodec.Error)
	siblings_back = WorkerCodec.decode(WorkerCodec.encode(siblings))
	nested : Dict(F64, Dict(F64, Str))
	nested = Dict.empty().insert(F64.nan, Dict.empty().insert(F64.nan, "x"))
	nested_back : Try(Dict(F64, Dict(F64, Str)), WorkerCodec.Error)
	nested_back = WorkerCodec.decode(WorkerCodec.encode(nested))
	around : Dict(F64, Dict(F64, Str))
	around = Dict.empty().insert(F64.nan, Dict.empty().insert(F64.nan, "x")).insert(F64.nan, Dict.empty())
	set : Set(F64)
	set = Set.empty().insert(F64.nan).insert(F64.nan)
	set_back : Try(Set(F64), WorkerCodec.Error)
	set_back = WorkerCodec.decode(WorkerCodec.encode(set))
	nan_keys = |d| d.to_list().keep_if(|(k, _)| k.is_nan()).len()
	actual =
		\\two: ${Str.inspect((two_f64.len(), WorkerCodec.try_encode(two_f64) == Err(NanKeys), WorkerCodec.encode_with_files("wire unit", two_f64) == Err(NanKeys)))}
		\\two_f32: ${Str.inspect((two_f32.len(), WorkerCodec.try_encode(two_f32) == Err(NanKeys)))}
		\\one: ${Str.inspect(one_back.map_ok(|d| (d.len(), nan_keys(d), d.get(1.0))))}
		\\siblings: ${Str.inspect(siblings_back.map_ok(|ds| ds.map(nan_keys)))}
		\\nested: ${Str.inspect(nested_back.map_ok(|d| (nan_keys(d), d.to_list().map(|(_, inner)| nan_keys(inner)))))}
		\\around: ${Str.inspect((around.len(), WorkerCodec.try_encode(around) == Err(NanKeys)))}
		\\set: ${Str.inspect((set.len(), set_back.map_ok(|s| s.len())))}
	expected =
		\\two: (2, True, True)
		\\two_f32: (2, True)
		\\one: Ok((2, 1, Ok("b")))
		\\siblings: Ok([1, 1])
		\\nested: Ok((1, [1]))
		\\around: (2, True)
		\\set: (2, Ok(2))
	actual == expected
}
