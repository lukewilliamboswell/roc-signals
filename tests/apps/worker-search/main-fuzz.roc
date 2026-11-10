app [target] { pf: platform "../../../platform/fuzz.roc" }

import pf.Core
import pf.Fuzz
import pf.Scm
import pf.Soak
import pf.SpecRunner
import SearchApp

## Worker search on the fuzz platform: soaks of an app whose work runs in
## worker programs. The walks answer pending jobs as `Soak.step` does (run in
## process, lost with a fault class, timed out, or left pending), so every
## program runs inside the leak check, and a program that crashes on an
## input the UI produced is a finding.
## - generated: explorer-driven walks, settled after every step (a job's
##   answer included), which must free everything they allocated.
## - "soak-10k": 10k seeded steps, then a search, a cleared query and the
##   report opened and closed, 48 times on the engine alone with every job
##   answered: live bytes flat.

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle): a search answered, a
## cleared query (a pure cancel), and the report's job answered, then
## disposed with its panel.
cycle : List(Scm.Op)
cycle = [Fill(Label("Search"), "roc"), Fill(Label("Search"), ""), Click(Role({ role: "button", name: "Report" })), Click(Role({ role: "button", name: "Report" }))]

## Answer every job in flight on the engine alone, as a worker instance
## would: the job a cycle event issued runs its program in process.
answer_all : Core.App, List(U8) -> (Core.App, List(U8))
answer_all = |a0, b0| {
	var $a = a0
	var $b = b0
	for id in Core.fx_live(a0) {
		(a1, b1) = Core.take_cmds(Core.result($a, id, Work(SearchApp.filter("roc".to_utf8()))), $b)
		$a = a1
		$b = b1
	}
	($a, $b)
}

start : {} -> SpecRunner.S(Core.App)
start = |_| SpecRunner.mount(Core.driver(SearchApp.program), "/", [])

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(SearchApp.program), start({}), program, Soak.settled(Core.driver(SearchApp.program))))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (settle-checked and leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Core.driver(SearchApp.program), start({}), 7, 10000, Soak.settled(Core.driver(SearchApp.program))))
	(s1, evs) = Soak.triples(Core.driver(SearchApp.program), start({}), cycle, Soak.settled(Core.driver(SearchApp.program)))
	counts = Soak.replay!(Core.driver(SearchApp.program), s1.inst, evs, 48, answer_all, begin!, net_bytes!)
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
	name: "worker-search",
	examples: [
		ex("soak-10k", 3, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
