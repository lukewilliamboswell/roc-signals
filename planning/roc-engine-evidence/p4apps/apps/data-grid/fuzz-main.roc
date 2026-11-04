app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import GridData
import GridApp
import GridSpecs

## Data Grid on the p4 engine.
## - "specs": every original .scm spec replayed through Spec.run.
## - "bench-N": an N-row dataset (the original has 1,200), then measured
##   single transactions: a note edit and a selection on the visible page,
##   paging, sorting and filtering.

specs! : {} => Fuzz.Outcome
specs! = |_| {
	for (name, steps) in GridSpecs.all {
		match Spec.run(GridApp.main({}), steps) {
			Ok(_) => {}
			Err(msg) => crash "spec ${name}: ${msg}"
		}
	}
	Fuzz.keep
}

mstep! : Spec.S, Str, Spec.Loc, Str, Str => Spec.S
mstep! = |s, name, loc, ev, payload| {
	i = Spec.find(s.dom, loc) ?? crash "${name}: no ${Spec.show_loc(loc)}"
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
	$s = mstep!($s, "next-page", Role("button", "Next page"), "click", "")
	$s = mstep!($s, "prev-page", Role("button", "Previous page"), "click", "")
	$s = mstep!($s, "sort-score", Role("button", "Sort by score"), "click", "")
	$s = mstep!($s, "sort-id", Role("button", "Sort by id"), "click", "")
	$s = mstep!($s, "filter", Label("Filter"), "input", "Node-1")
	$s = mstep!($s, "filter-clear", Label("Filter"), "input", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program: _ }| {
	if mode == 0 {
		bench!(size)
	} else {
		specs!({})
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "p4-data-grid",
	examples: [
		ex("specs", 1, 0),
		ex("bench-1200", 0, 1200),
		ex("bench-12000", 0, 12000),
	],
	generator: { mode: Fuzz.constant(1), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 8) }.Fuzz,
	test!,
	show: Str.inspect,
})
