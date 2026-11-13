app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.PictureCapture
import pf.PictureBoot
import pf.PictureHash
import pf.PictureVerdict
import pf.PictureCodec
import pf.PicturePlan

## This reference numbers incarnations by a per-address generation, rather
## than the production birth-offset maps. The generated program is a bounded
## flat DOM history of text creation, writes, removal, clearing and services.
Event : { frame : PictureCapture.Frame, generation : U32, verb : [Birth, Write, Remove, Clear, Service] }

## The fixture's independent wire encoder does not call the plan's reader.
word : List(U8), U32 -> List(U8)
word = |bytes, value| bytes.append(value.to_u8_wrap()).append(value.shr_wrap(8).to_u8_wrap()).append(value.shr_wrap(16).to_u8_wrap()).append(value.shr_wrap(24).to_u8_wrap())

## Decode arbitrary bytes into valid small programs; all generated histories
## are checked, including prefixes containing no live nodes at their end.
test : List(U8) -> Fuzz.Outcome
test = |input| {
	var $batch = [0.U8]
	var $events = []
	var $alive = List.repeat(False, 8)
	var $generation = List.repeat(0.U32, 8)
	var $births = List.repeat(0.U32, 8)
	var $text = List.repeat(97.U8, 8)
	var $order = []
	for byte in input.take_first(64) {
		address = (byte % 8).to_u32() + 1
		index = address.to_u64() - 1
		verb = byte % 5
		was_alive = $alive.get(index) ?? crash "bounded model address"
		if verb == 0 and was_alive {
			at = $batch.len().to_u32_wrap()
			$batch = word($batch.append(5), address)
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 5, address, slot: 0, kind: 0 }, generation: $generation.get(index) ?? crash "model generation", verb: Remove })
			$order = $order.keep_if(|existing| existing != address)
		}
		if verb == 0 or (verb == 1 and !was_alive) {
			at = $batch.len().to_u32_wrap()
			$batch = word(word(word(word($batch.append(10), address), 0), 0), 1).append(97)
			age = ($generation.get(index) ?? crash "model generation") + 1
			$generation = $generation.set(index, age) ?? crash "model generation index"
			$births = $births.set(index, at) ?? crash "model birth index"
			$alive = $alive.set(index, True) ?? crash "model live index"
			$text = $text.set(index, 97) ?? crash "model text index"
			$order = $order.append(address)
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 10, address, slot: 0, kind: 0 }, generation: age, verb: Birth })
		}
		if verb == 1 {
			at = $batch.len().to_u32_wrap()
			value = if (($text.get(index) ?? crash "model text") == 97) 98.U8 else 97.U8
			$text = $text.set(index, value) ?? crash "model text index"
			$batch = word(word($batch.append(12), address), 1).append(value)
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 12, address, slot: 0, kind: 0 }, generation: $generation.get(index) ?? crash "model generation", verb: Write })
		} else if verb == 2 and was_alive {
			at = $batch.len().to_u32_wrap()
			$batch = word($batch.append(5), address)
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 5, address, slot: 0, kind: 0 }, generation: $generation.get(index) ?? crash "model generation", verb: Remove })
			$alive = $alive.set(index, False) ?? crash "model live index"
			$order = $order.keep_if(|existing| existing != address)
		} else if verb == 3 {
			at = $batch.len().to_u32_wrap()
			$batch = word(word($batch.append(6), 0), 7)
			$alive = List.repeat(False, 8)
			$order = []
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 6, address: 0, slot: 7, kind: 0 }, generation: 0, verb: Clear })
		} else if verb == 4 {
			at = $batch.len().to_u32_wrap()
			$batch = word($batch.append(17), 1).append(65)
			$events = $events.append({ frame: { at, end: $batch.len().to_u32_wrap(), opcode: 17, address: 0, slot: 0, kind: 0 }, generation: 0, verb: Service })
		}
	}
	var $free = []
	for address in 1.U32..=8 {
		if !($alive.get(address.to_u64() - 1) ?? crash "model free index") {
			$free = $free.append(address)
		}
	}
	var $bindings = []
	var $logical = []
	var $parts = []
	var $ordinal = 0.U32
	for address in $order {
		$bindings = $bindings.append({ birth_offset: $births.get(address.to_u64() - 1) ?? crash "model final birth", role: Static, address, slot: 0, kind: Unused, logical: $ordinal })
		$logical = $logical.append(TextPart({ run: 0, part: $ordinal }))
		$parts = $parts.append({ logical: $ordinal, utf16_units: 1 })
		$ordinal = $ordinal + 1
	}
	envelope = PictureCodec.make({ root_name: { namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "main" }, batch_bytes: $batch.len().to_u32_wrap(), fingerprint: List.repeat(0, 32), expected: List.repeat(0, 32), physical_count: if ($order.is_empty()) 0 else 1, containers: [{ owner: Mount, role: Children, children: if ($order.is_empty()) [] else [0] }], logical: $logical, runs: if ($order.is_empty()) [] else [{ container: 0, child_index: 0, physical: Physical(0), parts: $parts }], bindings: $bindings, scaffolds: [] }, {}) ?? crash "valid model picture framing"
	plain_parts = PictureCodec.parts(envelope)
	fingerprint = PictureHash.digest(word("roc-signals/mount/19/1".to_utf8().append(0), $batch.len().to_u32_wrap()).concat($batch))
	checked_envelope = PictureCodec.make({ ..plain_parts, fingerprint }, {}) ?? crash "matching fingerprint retains checked topology"
	picture = PictureBoot.present({ measured: plain_parts.expected, envelope: PictureCodec.encode(checked_envelope) }) ?? crash "bounded picture transport"
	frames = $events.map(|event| event.frame)
	plan = PicturePlan.build({ batch: $batch, frames, next: 9, free: $free, envelope }) ?? crash "plan refused valid generated program"
	verdict = PictureVerdict.decide({ picture, root_name: plain_parts.root_name, batch: $batch, capture: Ok(frames), next: 9, free: $free }, {}) ?? crash "valid verdict limits"
	match PictureVerdict.parts(verdict) {
		Adopt(accepted) => if PicturePlan.operations(accepted) != PicturePlan.operations(plan) {
			crash "Roc verdict changed the accepted operation plan"
		}
		Replace(_) => crash "Roc replaced matching measured and fresh mount facts"
	}
	changed = PictureBoot.present({ measured: List.repeat(1, 32), envelope: PictureCodec.encode(checked_envelope) }) ?? crash "bounded disturbed measurement"
	refused = PictureVerdict.decide({ picture: changed, root_name: plain_parts.root_name, batch: $batch, capture: Ok(frames), next: 9, free: $free }, {}) ?? crash "valid disturbed verdict limits"
	match PictureVerdict.parts(refused) {
		Replace(DifferentMeasurement) => {}
		_ => crash "Roc did not replace a changed measured digest"
	}
	actual = PicturePlan.operations(plan)
	if actual.len() != $events.len() {
		crash "plan omitted a command boundary"
	}
	var $event_index = 0.U64
	for event in $events {
		frame = event.frame
		live = if (frame.address == 0) False else ($alive.get(frame.address.to_u64() - 1) ?? crash "model final live") and ($generation.get(frame.address.to_u64() - 1) ?? crash "model final generation") == event.generation
		wanted = match event.verb {
			Birth => if live {
				position = $order.find_first_index(|address| address == frame.address) ?? crash "live model address has a position"
				ClaimStatic(position.to_u32_wrap())
			} else Skip
			Write => if (live) Apply else Skip
			Remove => Skip
			Clear => ClearSite(7)
			Service => Apply
		}
		if actual.get($event_index) != Ok({ at: frame.at, end: frame.end, action: wanted }) {
			crash "plan differs from generation-based reference"
		}
		$event_index = $event_index + 1
	}
	match $bindings.first() {
		Ok(first) => {
			parts = PictureCodec.parts(envelope)
			wrong = PictureCodec.make({ ..parts, bindings: parts.bindings.set(0, { ..first, birth_offset: first.birth_offset + 1 }) ?? crash "model first binding" }, {}) ?? crash "wrong claim remains framing-valid"
			if PicturePlan.build({ batch: $batch, frames, next: 9, free: $free, envelope: wrong }).is_ok() {
				crash "plan accepted a claim inside a command instead of at its birth"
			}
		}
		Err(_) => {}
	}
	Fuzz.keep
}

## Long inputs stay bounded; repetitions force numeric address reuse rather
## than expanding a fixture tree or retaining snapshots of engine storage.
fixed_cases : List({ name : Str, revision : Str, make : () -> List(U8) })
fixed_cases = [
	{ name: "empty", revision: "1", make: || [] },
	{ name: "one-live-text", revision: "1", make: || [0] },
	{ name: "same-address-generations", revision: "1", make: || [0, 40, 80, 120] },
	{ name: "writes-before-and-after-clear", revision: "1", make: || [1, 41, 3, 81, 121] },
	{ name: "removed-final-text", revision: "1", make: || [10, 2] },
	{ name: "services-around-reuse", revision: "1", make: || [4, 0, 44, 40, 84, 3, 124] },
	{ name: "several-live-addresses", revision: "1", make: || [0, 5, 10, 15, 20, 25, 30, 35] },
	{ name: "bounded-long-reuse", revision: "1", make: || List.repeat(40, 128) },
]

## Preflight is the same property; optimized roc-fuzz fixed replay is a
## separate required check with its allocation and trace validation intact.
expect fixed_cases.all(
	|example| match test((example.make)()) {
		Keep => True
		Reject => False
	},
)

target = Fuzz.target_with({ name: "picture-plan", generator: Fuzz.raw_bytes, test, show: |input| Str.inspect(input), examples: fixed_cases.map(Fuzz.example) })
