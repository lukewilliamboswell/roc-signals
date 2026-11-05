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
import Sheet
import SheetApp

## Spreadsheet Lite on the Roc-owned engine (its specs run through
## `main-test.roc`).
## - "bench": one measured region per engine transaction: selecting a cell,
##   editing a cell with a deep dependency chain and one nothing depends on,
##   typing a formula in the formula bar, and every view toggle.
## - generated: explorer-driven random walks over the live DOM (typing into
##   cells and the formula bar, focus, blur, toggles), which must free
##   everything they allocated.
## - "soak-10k": 10k seeded events, then an edit, reorder, filter and mode
##   round trip 48 times on the engine alone with flat live bytes.

B : { eng : Engine.App, dom : Dom.Model }

mstep! : B, Str, Scm.Loc, Str, Str => B
mstep! = |s, name, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "${name}: no ${Scm.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "${name}: no ${ev} handler"
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(Engine.event(s.eng, node, h, payload), [])
	_ = w.finish!()
	{ eng: a, dom: Dom.apply(s.dom, c) }
}

button : Str -> Scm.Loc
button = |name| Role({ role: "button", name })

bench! : {} => Fuzz.Outcome
bench! = |_| {
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(SheetApp.main(Sheet.initial_cells)), [])
	_ = w.finish!()
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0) }
	$s = mstep!($s, "focus-b2", Label("B2"), "focus", "1200")
	$s = mstep!($s, "edit-b2-chain", Label("B2"), "input", "1500")
	$s = mstep!($s, "restore-b2", Label("B2"), "input", "1200")
	$s = mstep!($s, "blur-b2", Label("B2"), "blur", "1200")
	$s = mstep!($s, "focus-c12", Label("C12"), "focus", "7")
	$s = mstep!($s, "edit-c12-leaf", Label("C12"), "input", "9")
	$s = mstep!($s, "formula-bar", Label("Formula"), "input", "=B2+C2+100")
	$s = mstep!($s, "formula-bar-error", Label("Formula"), "input", "=1/0")
	$s = mstep!($s, "show-formulas", button("Show formulas"), "click", "")
	$s = mstep!($s, "show-values", button("Show values"), "click", "")
	$s = mstep!($s, "hide-empty", button("Hide empty rows"), "click", "")
	$s = mstep!($s, "show-all", button("Show all rows"), "click", "")
	$s = mstep!($s, "reverse", button("Reverse row order"), "click", "")
	$s = mstep!($s, "unreverse", button("Top to bottom"), "click", "")
	_ = $s
	Fuzz.keep
}

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [
	Fill(Label("B2"), "1500"),
	Fill(Label("B2"), "1200"),
	Click(button("Reverse row order")),
	Click(button("Top to bottom")),
	Click(button("Hide empty rows")),
	Click(button("Show all rows")),
	Click(button("Show formulas")),
	Click(button("Show values")),
]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(SheetApp.program, SpecRunner.mount(SheetApp.program, "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(SheetApp.program, SpecRunner.mount(SheetApp.program, "/", []), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(SheetApp.program, SpecRunner.mount(SheetApp.program, "/", []), cycle, |s| s)
	counts = Soak.replay!(SheetApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program, .. }| {
	if mode == 0 {
		bench!({})
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
	name: "spreadsheet-lite",
	examples: [
		ex("soak-10k", 3, 0),
		ex("bench", 0, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
