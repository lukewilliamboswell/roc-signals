app [target] {
	cbor: "https://github.com/lukewilliamboswell/roc-cbor/releases/download/0.6.3/J3xX4n61WoMZKK3tdWTnZBdKaVbi8SvXvmtC5i3qDAER.tar.zst",
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import Saved
import cbor.Cbor
import pf.Core
import pf.Engine
import pf.WorkerCodec
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
##
## Every input is also decoded as `Filed`, a value holding files, against a
## table of two handles: decoding stays within the bound, every decoded file
## is a table entry's handle with the name, type and range its payload
## gives, a range that lies within its size, and a decoded value re-encodes
## to a payload and file list that decode back to it.
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

## A value holding files, as a worker task's input does.
Filed : { title : Str, docs : List(Engine.File), extra : Try(Engine.File, [Missing]) }

## The handles an input's `Filed` decoding places files at, as a worker's
## host mints them for a job.
table_of : {} -> List(Engine.File)
table_of = |_| [Core.held_file(Box.box(1)), Core.held_file(Box.box(2))]

decode_filed : List(U8), List(Engine.File) -> Try(Filed, WorkerCodec.Error)
decode_filed = |input, table| WorkerCodec.decode_with_held(input, table)

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

decode_rich : List(U8) -> Try(Rich, WorkerCodec.Error)
decode_rich = |bytes| WorkerCodec.decode(bytes)

decode_canon : List(U8) -> Try(Canon, WorkerCodec.Error)
decode_canon = |bytes| WorkerCodec.decode(bytes)

decode_strs : List(U8) -> Try(List(Str), WorkerCodec.Error)
decode_strs = |bytes| WorkerCodec.decode(bytes)

decode_words : List(U8) -> Try(Dict(Str, U8), WorkerCodec.Error)
decode_words = |bytes| WorkerCodec.decode(bytes)

decode_profiles : List(U8) -> Try(List(Profile), WorkerCodec.Error)
decode_profiles = |bytes| WorkerCodec.decode(bytes)

decode_kinds : List(U8) -> Try(List(Kind), WorkerCodec.Error)
decode_kinds = |bytes| WorkerCodec.decode(bytes)

decode_node : List(U8) -> Try(Node, WorkerCodec.Error)
decode_node = |bytes| WorkerCodec.decode(bytes)

decode_colors : List(U8) -> Try(Dict([Red, Green, Blue], List(I16)), WorkerCodec.Error)
decode_colors = |bytes| WorkerCodec.decode(bytes)

## Preferred scalar forms still must not let numeric float-key aliases overwrite entries.
decode_float_keys : List(U8) -> Try(Dict(F64, Str), WorkerCodec.Error)
decode_float_keys = |bytes| WorkerCodec.decode(bytes)

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
canonical! : Str, List(U8), (List(U8) -> Try(a, WorkerCodec.Error)) => {} where [a.Wire.Sendable]
canonical! = |label, input, decode| {
	measured = Fuzz.measure!(label, || decode(input))
	check_bound!(label, input, measured.stats)
	match measured.value {
		# The reader's backstop counts CBOR levels and admits values nested
		# past the writer's bound on the app's own levels; such a value is
		# refused as `TooDeep`, never written as other bytes. The reader
		# refuses two equal keys in one map, and every NaN is read from the
		# one canonical form, so an accepted input never holds two NaN keys
		# in one dictionary.
		Ok(value) => match WorkerCodec.try_encode(value) {
			Ok(bytes) if bytes != input => crash "an accepted ${label} input is not the encoding of the value it decodes to"
			Ok(_) => {}
			Err(TooDeep) => {}
			Err(NanKeys) => crash "an accepted ${label} input holds two NaN keys in one dictionary"
		}
		Err(_) => {}
	}
}

test! : List(U8) => Fuzz.Outcome
test! = |input| {
	rich = Fuzz.measure!("Rich", || decode_rich(input))
	check_bound!("Rich", input, rich.stats)
	match rich.value {
		Ok(value) => match WorkerCodec.try_encode(value) {
			Ok(payload) => {
				well_formed : Try(Cbor.Value, _)
				well_formed = Cbor.parse(payload)
				if well_formed.is_err() {
					crash "an encoded Rich is not a CBOR item"
				}
				match decode_rich(payload) {
					Ok(again) if WorkerCodec.try_encode(again) == Ok(payload) => {}
					Ok(_) => crash "a re-encoded Rich decodes to a value with a different encoding"
					Err(problem) => crash "a re-encoded Rich is refused: ${Str.inspect(problem)}"
				}
			}
			# Nested past the writer's bound, as the canonical rule allows.
			Err(TooDeep) => {}
			Err(NanKeys) => crash "a decoded Rich, whose dictionary keys are text, holds two NaN keys"
		}
		Err(_) => {}
	}
	table = table_of({})
	filed = Fuzz.measure!("Filed", || decode_filed(input, table))
	check_bound!("Filed", input, filed.stats)
	match filed.value {
		Ok(value) => {
			all = match value.extra {
				Ok(f) => value.docs.append(f)
				Err(_) => value.docs
			}
			if !all.all(|f| table.any(|t| Core.placed_file(t, Core.file_parts(f)) == Ok(f))) {
				crash "a decoded file is not a table entry's handle"
			}
			if !all.all(|f| within(Core.file_parts(f))) {
				crash "a decoded file's range lies outside its size"
			}
			again = match WorkerCodec.encode_with_files("wire fuzz", value) {
				Ok(encoded) => encoded
				Err(TooDeep) => crash "a decoded Filed, which cannot nest, is refused as too deep"
				Err(NanKeys) => crash "a decoded Filed, which has no dictionary, holds two NaN keys"
			}
			well_formed : Try(Cbor.Value, _)
			well_formed = Cbor.parse(again.bytes)
			if well_formed.is_err() {
				crash "an encoded Filed is not a CBOR item"
			}
			match decode_filed(again.bytes, again.files) {
				Ok(back) if back == value => {}
				Ok(_) => crash "a re-encoded Filed decodes to a different value"
				Err(problem) => crash "a re-encoded Filed is refused: ${Str.inspect(problem)}"
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
	canonical!("Dict(F64, Str)", input, decode_float_keys)
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

## Whether a file's range lies within its size.
within : { name : Str, mime : Str, size : U64, start : U64, len : U64 } -> Bool
within = |{ size, start, len, .. }| start <= size and len <= size - start

## A `Filed` payload naming the table's first handle, an empty file.
sample_filed : List(U8)
sample_filed = {
	empty = match Core.placed_file(Core.held_file(Box.box(1)), { name: "e.txt", mime: "text/plain", size: 0, start: 0, len: 0 }) {
		Ok(f) => f
		Err(_) => crash "an empty range lies within an empty file"
	}
	match WorkerCodec.encode_with_files("wire fuzz", { title: "t", docs: [empty], extra: Err(Missing) }) {
		Ok(encoded) => encoded.bytes
		Err(TooDeep) => crash "a seed Filed, which cannot nest, is refused as too deep"
		Err(NanKeys) => crash "a seed Filed, which has no dictionary, holds two NaN keys"
	}
}

target = Fuzz.target_with!({
	examples: [
		Fuzz.saved({ name: "rich", revision: "2", bytes: Saved.rich }),
		Fuzz.saved({ name: "canon", revision: "2", bytes: Saved.canon }),
		Fuzz.saved({ name: "rich-truncated", revision: "2", bytes: Saved.rich.drop_last(1) }),
		Fuzz.saved({ name: "canon-trailing", revision: "2", bytes: Saved.canon.append(0) }),
		Fuzz.saved({ name: "empty", revision: "2", bytes: [] }),
		Fuzz.saved({ name: "filed", revision: "2", bytes: Saved.filed }),
		Fuzz.saved({ name: "canon-money-float", revision: "1", bytes: Saved.canon_money_float }),
		Fuzz.saved({ name: "float-key-zero-alias", revision: "1", bytes: [0xa2, 0xf9, 0, 0, 0x61, 0x61, 0xf9, 0x80, 0, 0x61, 0x62] }),
	],
	name: "wire",
	generator: Fuzz.raw_bytes,
	test!,
	show: |input| Str.inspect(input),
})

## A saved full Canon with floating money must be refused without weakening canonical equality.
expect decode_canon(Saved.canon_money_float).is_err()

## Independent complete Rich seed reaches every maintained derived shape.
expect decode_rich(Saved.rich) == Ok(sample_rich)

## Independent complete Canon seed is accepted and re-encodes byte-for-byte.
expect decode_canon(Saved.canon) == Ok(sample_canon) and WorkerCodec.encode(sample_canon) == Saved.canon

## The six-item file metadata array agrees with the owned-handle encoder.
expect sample_filed == Saved.filed
