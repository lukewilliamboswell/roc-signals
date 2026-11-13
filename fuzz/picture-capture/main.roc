app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.PictureCapture

## The model writes the final stream directly, including ports in issue order.
## Capture sees only ordinary command positions until the turn seals. Bytes
## generate valid histories with aliases, repeated addresses and port-only turns.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	var $capture = PictureCapture.start({ max_records: 2048 }) ?? crash "valid capture test limit"
	var $expected = []
	var $insertions = []
	var $ordinary = 1.U64
	var $final = 1.U64
	for byte in bytes.take_first(512) {
		length = byte.to_u64() + 17
		address = (byte % 8).to_u32() + 1
		match byte % 4 {
			0 => {
				opcode = if (byte % 8 == 0) 19.U8 else 13.U8
				$insertions = $insertions.append({ at: $ordinary, bytes: length, opcode })
				$expected = $expected.append({ at: $final.to_u32_wrap(), end: ($final + length).to_u32_wrap(), opcode, address: 0.U32, slot: 0.U32, kind: 0.U8 })
				$final = $final + length
			}
			1 => {
				opcode = if (byte % 8 == 1) 10.U8 else 5.U8
				$capture = PictureCapture.command($capture, { at: $ordinary, end: $ordinary + length, opcode, address, slot: 0 })
				$expected = $expected.append({ at: $final.to_u32_wrap(), end: ($final + length).to_u32_wrap(), opcode, address, slot: 0.U32, kind: 0.U8 })
				$ordinary = $ordinary + length
				$final = $final + length
			}
			2 => {
				kind = if (byte % 8 == 2) 4.U8 else 5.U8
				hole = byte.to_u32() % 5
				$capture = PictureCapture.command($capture, { at: $ordinary, end: $ordinary + length, opcode: 1, address, slot: 7 })
				$capture = PictureCapture.hole($capture, { at: $ordinary, end: $ordinary + length, row: address, index: hole, kind })
				$capture = PictureCapture.alias($capture, { at: $ordinary, end: $ordinary + length, address: address + 16, hole, kind })
				$expected = $expected.append({ at: $final.to_u32_wrap(), end: ($final + length).to_u32_wrap(), opcode: 1, address, slot: 7, kind: 0 })
				$expected = $expected.append({ at: $final.to_u32_wrap(), end: ($final + length).to_u32_wrap(), opcode: 255, address, slot: hole, kind })
				$expected = $expected.append({ at: $final.to_u32_wrap(), end: ($final + length).to_u32_wrap(), opcode: 0, address: address + 16, slot: hole, kind })
				$ordinary = $ordinary + length
				$final = $final + length
			}
			_ => {
				$capture = PictureCapture.seal($capture, $insertions)
				$insertions = []
				$ordinary = $final
			}
		}
	}
	actual = PictureCapture.finish(PictureCapture.seal($capture, $insertions)) ?? crash "capture refused bounded valid history"
	if actual != $expected {
		crash "capture changed command positions, port order or alias incarnations"
	}
	Fuzz.keep
}

## Fixed histories exercise ports before aliases, repeated same-gap ports,
## port-only turns, address reuse and several seals without a command.
fixed_cases : List({ name : Str, revision : Str, make : () -> List(U8) })
fixed_cases = [
	{ name: "empty", revision: "1", make: || [] },
	{ name: "port-only", revision: "1", make: || [0] },
	{ name: "same-gap-ports", revision: "1", make: || [0, 4, 8, 12] },
	{ name: "ports-before-alias", revision: "1", make: || [0, 4, 2, 6] },
	{ name: "ports-after-alias", revision: "1", make: || [2, 0, 4, 3] },
	{ name: "address-reuse-across-turns", revision: "1", make: || [1, 5, 3, 0, 1, 2, 3, 6] },
	{ name: "empty-seals", revision: "1", make: || [3, 7, 11, 0, 3, 7, 2, 3, 3] },
	{
		name: "all-byte-roles",
		revision: "1",
		make: || {
			var $all = []
			for byte in 0.U16..<256 {
				$all = $all.append(byte.to_u8_wrap())
			}
			$all
		},
	},
	{ name: "long-port-only", revision: "1", make: || List.repeat(0, 512) },
	{ name: "long-alias-only", revision: "1", make: || List.repeat(2, 512) },
]

## This preflight checks the same reference property, while the actual target
## remains responsible for optimized fixed-example replay and allocation checks.
expect fixed_cases.all(
	|example| match test((example.make)()) {
		Keep => True
		Reject => False
	},
)

target = Fuzz.target_with({
	name: "picture-capture",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(bytes),
	examples: fixed_cases.map(Fuzz.example),
})
