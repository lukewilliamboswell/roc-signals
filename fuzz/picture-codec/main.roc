app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.PictureCodec
import Corpus

## A short independent valid forest generator. Missing seed bytes select the
## documented zero choice; arbitrary wire bytes are still checked separately.
model : List(U8) -> { parts : PictureCodec.Parts, depth : U32, nodes : U32 }
model = |bytes| {
	choice = (bytes.get(0) ?? 0).to_u32() % 7
	depth = if (choice < 5) choice else 0
	namespace = match (bytes.get(1) ?? 0) % 3 {
		0 => ""
		1 => "http://www.w3.org/2000/svg"
		_ => "urn:entry"
	}
	prefix = if ((bytes.get(2) ?? 0) % 2 == 0) "" else "p"
	local = match (bytes.get(3) ?? 0) % 4 {
		0 => "entry"
		1 => "h:div"
		2 => "a=b"
		_ => "xmlns"
	}
	var $containers = [{ owner: Mount, role: Children, children: if (depth == 0) [] else [0.U32] }]
	var $logical = []
	for ordinal in 0..<depth {
		$containers = $containers.append({ owner: Element(ordinal), role: Children, children: if (ordinal + 1 < depth) [ordinal + 1] else [] })
		$logical = $logical.append(ExistingElement(ordinal))
	}
	bindings = if (depth == 0) [] else [{ birth_offset: 1, role: Static, address: 1, slot: 0, kind: Unused, logical: 0 }]
	base : PictureCodec.Parts
	base = {
		root_name: { namespace, prefix, local },
		batch_bytes: if (depth == 0) 0 else 2,
		fingerprint: List.repeat(bytes.get(4) ?? 0, 32),
		expected: List.repeat(bytes.get(5) ?? 0, 32),
		physical_count: depth,
		containers: $containers,
		logical: $logical,
		runs: [],
		bindings,
		scaffolds: [],
	}
	if choice == 5 {
		return { parts: { ..base, logical: [TextPart({ run: 0, part: 0 })], runs: [{ container: 0, child_index: 0, physical: Omitted, parts: [{ logical: 0, utf16_units: 0 }] }] }, depth: 1, nodes: 1 }
	}
	if choice == 6 {
		return { parts: { ..base, physical_count: 1, containers: [{ owner: Mount, role: Children, children: [0] }, { owner: Element(0), role: Children, children: [] }], logical: [ExistingElement(0), ConstructedText({ container: 1, logical_child_index: 0, data: "" }), ConstructedComment({ container: 1, logical_child_index: 1, data: "original" })], scaffolds: [ControlText({ owner: 0, container: 1, physical: Omitted })] }, depth: 2, nodes: 3 }
	}
	{ parts: base, depth, nodes: depth }
}

## A malformed input is refused; an accepted wire item has one canonical
## encoding and retains every checked field, without a hash or DOM assertion.
check_wire : List(U8) -> {}
check_wire = |bytes| match PictureCodec.read(bytes, {}) {
	Err(_) => {}
	Ok(envelope) => {
		encoded = PictureCodec.encode(envelope)
		if encoded != bytes {
			crash "picture-codec: accepted noncanonical wire item"
		}
		decoded = PictureCodec.read(encoded, {}) ?? crash "picture-codec: canonical item refused on replay"
		if PictureCodec.parts(decoded) != PictureCodec.parts(envelope) {
			crash "picture-codec: decoded facts changed"
		}
	}
}

## Raw input probes framing; generated valid records probe complete encode/read
## preservation and exact byte/node/depth bounds on every invocation.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	check_wire(bytes)
	reference = model(bytes)
	envelope = PictureCodec.make(reference.parts, {}) ?? crash "picture-codec: independent valid forest refused"
	encoded = PictureCodec.encode(envelope)
	decoded = PictureCodec.read(encoded, {}) ?? crash "picture-codec: generated valid bytes refused"
	if PictureCodec.parts(decoded) != reference.parts {
		crash "picture-codec: generated forest changed"
	}
	exact = PictureCodec.make(reference.parts, { max_bytes: encoded.len(), max_nodes: reference.nodes, max_depth: reference.depth }) ?? crash "picture-codec: exact structural limits refused"
	if PictureCodec.encode(exact) != encoded {
		crash "picture-codec: limits changed canonical bytes"
	}
	if PictureCodec.make(reference.parts, { max_bytes: encoded.len() - 1 }).is_ok() {
		crash "picture-codec: writer grew beyond its byte cap"
	}
	if reference.depth > 0 {
		if PictureCodec.make(reference.parts, { max_nodes: reference.nodes - 1 }).is_ok() {
			crash "picture-codec: node bound ignored"
		}
		if PictureCodec.make(reference.parts, { max_depth: reference.depth - 1 }).is_ok() {
			crash "picture-codec: depth bound ignored"
		}
	}
	Fuzz.keep
}

## Named cases are preflighted as pure properties and independently handed to
## roc-fuzz for its mandatory optimized fixed-example preparation and replay.
fixed_cases : List({ name : Str, revision : Str, make : () -> List(U8) })
fixed_cases = [
	{ name: "raw-empty", revision: "1", make: || [] },
	{ name: "empty-picture", revision: "1", make: || Corpus.empty },
	{ name: "all-roles", revision: "1", make: || Corpus.rich },
	{ name: "last-byte-cut", revision: "1", make: || Corpus.rich.drop_last(1) },
	{ name: "trailing-byte", revision: "1", make: || Corpus.rich.append(0) },
	{
		name: "container-count-bomb",
		revision: "1",
		make: || {
			var $bytes = Corpus.empty
			for at in 99.U64..<103 {
				$bytes = $bytes.set(at, 255) ?? crash "fixed corpus count offset"
			}
			$bytes
		},
	},
	{ name: "unknown-logical-role", revision: "1", make: || Corpus.rich.set(203, 5) ?? crash "fixed corpus offset" },
	{ name: "unknown-binding-role", revision: "1", make: || Corpus.rich.set(374, 4) ?? crash "fixed corpus offset" },
	{ name: "unknown-scaffold-role", revision: "1", make: || Corpus.rich.set(482, 3) ?? crash "fixed corpus offset" },
	{ name: "birth-at-flags", revision: "1", make: || Corpus.rich.set(370, 0) ?? crash "fixed corpus offset" },
	{ name: "birth-after-batch", revision: "1", make: || Corpus.rich.set(370, 32) ?? crash "fixed corpus offset" },
	{ name: "invalid-presence", revision: "1", make: || Corpus.rich.set(491, 2) ?? crash "fixed corpus offset" },
	{ name: "invalid-utf8", revision: "1", make: || Corpus.rich.set(254, 255) ?? crash "fixed corpus offset" },
	{ name: "hole-attribute-kind", revision: "1", make: || Corpus.rich.set(419, 2) ?? crash "fixed corpus offset" },
	{ name: "hole-event-kind", revision: "1", make: || Corpus.rich.set(419, 3) ?? crash "fixed corpus offset" },
	{ name: "hole-bind-kind", revision: "1", make: || Corpus.rich.set(419, 4) ?? crash "fixed corpus offset" },
	{ name: "hole-property-kind", revision: "1", make: || Corpus.rich.set(419, 6) ?? crash "fixed corpus offset" },
	{ name: "alias-bind-kind", revision: "1", make: || Corpus.rich.set(437, 4) ?? crash "fixed corpus offset" },
	{ name: "omitted-root-logical-depth", revision: "1", make: || [5] },
	{ name: "depth-four-reserved-facts", revision: "1", make: || [4, 1, 1, 3, 255, 128] },
]

## Every declared fixed input must satisfy the same property before a costly
## optimized build; this check does not replace actual roc-fuzz execution.
expect fixed_cases.all(
	|example| match test((example.make)()) {
		Keep => True
		Reject => False
	},
)

## Actual fixed replays use the same declared examples, never another input list.
target = Fuzz.target_with({
	name: "picture-codec",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(bytes),
	examples: fixed_cases.map(Fuzz.example),
})
