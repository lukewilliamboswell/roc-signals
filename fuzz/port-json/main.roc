app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.PortJson
import pf.Wire

## The port message format is total over arbitrary text, and stable once a
## value has been read.
##
## The other end of a port is JavaScript the platform did not write, so the
## decoder meets text no Roc encoder produced: any whitespace, key order or
## escape JSON allows, and anything else at all. Every input is read as the
## JSON text of a message carrying two fixed blobs, and decoded as `Rich`,
## which reaches every shape derivation covers, and as several small types
## that are valid for far more inputs. For every type, decoding never
## crashes and its peak memory stays within a constant factor of the input's
## length. A decoded value is then the fixed point the format promises: its
## message decodes to a value whose message is the same text and blobs, and,
## for the types whose equality is structural, to an equal value. JSON is
## not canonical, so an accepted input need not be the encoding of its
## value; what must hold is that Roc's own encoding is.
Shape : [Dot, Circle(F64), Rect({ w : U32, h : U32 }), Path(List((I16, I16)))]

Kind : [A, B(U16, Str), C({ x : I8 })]

Profile : { name : Str, nick : Try(Str, [Missing]), age : Try(U8, [Missing]) }

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

## The blobs every input's markers may name.
blobs : List(List(U8))
blobs = [[0, 255, 7], []]

## Peak decoder memory may grow by this much per input byte: the largest
## in-memory size a type gives one byte of JSON, doubled for list growth.
bytes_per_input_byte : U64
bytes_per_input_byte = 128

## Peak decoder memory independent of the input's length: the deepest
## recursion and allocator rounding.
fixed_bytes : U64
fixed_bytes = 262144

message : List(U8) -> PortJson.Message
message = |input| { json: Str.from_utf8_lossy(input), blobs, files: [] }

decode_rich : List(U8) -> Try(Rich, PortJson.Error)
decode_rich = |input| PortJson.decode(message(input))

decode_canon : List(U8) -> Try(Canon, PortJson.Error)
decode_canon = |input| PortJson.decode(message(input))

decode_strs : List(U8) -> Try(List(Str), PortJson.Error)
decode_strs = |input| PortJson.decode(message(input))

decode_words : List(U8) -> Try(Dict(Str, U8), PortJson.Error)
decode_words = |input| PortJson.decode(message(input))

decode_profiles : List(U8) -> Try(List(Profile), PortJson.Error)
decode_profiles = |input| PortJson.decode(message(input))

decode_kinds : List(U8) -> Try(List(Kind), PortJson.Error)
decode_kinds = |input| PortJson.decode(message(input))

decode_node : List(U8) -> Try(Node, PortJson.Error)
decode_node = |input| PortJson.decode(message(input))

decode_numbers : List(U8) -> Try((U64, I128, Dec, List(I32)), PortJson.Error)
decode_numbers = |input| PortJson.decode(message(input))

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

## Decode `input` as `a`, within the memory bound. A value it decodes to must
## come back from its own message equal, with the same message again.
structural! : Str, List(U8), (List(U8) -> Try(a, PortJson.Error)) => {} where [a.PortJson.Sendable, a.is_eq : a, a -> Bool]
structural! = |label, input, decode| {
	measured = Fuzz.measure!(label, || decode(input))
	check_bound!(label, input, measured.stats)
	match measured.value {
		Ok(value) => {
			sent = PortJson.encode(value)
			again : Try(a, PortJson.Error)
			again = PortJson.decode(sent)
			match again {
				Ok(back) if back == value and PortJson.encode(back) == sent => {}
				Ok(_) => crash "a decoded ${label} does not come back from its own message unchanged"
				Err(problem) => crash "the message of a decoded ${label} is refused: ${PortJson.describe(problem)}"
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
			# Floats keep NaN and signed zero, so `Rich` is compared by its
			# message, which must be a fixed point.
			sent = PortJson.encode(value)
			again : Try(Rich, PortJson.Error)
			again = PortJson.decode(sent)
			match again {
				Ok(back) if PortJson.encode(back) == sent => {}
				Ok(_) => crash "a re-encoded Rich decodes to a value with a different message"
				Err(problem) => crash "a re-encoded Rich is refused: ${PortJson.describe(problem)}"
			}
		}
		Err(_) => {}
	}
	structural!("Canon", input, decode_canon)
	structural!("List(Str)", input, decode_strs)
	structural!("Dict(Str, U8)", input, decode_words)
	structural!("List(Profile)", input, decode_profiles)
	structural!("List(Kind)", input, decode_kinds)
	structural!("Node", input, decode_node)
	structural!("numbers", input, decode_numbers)
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
	index: Dict.from_list([("k", [1, 2]), ("$j", [])]),
	seen: Set.from_list([3, -4]),
	who: { name: "n\"\u(1F98A)", nick: Err(Missing), age: Ok(2) },
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
	who: [{ name: "n", nick: Err(Missing), age: Err(Missing) }, { name: "m", nick: Ok("k"), age: Ok(3) }],
	blob: Wire.Bytes.from_list([1, 2, 3]),
	tree: sample_tree,
	note: Ok("note"),
}

## How JavaScript writes the same kind of message: spaced, keys in another
## order, numbers where Roc writes strings, escapes Roc never writes, nulls
## for absent fields.
from_javascript : Str
from_javascript = " [ { \"who\" : { \"nick\" : null , \"name\" : \"\\u00e9\\ud83e\\udd8a\\/\" } } ,\n   \"1e3\", 1.5e-3, 9007199254740991, { \"$bytes\" : 1 }, { \"Branch\": { \"kids\": [ { \"Leaf\": \"x\" } ], \"label\": 3 } } ]"

target = Fuzz.target_with!({
	examples: [
		Fuzz.example({ name: "rich", revision: "1", make: || Str.to_utf8(PortJson.encode(sample_rich).json) }),
		Fuzz.example({ name: "canon", revision: "1", make: || Str.to_utf8(PortJson.encode(sample_canon).json) }),
		Fuzz.example({ name: "javascript", revision: "1", make: || Str.to_utf8(from_javascript) }),
		Fuzz.example({ name: "rich-truncated", revision: "1", make: || Str.to_utf8(PortJson.encode(sample_rich).json).drop_last(1) }),
		Fuzz.example({ name: "canon-trailing", revision: "1", make: || Str.to_utf8(PortJson.encode(sample_canon).json).append(44) }),
		Fuzz.example({ name: "deep", revision: "1", make: || List.repeat(91, 700) }),
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
	],
	name: "port-json",
	generator: Fuzz.raw_bytes,
	test!,
	show: |input| Str.inspect(Str.from_utf8_lossy(input)),
})
