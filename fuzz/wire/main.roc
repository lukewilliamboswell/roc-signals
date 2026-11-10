app [target] { pf: platform "../../platform/fuzz.roc" }

import pf.Fuzz
import pf.Wire

## The worker wire format is total and canonical over arbitrary bytes.
##
## Every input is decoded as `Rich`, which reaches every shape derivation
## covers, and as `Canon` and several small types, which avoid the two shapes
## whose encoding is not a function of equality (floats keep their bit
## patterns; sets keep their iteration order and drop duplicates). For every
## type, decoding never crashes and its peak memory stays within a constant
## factor of the input's length. A decoded `Rich` re-encodes to a payload that
## decodes again to the same encoding. For the canonical types the decoder
## must also be strict: an input it accepts is exactly the encoding of the
## value it decodes to, so a lax rule (a non-minimal count, unsorted keys, a
## field out of order) is caught as soon as mutation reaches it.
Shape : [Dot, Circle(F64), Rect({ w : U32, h : U32 }), Path(List((I16, I16)))]

Kind : [A, B(U16, Str), C({ x : I8 })]

Profile : { name : Str, nick ?: Str, age ?: U8 }

## A recursive type, which recurses through a record field and a list.
Node := [Leaf(Str), Branch({ label : U8, kids : List(Node) })].{
	parser_for : _
	encoder_for : _
	is_eq : _
}

Rich : {
	id : U64,
	small : (I8, U16, I32, I128, U128),
	ratio : F32,
	score : F64,
	money : Dec,
	ok : Bool,
	shapes : List(Shape),
	index : Dict(Str, List(U16)),
	seen : Set(I64),
	who : Profile,
	blob : Wire.Bytes,
	tree : Node,
	note : Try(Str, [Missing]),
}

Canon : {
	id : U64,
	small : (I8, U16, I32, I128, U128),
	money : Dec,
	ok : Bool,
	kinds : List(Kind),
	index : Dict(Str, U8),
	keyed : Dict(U32, List(Bool)),
	colors : Dict([Red, Green, Blue], I16),
	who : List(Profile),
	blob : Wire.Bytes,
	tree : Node,
	note : Try(Str, [Missing]),
}

## Peak decoder memory may grow by this much per input byte: the largest
## in-memory size either type gives one encoded byte, doubled for list growth.
bytes_per_input_byte : U64
bytes_per_input_byte = 64

## Peak decoder memory independent of the input's length: the frame stack and
## cached field names at the deepest nesting, and allocator rounding.
fixed_bytes : U64
fixed_bytes = 65536

decode_rich : List(U8) -> Try(Rich, Wire.Error)
decode_rich = |bytes| Wire.decode(bytes)

decode_canon : List(U8) -> Try(Canon, Wire.Error)
decode_canon = |bytes| Wire.decode(bytes)

decode_strs : List(U8) -> Try(List(Str), Wire.Error)
decode_strs = |bytes| Wire.decode(bytes)

decode_words : List(U8) -> Try(Dict(Str, U8), Wire.Error)
decode_words = |bytes| Wire.decode(bytes)

decode_profiles : List(U8) -> Try(List(Profile), Wire.Error)
decode_profiles = |bytes| Wire.decode(bytes)

decode_kinds : List(U8) -> Try(List(Kind), Wire.Error)
decode_kinds = |bytes| Wire.decode(bytes)

decode_node : List(U8) -> Try(Node, Wire.Error)
decode_node = |bytes| Wire.decode(bytes)

decode_colors : List(U8) -> Try(Dict([Red, Green, Blue], List(I16)), Wire.Error)
decode_colors = |bytes| Wire.decode(bytes)

## Crash unless a decode's peak memory is within the bound for `input`.
check_bound! : Str, List(U8), Fuzz.Stats => {}
check_bound! = |label, input, stats| {
	grown = if (stats.peak_live_bytes > stats.entry_live_bytes) stats.peak_live_bytes - stats.entry_live_bytes else 0
	bound = bytes_per_input_byte * input.len() + fixed_bytes
	if grown > bound {
		crash "decoding ${input.len().to_str()} bytes as ${label} peaked ${grown.to_str()} bytes above its entry, over the bound of ${bound.to_str()}"
	}
	{}
}

## Decode `input` as the canonical type `a`, within the memory bound. An
## accepted input must be exactly the encoding of the value it decodes to.
canonical! : Str, List(U8), (List(U8) -> Try(a, Wire.Error)) => {} where [a.Wire.Sendable]
canonical! = |label, input, decode| {
	measured = Fuzz.measure!(label, || decode(input))
	check_bound!(label, input, measured.stats)
	match measured.value {
		Ok(value) => {
			if Wire.encode(value) != input {
				crash "an accepted ${label} input is not the encoding of the value it decodes to"
			}
		}
		Err(_) => {}
	}
}

test! : List(U8) => Fuzz.Outcome
test! = |input| {
	rich = Fuzz.measure!("Rich", || decode_rich(input))
	check_bound!("Rich", input, rich.stats)
	match rich.value {
		Ok(value) => {
			payload = Wire.encode(value)
			match decode_rich(payload) {
				Ok(again) if Wire.encode(again) == payload => {}
				Ok(_) => crash "a re-encoded Rich decodes to a value with a different encoding"
				Err(problem) => crash "a re-encoded Rich is refused: ${Str.inspect(problem)}"
			}
		}
		Err(_) => {}
	}
	# Small types are valid for far more inputs than the large ones, so the
	# strictness of each rule is reached by mutation, not only by the seeds.
	canonical!("Canon", input, decode_canon)
	canonical!("List(Str)", input, decode_strs)
	canonical!("Dict(Str, U8)", input, decode_words)
	canonical!("List(Profile)", input, decode_profiles)
	canonical!("List(Kind)", input, decode_kinds)
	canonical!("Node", input, decode_node)
	canonical!("Dict(color, List(I16))", input, decode_colors)
	Fuzz.keep
}

sample_tree : Node
sample_tree = Node.Branch({ label: 1, kids: [Node.Leaf("a"), Node.Branch({ label: 2, kids: [] })] })

sample_rich : Rich
sample_rich = {
	id: 7,
	small: (-1, 2, -3, I128.lowest, U128.highest),
	ratio: 0.5,
	score: -2.25,
	money: 12.5,
	ok: Bool.True,
	shapes: [Dot, Circle(1.0), Rect({ w: 3, h: 4 }), Path([(1, -1)])],
	index: Dict.from_list([("k", [1, 2]), ("j", [])]),
	seen: Set.from_list([3, -4]),
	who: { name: "n", age: 2 },
	blob: Wire.Bytes.from_list([0, 255]),
	tree: sample_tree,
	note: Err(Missing),
}

sample_canon : Canon
sample_canon = {
	id: 7,
	small: (-1, 2, -3, I128.lowest, U128.highest),
	money: -0.5,
	ok: Bool.False,
	kinds: [A, B(9, "b"), C({ x: -8 })],
	index: Dict.from_list([("k", 1), ("j", 2)]),
	keyed: Dict.from_list([(5, [Bool.True]), (1, [])]),
	colors: Dict.from_list([(Red, 1), (Blue, -1)]),
	who: [{ name: "n" }, { name: "m", nick: "k", age: 3 }],
	blob: Wire.Bytes.from_list([1, 2, 3]),
	tree: sample_tree,
	note: Ok("note"),
}

target = Fuzz.target_with!({
	examples: [
		Fuzz.example({ name: "rich", revision: "1", make: || Wire.encode(sample_rich) }),
		Fuzz.example({ name: "canon", revision: "1", make: || Wire.encode(sample_canon) }),
		Fuzz.example({ name: "rich-truncated", revision: "1", make: || Wire.encode(sample_rich).drop_last(1) }),
		Fuzz.example({ name: "canon-trailing", revision: "1", make: || Wire.encode(sample_canon).append(0) }),
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
	],
	name: "wire",
	generator: Fuzz.raw_bytes,
	test!,
	show: |input| Str.inspect(input),
})
