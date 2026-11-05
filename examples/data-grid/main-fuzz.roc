app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Core
import pf.Fuzz
import ts.Scm
import ts.Soak
import ts.SpecRunner
import GridApp

## Data Grid on the Roc-owned engine.

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [Fill(Label("Filter"), "Node-0007"), Fill(Label("Filter"), ""), Click(Role({ role: "button", name: "Next page" })), Click(Role({ role: "button", name: "Previous page" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(GridApp.program), SpecRunner.mount(Core.driver(GridApp.program), "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Core.driver(GridApp.program), SpecRunner.mount(Core.driver(GridApp.program), "/", []), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(Core.driver(GridApp.program), SpecRunner.mount(Core.driver(GridApp.program), "/", []), cycle, |s| s)
	counts = Soak.replay!(Core.driver(GridApp.program), s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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
test! = |{ mode, program, .. }| {
	if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "data-grid",
	examples: [
		ex("soak-10k", 3, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
