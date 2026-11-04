app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import GridData
import GridApp

## The engine-level state the benches measure transactions on.
B : { eng : Engine.App, dom : Dom.Model, steps : U64 }

## Data Grid on the Roc-owned engine.
## - "bench-N": an N-row dataset (the original has 1,200), then measured
##   single transactions: a note edit and a selection on the visible page,
##   paging, sorting and filtering.

mstep! : B, Str, Scm.Loc, Str, Str => B
mstep! = |s, name, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "${name}: no ${Scm.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "${name}: no handler"
	{ eng, dom, steps } = s
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(Engine.event(eng, node, h, payload), [])
	_ = w.finish!()
	{ eng: a, dom: Dom.apply(dom, c), steps: steps + 1 }
}

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	data = GridData.generate_rows(n)
	view = GridApp.main_with(data)
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	# The app's own derivation for a filter keystroke, outside the engine.
	wj = Fuzz.start_measure!("app-filter-sort-summary")
	f1 = GridApp.filter_in(data, "Node-1")
	s1 = GridData.sort_rows(f1, { key: ById, desc: False })
	sm = GridData.summarize(f1, [])
	_ = wj.finish!()
	_ = (s1, sm)
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	$s = mstep!($s, "note-edit", Label("Note for Node-0003"), "input", "needs review")
	$s = mstep!($s, "note-edit-again", Label("Note for Node-0003"), "input", "needs review!")
	$s = mstep!($s, "select-row", Label("Select Node-0004"), "change", "true")
	$s = mstep!($s, "next-page", Role({ role: "button", name: "Next page" }), "click", "")
	$s = mstep!($s, "prev-page", Role({ role: "button", name: "Previous page" }), "click", "")
	$s = mstep!($s, "sort-score", Role({ role: "button", name: "Sort by score" }), "click", "")
	$s = mstep!($s, "sort-id", Role({ role: "button", name: "Sort by id" }), "click", "")
	$s = mstep!($s, "filter", Label("Filter"), "input", "Node-1")
	$s = mstep!($s, "filter-clear", Label("Filter"), "input", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [Fill(Label("Filter"), "Node-0007"), Fill(Label("Filter"), ""), Click(Role({ role: "button", name: "Next page" })), Click(Role({ role: "button", name: "Previous page" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(GridApp.program, SpecRunner.mount(GridApp.program, "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(GridApp.program, SpecRunner.mount(GridApp.program, "/", []), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(GridApp.program, SpecRunner.mount(GridApp.program, "/", []), cycle, |s| s)
	counts = Soak.replay!(GridApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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
	if mode == 0 {
		if (size > 12000) Fuzz.reject else bench!(size)
	} else if mode == 2 {
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
		ex("bench-1200", 0, 1200),
		ex("bench-12000", 0, 12000),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
