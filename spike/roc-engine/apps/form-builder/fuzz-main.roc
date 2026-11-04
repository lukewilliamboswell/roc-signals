app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import Soak
import Form
import FormApp
import FormSpecs

## Form Builder on the p4 engine.
## - "specs": every original .scm spec replayed through Spec.run (events in,
##   decoded DOM out); any mismatch crashes with the spec and step.
## - "bench-N": mount with N fields, then measured single transactions
##   (event + command buffer handed back) on the field in the middle.
## - generated: random sequences of designer/preview edits checked against a
##   reference model of the schema/answers (the DOM's field order, labels,
##   summaries, verdicts and counts must match the pure Form functions).

specs! : {} => Fuzz.Outcome
specs! = |_| {
	for (name, steps) in FormSpecs.all {
		match Spec.run(FormApp.main({}), steps) {
			Ok(_) => {}
			Err(msg) => crash "spec ${name}: ${msg}"
		}
	}
	Fuzz.keep
}

schema_of : U64 -> Form.Schema
schema_of = |n| {
	var $s = { seq: 0, fields: [] }
	var $i = 0.U64
	while $i < n {
		kind = match $i % 4 {
			0 => Form.text_kind
			1 => Form.number_kind
			2 => Form.email_kind
			_ => Form.select_kind
		}
		$s = Form.add_field($s, kind)
		$i = $i + 1
	}
	$s
}

## One measured transaction on the node the locator finds.
mstep! : Spec.S, Str, Spec.Loc, Str, Str => Spec.S
mstep! = |s, name, loc, ev, payload| {
	i = Spec.find(s.dom, loc) ?? crash "${name}: no ${Spec.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "${name}: no handler"
	{ eng, dom, steps } = s
	e0 = Engine.evals(eng)
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(Engine.event(eng, node, h, payload), [])
	_ = w.finish!()
	evals = Engine.evals(a) - e0
	(d2, ops) = Dom.apply_ops(dom, c)
	Fuzz.mark!("${name}: evals=${evals.to_str()} ${Dom.describe(ops)}")
	{ eng: a, dom: d2, steps: steps + 1 }
}

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	view = FormApp.main_with(schema_of(n))
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	s0 = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	mid = "f${((n // 2) // 4 * 4 + 1).to_str()}"
	# The app's own work, outside the engine: the schema x answers join that
	# every schema or answer edit recomputes (as in the original).
	schema = schema_of(n)
	wj = Fuzz.start_measure!("app-join-rows_of")
	rows = Form.rows_of(schema.fields, [{ id: mid, text: "Ada", flag: False }])
	_ = wj.finish!()
	_ = rows
	var $s = s0
	$s = mstep!($s, "edit-label", Label("Label ${mid}"), "input", "Renamed")
	$s = mstep!($s, "edit-label-again", Label("Label ${mid}"), "input", "Renamed!")
	$s = mstep!($s, "answer", Label("Answer ${mid}"), "input", "Ada")
	$s = mstep!($s, "answer-again", Label("Answer ${mid}"), "input", "Ada L")
	$s = mstep!($s, "edit-label-after-answer", Label("Label ${mid}"), "input", "Renamed?")
	$s = mstep!($s, "answer-third", Label("Answer ${mid}"), "input", "Ada Lo")
	$s = mstep!($s, "toggle-required", Label("Required ${mid}"), "change", "true")
	$s = mstep!($s, "move-up", Role("button", "Move up ${mid}"), "click", "")
	$s = mstep!($s, "submit", Role("button", "Submit form"), "click", "")
	$s = mstep!($s, "add-field", Role("button", "Add text field"), "click", "")
	$s = mstep!($s, "delete-field", Role("button", "Delete ${mid}"), "click", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Spec.Step)
cycle = [Fill(Label("Answer f1"), "Ada"), Fill(Label("Answer f1"), ""), Click(Role("button", "Move up f2")), Click(Role("button", "Move up f1"))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Spec.start(FormApp.main({})), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 12 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Spec.start(FormApp.main({})), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(Spec.start(FormApp.main({})), cycle, |s| s)
	counts = Soak.replay!(s1.eng, evs, 12, |a, b| (a, b), |_| Fuzz.live_alloc_count!())
	match Soak.flat(counts, 2) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle live allocations ${Str.inspect(counts)}")
	Fuzz.keep
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 0 {
		if size > 1000 Fuzz.reject else bench!(size)
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		specs!({})
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "p4-form-builder",
	examples: [
		ex("specs", 1, 0),
		ex("soak-10k", 3, 0),
		ex("bench-20", 0, 20),
		ex("bench-200", 0, 200),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
