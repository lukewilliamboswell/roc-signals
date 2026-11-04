app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Jfb
import T1
import T2
import Canary
import NestedEach

## Phase 2 unified-engine target. Three oracles, none sharing engine code:
## - the DOM decoded from the command stream (Dom.roc) must show exactly the
##   reference model's rows (key, label, selected class) after every step;
## - kept keys keep their DOM row node (keyed identity, no recreation);
## - the engine's derived-evaluation count must equal the count the reference
##   predicts: 1 list read per model write, 3 per created row, 1 per row whose
##   item changed, 1 per row whose selected-ness changed. Unchanged rows may
##   not be evaluated.
## Measured regions (exact allocation baselines) wrap one engine transaction
## on the host path (event + command buffer handed back), as the Wasm host does.

Run : {
	eng : Engine.App,
	dom : Dom.Model,
	buf : List(U8),
	ref : Jfb.Model,
	sel : Str,
	buttons : List((Str, (U32, U32))),
	tbody : U64,
	small : U64,
	lots : U64,
}

button_ids : List(Str)
button_ids = ["run", "runlots", "add", "update", "clear", "swaprows", "updone", "reverse", "rotate", "dropodd", "insmid", "shuffle", "same"]

start : U64, U64 -> Run
start = |small, lots| {
	(eng, cmds) = Engine.take_cmds(Engine.mount(Jfb.view_with(small, lots, True)), [])
	dom = Dom.apply(Dom.new({}), cmds)
	buttons = button_ids.map(|id| (id, Dom.click_target(dom, Dom.by_attr(dom, "id", id) ?? crash "button ${id}") ?? crash "no handler"))
	tbody = Dom.by_attr(dom, "id", "tbody") ?? crash "tbody"
	{ eng, dom, buf: cmds, ref: Jfb.initial, sel: "", buttons, tbody, small, lots }
}

ref_button : Jfb.Model, Str, U64, U64 -> Jfb.Model
ref_button = |m, id, small, lots| {
	if id == "run" {
		Jfb.run(m, small)
	} else if id == "runlots" {
		Jfb.run(m, lots)
	} else if id == "add" {
		Jfb.add_rows(m, small)
	} else if id == "update" {
		Jfb.update_every_10(m)
	} else if id == "clear" {
		Jfb.clear(m)
	} else if id == "swaprows" {
		Jfb.swap_any(m)
	} else if id == "updone" {
		Jfb.update_one(m)
	} else if id == "reverse" {
		Jfb.reverse(m)
	} else if id == "rotate" {
		Jfb.rotate(m)
	} else if id == "dropodd" {
		Jfb.drop_odd(m)
	} else if id == "insmid" {
		Jfb.ins_mid(m)
	} else if id == "shuffle" {
		Jfb.shuffle(m)
	} else if id == "same" {
		Jfb.same_label(m)
	} else {
		crash "unknown button"
	}
}

Action : [Button(Str), Select(U64), Remove(U64)]

## The (node, handler) the browser would dispatch for this action.
target_of : Run, Action -> (U32, U32)
target_of = |r, action| match action {
	Button(id) => r.buttons.find_first(|(b, _)| b == id).map_ok(|(_, t)| t) ?? crash "button"
	Select(pos) => if r.lots > 1000 (1.U32.shl_wrap(20) + pos.to_u32_wrap() + 1, 0) else row_link(r, pos, 1)
	Remove(pos) => if r.lots > 1000 (1.U32.shl_wrap(20) + pos.to_u32_wrap() + 1, 1) else row_link(r, pos, 2)
}

row_link : Run, U64, U64 -> (U32, U32)
row_link = |r, pos, col| {
	tr = Dom.node(r.dom, r.tbody).kids.get(pos) ?? crash "row position"
	td = Dom.node(r.dom, tr).kids.get(col) ?? crash "td"
	a = Dom.node(r.dom, td).kids.get(0) ?? crash "a"
	Dom.click_target(r.dom, a) ?? crash "row handler"
}

## The reference's view of an action: new model and selection.
ref_apply : Run, Action -> (Jfb.Model, Str)
ref_apply = |r, action| match action {
	Button(id) => (ref_button(r.ref, id, r.small, r.lots), r.sel)
	Select(pos) => (r.ref, (r.ref.rows.get(pos) ?? crash "pos").id.to_str())
	Remove(pos) => (Jfb.remove(r.ref, (r.ref.rows.get(pos) ?? crash "pos").id), r.sel)
}

expected_rows : Jfb.Model, Str -> List(Str)
expected_rows = |m, sel| m.rows.map(|r| {
	k = r.id.to_str()
	"${k}:${r.label}:${if k == sel "danger" else ""}"
})

dom_rows : Run -> List(Str)
dom_rows = |r| Dom.node(r.dom, r.tbody).kids.map(|tr| {
	n = Dom.node(r.dom, tr)
	"${Dom.text_of(r.dom, n.kids.get(0) ?? 0)}:${Dom.text_of(r.dom, n.kids.get(1) ?? 0)}:${Dom.attr_of(n, "class")}"
})

## Exact derived evaluations the engine must run for this step (small sizes).
expected_evals : Jfb.Model, Str, Jfb.Model, Str, Bool -> U64
expected_evals = |before, sel0, after, sel1, model_write| {
	var $n = if model_write 1 else 0
	for r in after.rows {
		match before.rows.find_first(|o| o.id == r.id) {
			Err(_) => {
				$n = $n + 3
			}
			Ok(o) => {
				if o != r {
					$n = $n + 1
				}
			}
		}
	}
	if sel0 != sel1 {
		if before.rows.any(|o| o.id.to_str() == sel0) and after.rows.any(|o| o.id.to_str() == sel0) {
			$n = $n + 1
		}
		if after.rows.any(|o| o.id.to_str() == sel1) {
			$n = $n + 1
		}
	}
	$n
}

## One step: measured engine transaction, then the oracles.
step! : Run, Str, Action, Bool => Run
step! = |r, name, action, exact| {
	(node, h) = target_of(r, action)
	(next_ref, next_sel) = ref_apply(r, action)
	{ eng, dom, buf, ref, sel, buttons, tbody, small, lots } = r
	before_ids = if exact Dom.node(dom, tbody).kids.map(|tr| (Dom.text_of(dom, Dom.node(dom, tr).kids.get(0) ?? 0), tr)) else []
	e0 = Engine.evals(eng)
	w = Fuzz.start_measure!(name)
	(eng2, cmds) = Engine.take_cmds(Engine.event(eng, node, h), buf)
	_ = w.finish!()
	evals = Engine.evals(eng2) - e0
	fast = lots > 1000
	dom2 = if fast dom else Dom.apply(dom, cmds)
	r2 = { eng: eng2, dom: dom2, buf: cmds, ref: next_ref, sel: next_sel, buttons, tbody, small, lots }
	got = if fast [] else dom_rows(r2)
	want = if fast [] else expected_rows(next_ref, next_sel)
	if got != want {
		crash "DOM mismatch after ${name}: ${got.len().to_str()} rows vs ${want.len().to_str()}; first diff ${Str.inspect(got.sublist({ start: 0, len: 3 }))} vs ${Str.inspect(want.sublist({ start: 0, len: 3 }))}"
	}
	if exact {
		model_write = match action {
			Select(_) => False
			_ => True
		}
		want_evals = expected_evals(ref, sel, next_ref, next_sel, model_write)
		if evals != want_evals {
			crash "eval count after ${name}: ${evals.to_str()} vs expected ${want_evals.to_str()}"
		}
		for (k, tr) in Dom.node(dom2, tbody).kids.map(|t| (Dom.text_of(dom2, Dom.node(dom2, t).kids.get(0) ?? 0), t)) {
			match before_ids.find_first(|(k0, _)| k0 == k) {
				Ok((_, tr0)) => {
					if tr0 != tr {
						crash "row ${k} was recreated by ${name}"
					}
				}
				Err(_) => {}
			}
		}
	}
	r2
}

ops : List(Str)
ops = ["run", "runlots", "add", "update", "updone", "swaprows", "sel", "rm", "clear", "reverse", "rotate", "dropodd", "insmid", "shuffle", "same"]

run_program! : List(U8) => Fuzz.Outcome
run_program! = |program| {
	if program.len() > 128 {
		return Fuzz.reject
	}
	var $r = start(4, 24)
	var $i = 0.U64
	while $i + 1 < program.len() {
		op = (program.get($i) ?? 0).to_u64() % ops.len()
		arg = (program.get($i + 1) ?? 0).to_u64()
		$i = $i + 2
		name = ops.get(op) ?? crash "op"
		n = $r.ref.rows.len()
		if name == "sel" or name == "rm" {
			if n > 0 {
				action = if name == "sel" Select(arg % n) else Remove(arg % n)
				$r = step!($r, "step", action, True)
			}
		} else {
			$r = step!($r, "step", Button(name), True)
		}
	}
	Fuzz.keep
}

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	var $r = start(1000, n)
	steps : List((Str, Action))
	steps = [
		("create", Button("runlots")),
		("update-every-10th", Button("update")),
		("update-one", Button("updone")),
		("select", Select(3)),
		("select-other", Select(7)),
		("select-same", Select(7)),
		("swap", Button("swaprows")),
		("remove", Remove(2)),
		("equal-write-prune", Button("same")),
		("append-1k", Button("add")),
		("clear", Button("clear")),
		("create-1k", Button("run")),
		("replace-1k", Button("run")),
		("clear-1k", Button("clear")),
	]
	for (name, action) in steps {
		$r = step!($r, name, action, False)
	}
	Fuzz.keep
}

## Canary and nested-each as real programs: measured steps with exact
## derived-evaluation counts and exact command histograms.
Finder : [Btn(Str, U64), Input(U64), Id(Str)]

app_step! : T1.S, Str, Finder, U64, Str => T1.S
app_step! = |s, name, finder, want_evals, want_ops| {
	i = match finder {
		Btn(label, n) => T2.nth_button(s, label, n)
		Input(n) => T2.nth_input(s, n)
		Id(id) => Dom.by_attr(s.dom, "id", id) ?? crash "id"
	}
	{ eng, dom } = s
	(node, h) = Dom.click_target(dom, i) ?? crash "no handler"
	e0 = Engine.evals(eng)
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(Engine.event(eng, node, h), [])
	_ = w.finish!()
	evals = Engine.evals(a) - e0
	(d2, ops) = Dom.apply_ops(dom, c)
	got_ops = Dom.describe(ops)
	if evals != want_evals or got_ops != want_ops {
		crash "${name}: evals=${evals.to_str()} ${got_ops}, expected evals=${want_evals.to_str()} ${want_ops}"
	}
	{ eng: a, dom: d2 }
}

apps! : U64 => Fuzz.Outcome
apps! = |which| {
	if which == 0 {
		var $s = T1.start(Canary.main({}))
		$s = app_step!($s, "canary-details-row-b", Btn("Details", 2), 2, "REMOVE=1 ELEM=1 TEXTNODE=2")
		$s = app_step!($s, "canary-details-row-b-again", Btn("Details", 2), 1, "REMOVE=1 TEXTNODE=1")
		$s = app_step!($s, "canary-toggle-row-a", Input(1), 9, "REMOVE=2 ELEM=2 ATTR=4 TEXTNODE=2")
		$s = app_step!($s, "canary-select-row-b", Btn("Select", 1), 6, "ATTR=1")
		$s = app_step!($s, "canary-add", Id("add"), 12, "INST=1 ELEM=4 ATTR=5 TEXTNODE=8 LISTEN=3")
		$s = app_step!($s, "canary-remove-row-a", Btn("Remove", 1), 6, "REMOVE=1 SETTEXT=1")
		_ = $s
		Fuzz.keep
	} else {
		var $s = T1.start(NestedEach.main({}))
		$s = app_step!($s, "nested-add-g1", Btn("Add item", 0), 6, "INST=1")
		$s = app_step!($s, "nested-add-g2", Btn("Add item", 1), 6, "INST=1")
		$s = app_step!($s, "nested-add-g1-second", Btn("Add item", 0), 7, "INST=1")
		$s = app_step!($s, "nested-remove-g1-first", Btn("Remove", 0), 4, "REMOVE=1")
		$s = app_step!($s, "nested-remove-g2-outer-key", Btn("Remove", 1), 3, "REMOVE=1")
		if T2.html($s) != "<root><div><section><h2>Fruit</h2><button>Add item</button><ul><li>New in Fruit x1<button>Remove</button></li></ul></section><section><h2>Tools</h2><button>Add item</button><ul></ul></section></div></root>" {
			crash "nested-each final DOM"
		}
		Fuzz.keep
	}
}

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 0 {
		if size > 100_000 or size < 1000 {
			return Fuzz.reject
		}
		bench!(size)
	} else if mode == 2 {
		apps!(size)
	} else {
		run_program!(program)
	}
}

ex_bench : Str, U64 -> Fuzz.Example(Input)
ex_bench = |name, size| Fuzz.example({ name, revision: "1", make: || { mode: 0, size, program: [] } })

ex_prog : Str, List(U8) -> Fuzz.Example(Input)
ex_prog = |name, program| Fuzz.example({ name, revision: "1", make: || { mode: 1, size: 0, program } })

ex_app : Str, U64 -> Fuzz.Example(Input)
ex_app = |name, which| Fuzz.example({ name, revision: "1", make: || { mode: 2, size: which, program: [] } })

target = Fuzz.target_with!({
	name: "p2-each",
	examples: [
		ex_bench("bench-1k", 1000),
		ex_bench("bench-10k", 10000),
		ex_bench("bench-100k", 100000),
		ex_prog("run-select-update", [1, 0, 6, 3, 3, 0, 6, 5, 4, 0, 5, 0, 7, 2, 14, 0, 2, 0, 8, 0]),
		ex_prog("reorders", [1, 0, 9, 0, 6, 4, 10, 0, 11, 0, 12, 0, 13, 0, 13, 1, 7, 0, 9, 0, 0, 0, 13, 0]),
		ex_prog("select-remove-selected", [0, 0, 6, 1, 7, 1, 6, 0, 2, 0, 6, 5, 8, 0, 0, 0, 6, 2]),
		ex_app("canary", 0),
		ex_app("nested-each", 1),
	],
	generator: { mode: Fuzz.constant(1), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
