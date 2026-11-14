import WorkerCodec
import Core
import Engine

## The derived payload types an app uses in worker task signatures.
## A task's types derive their codecs over [Format]; the platform carries the
## resulting CBOR item and the files it owns between instances of one module.
Wire := [].{

	## The opaque format supplied to a derived or handwritten codec.
	Format : WorkerCodec.Format

	## One item's opaque writer state, passed through codec callbacks.
	Enc : WorkerCodec.Enc

	## A container accumulator, distinct from the writer of each of its items.
	Items : WorkerCodec.Items

	## The accumulator of an open record's fields.
	Fields : WorkerCodec.Fields

	## The accumulator of an open dictionary's entries.
	Entries : WorkerCodec.Entries

	## One checked payload's opaque cursor, passed through parser callbacks.
	State : WorkerCodec.State

	## A malformed item's position or a missing required field name.
	Error : WorkerCodec.Error

	## Types that can cross between instances, with derived or handwritten
	## codecs over this format. Functions and absent codecs are compile errors.
	# Derivation through format aliases fails on the pinned compiler. Only
	# this constraint names backing types; public aliases remain app-nameable.
	# https://github.com/roc-lang/roc/issues/13022
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
	decoded : Try(a, Wire.Error)
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
	decoded : Try((F64, F64, F64, F64, F64, F32, F32, F32), Wire.Error)
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
	decoded : Try(List(U8), Wire.Error)
	decoded = WorkerCodec.decode(WorkerCodec.encode(bytes))
	round_trips(bytes) and WorkerCodec.encode(bytes) == WorkerCodec.encode([0.U8, 1, 255]) and decoded == Ok([0, 1, 255])
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
		decoded : Try(Sample, Wire.Error)
		decoded = WorkerCodec.decode(bytes)
		decoded.is_ok()
	}
	prefixes_refused(WorkerCodec.encode(value), accepted)
}

## Input left after the value is refused.
expect {
	decoded : Try({ a : U8 }, Wire.Error)
	decoded = WorkerCodec.decode(WorkerCodec.encode({ a: 1.U8 }).append(0))
	decoded == Err(InvalidCbor(4))
}

## A tag name the type does not have is refused.
expect {
	decoded : Try([Small, Large(U8)], Wire.Error)
	decoded = WorkerCodec.decode([161, 100, 72, 117, 103, 101, 1])
	decoded.is_err()
}

## A count larger than the rest of the input is refused before anything is
## allocated for it, however large it claims to be.
expect {
	text : Try(Str, Wire.Error)
	text = WorkerCodec.decode([0x65, 97])
	huge : Try(List(U64), Wire.Error)
	huge = WorkerCodec.decode([0x9b, 255, 255, 255, 255, 255, 255, 255, 255])
	units : Try(List({}), Wire.Error)
	units = WorkerCodec.decode([0x83, 0xa0, 0xa0])
	text.is_err() and huge.is_err() and units.is_err()
}

## Invalid UTF-8 in a string is refused.
expect {
	decoded : Try(Str, Wire.Error)
	decoded = WorkerCodec.decode([0x62, 195, 40])
	decoded.is_err()
}

## Invalid scalar forms, padded CBOR heads and impossible container counts are refused.
expect {
	flag : Try(Bool, Wire.Error)
	flag = WorkerCodec.decode([2])
	padded : Try(Str, Wire.Error)
	padded = WorkerCodec.decode([0x78, 0x00])
	overflow : Try(List(U8), Wire.Error)
	overflow = WorkerCodec.decode([255, 255, 255, 255, 255, 255, 255, 255, 255, 2])
	flag.is_err() and padded.is_err() and overflow.is_err()
}

## A record count above the type's field count, a named field out of order,
## a named field the type lacks, and a missing required field are refused.
expect {
	wide : Try({ a : U8, b : U8 }, Wire.Error)
	wide = WorkerCodec.decode([0xa3, 0x61, 97, 1, 0x61, 98, 2, 0x61, 99, 3])
	unordered : Try(Profile, Wire.Error)
	unordered = WorkerCodec.decode([0xa2, 0x64, 110, 97, 109, 101, 0x61, 110, 0x63, 97, 103, 101, 9])
	unknown : Try(Profile, Wire.Error)
	unknown = WorkerCodec.decode([0xa1, 0x63, 122, 122, 122, 9])
	missing : Try(Profile, Wire.Error)
	missing = WorkerCodec.decode([0xa1, 0x63, 97, 103, 101, 9])
	wide.is_err() and unordered.is_err() and unknown.is_err() and missing == Err(MissingRequiredField("name"))
}

## Dictionary keys out of order, or repeated, are refused.
expect {
	unordered : Try(Dict(Str, U8), Wire.Error)
	unordered = WorkerCodec.decode([0xa2, 0x61, 98, 2, 0x61, 97, 1])
	repeated : Try(Dict(Str, U8), Wire.Error)
	repeated = WorkerCodec.decode([0xa2, 0x61, 97, 1, 0x61, 97, 2])
	unordered.is_err() and repeated.is_err()
}

## The physical CBOR bound is exact at511/512/513, including the additional map around a typed value.
expect {
	at511 = { inner: left_spine(255) }
	at512 = left_spine(256)
	at513 = { inner: left_spine(256) }
	decoded511 : Try({ inner : Tree }, Wire.Error)
	decoded511 = WorkerCodec.decode(WorkerCodec.encode(at511))
	decoded512 : Try(Tree, Wire.Error)
	decoded512 = WorkerCodec.decode(WorkerCodec.encode(at512))
	decoded513 : Try({ inner : Tree }, Wire.Error)
	decoded513 = WorkerCodec.decode(WorkerCodec.encode(at513))
	decoded511 == Ok(at511) and decoded512 == Ok(at512) and decoded513.is_err() and WorkerCodec.try_encode(at511).is_ok() and WorkerCodec.try_encode(at512).is_ok() and WorkerCodec.try_encode(at513) == Err(TooDeep)
}

## Reader and writer agree across recursive records/lists and dictionary wrappers, without assuming the former logical Wire framing depth.
expect {
	nest = |depth| {
		var $value = Nested.{ children: [] }
		for _ in (1.U64).until(depth) {
			$value = Nested.{ children: [$value] }
		}
		$value
	}
	agrees = |value| {
		back : Try(Nested, Wire.Error)
		back = WorkerCodec.decode(WorkerCodec.encode(value))
		back.is_ok() == WorkerCodec.try_encode(value).is_ok()
	}
	wrapped = |depth| {
		value = Dict.from_list([("k", left_spine(depth))])
		back : Try(Dict(Str, Tree), Wire.Error)
		back = WorkerCodec.decode(WorkerCodec.encode(value))
		back.is_ok() == WorkerCodec.try_encode(value).is_ok()
	}
	[255.U64, 256, 257].all(|d| agrees(nest(d))) and WorkerCodec.try_encode(nest(256)).is_ok() and WorkerCodec.try_encode(nest(257)).is_err() and [254.U64, 255, 256].all(wrapped)
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
	sent = WorkerCodec.encode_with_files("wire unit", { note: "x", docs: [a, b] })
	back : Try({ note : Str, docs : List(Engine.File) }, Wire.Error)
	back = WorkerCodec.decode_with_held(sent.bytes, sent.files)
	missing : Try({ note : Str, docs : List(Engine.File) }, Wire.Error)
	missing = WorkerCodec.decode_with_held(sent.bytes, sent.files.take_first(1))
	outside = Core.placed_file(Core.held_file(Box.box(3)), { name: "c", mime: "", size: 4, start: 2, len: 3 })
	back == Ok({ note: "x", docs: [a, b] }) and missing.is_err() and outside.is_err()
}

## A typed numeric dictionary must refuse physical zero keys that would otherwise overwrite one entry (https://github.com/roc-lang/roc/issues/13057).
expect {
	value : Try(Dict(F64, Str), Wire.Error)
	value = WorkerCodec.decode([0xa2, 0xf9, 0, 0, 0x61, 0x61, 0xf9, 0x80, 0, 0x61, 0x62])
	value.is_err()
}

## The same typed nonloss requirement holds inside a derived record key (https://github.com/roc-lang/roc/issues/13057).
expect {
	value : Try(Dict({ f : F64 }, Str), Wire.Error)
	value = WorkerCodec.decode([0xa2, 0xa1, 0x61, 0x66, 0xf9, 0, 0, 0x61, 0x61, 0xa1, 0x61, 0x66, 0xf9, 0x80, 0, 0x61, 0x62])
	value.is_err()
}
