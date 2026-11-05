app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import ts.Scm
import ts.Soak
import ts.SpecRunner
import MdApp

## Markdown Editor on the Roc-owned engine.

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)

## (Append then remove a section is not an exact inverse in this app: each
## round trip leaves one more trailing newline, so it grows by design.)
cycle = [Click(Role({ role: "button", name: "Load heading drill" })), Click(Role({ role: "button", name: "Load document without headings" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 2,000 seeded random events per example (five examples,
## seeds 1-5: 10k events; the DOM oracle makes one 10k walk exceed the
## per-input timeout here), leak-checked, then the round trip 48 times on
## the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : U64 => Fuzz.Outcome
soak_10k! = |seed| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), seed, 2000, |s| s))
	(s1, evs) = Soak.triples(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), cycle, |s| s)
	counts = Soak.replay!(MdApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
	match Soak.flat(counts, 2) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle net live bytes ${Str.inspect(counts.sublist({ start: 0, len: 4 }))} ... (${counts.len().to_str()} cycles)")
	Fuzz.keep
}

## Soak probes: a measured region around one cycle; its net live bytes.
begin! : {} => Fuzz.Measurement
begin! = |_| Fuzz.start_measure!("cycle")

net_bytes! : Fuzz.Measurement => I64
net_bytes! = |w| {
	stats = w.finish!()
	stats.exit_live_bytes.to_i64_wrap() - stats.entry_live_bytes.to_i64_wrap()
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!(size)
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "markdown-editor",
	examples: [
		ex("soak-2k-s1", 3, 1),
		ex("soak-2k-s2", 3, 2),
		ex("soak-2k-s3", 3, 3),
		ex("soak-2k-s4", 3, 4),
		ex("soak-2k-s5", 3, 5),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
