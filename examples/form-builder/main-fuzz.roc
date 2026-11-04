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
import Form
import FormApp

## The engine-level state the benches measure transactions on.
B : { eng : Engine.App, dom : Dom.Model, steps : U64 }

## Form Builder on the Roc-owned engine.
## - specs: run through main-test.roc (events in,
##   decoded DOM out); any mismatch crashes with the spec and step.
## - "bench-N": mount with N fields, then measured single transactions
##   (event + command buffer handed back) on the field in the middle.
## - generated: random sequences of designer/preview edits checked against a
##   reference model of the schema/answers (the DOM's field order, labels,
##   summaries, verdicts and counts must match the pure Form functions).

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
mstep! : B, Str, Scm.Loc, Str, Str => B
mstep! = |s, name, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "${name}: no ${Scm.show_loc(loc)}"
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
	$s = mstep!($s, "move-up", Role({ role: "button", name: "Move up ${mid}" }), "click", "")
	$s = mstep!($s, "submit", Role({ role: "button", name: "Submit form" }), "click", "")
	$s = mstep!($s, "add-field", Role({ role: "button", name: "Add text field" }), "click", "")
	$s = mstep!($s, "delete-field", Role({ role: "button", name: "Delete ${mid}" }), "click", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [Fill(Label("Answer f1"), "Ada"), Fill(Label("Answer f1"), ""), Click(Role({ role: "button", name: "Move up f2" })), Click(Role({ role: "button", name: "Move up f1" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(FormApp.program, SpecRunner.mount(FormApp.program, "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(FormApp.program, SpecRunner.mount(FormApp.program, "/", []), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(FormApp.program, SpecRunner.mount(FormApp.program, "/", []), cycle, |s| s)
	counts = Soak.replay!(FormApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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

## Engine mount alone at n fields (measured), no DOM model.
mount_only! : U64 => Fuzz.Outcome
mount_only! = |n| {
	view = FormApp.main_with(schema_of(n))
	w = Fuzz.start_measure!("mount")
	(_, c) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	if c.len() < n {
		crash "mount produced too few commands"
	}
	Fuzz.keep
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 0 {
		if (size > 70000) Fuzz.reject else bench!(size)
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 4 {
		mount_only!(size)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "form-builder",
	examples: [
		ex("soak-10k", 3, 0),
		ex("bench-20", 0, 20),
		ex("bench-200", 0, 200),
		# ~65k fields: more than 4,095 each sites (one nested each per field row);
		# engine mount only (the DOM oracle is too slow at this size)
		ex("mount-65536", 4, 65536),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
