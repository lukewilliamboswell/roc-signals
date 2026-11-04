app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Bench
import Jfb
import "regressions/index-backshift-wrap.bin" as index_backshift_wrap : List(U8)

# ======================================================================
# Reference model: plain lists, recomputed per operation. It shares only the
# application's label generator with the engine app, never engine code.

Ref : {
	rows : List(Bench.Item),
	sel : Try(U64, [None]),
	todos : List(Bench.Todo),
	next_id : U64,
	seed : U64,
	next_todo : U64,
}

ref_init : Ref
ref_init = { rows: [], sel: Err(None), todos: [], next_id: 1, seed: 42, next_todo: 1 }

ref_add : Ref, U64 -> Ref
ref_add = |ref, n| {
	var $rows = ref.rows
	var $id = ref.next_id
	var $seed = ref.seed
	var $i = 0.U64
	while $i < n {
		g = Bench.gen_label($seed)
		$seed = g.seed
		$rows = $rows.append({ id: $id, label: g.label, clicks: 0 })
		$id = $id + 1
		$i = $i + 1
	}
	{ ..ref, rows: $rows, next_id: $id, seed: $seed }
}

ref_swap : List(a), U64, U64 -> List(a)
ref_swap = |list, i, j| if i < list.len() and j < list.len() (list.swap(i, j) ?? list) else list

ref_apply : Ref, Bench.Msg -> Ref
ref_apply = |ref, msg| match msg {
	Run(n) => ref_add({ ..ref, rows: [] }, n)
	Add(n) => ref_add(ref, n)
	UpdateEvery10 => { ..ref, rows: ref.rows.map_with_index(|r, i| if i % 10 == 0 { ..r, label: "${r.label} !!!" } else r) }
	UpdateOne(k) => { ..ref, rows: ref.rows.map(|r| if r.id == k { ..r, label: "${r.label} !!!" } else r) }
	UpdateTwice(k) => { ..ref, rows: ref.rows.map(|r| if r.id == k { ..r, label: "${r.label} !!! !!!" } else r) }
	UpdateAndAdd(k) => ref_add({ ..ref, rows: ref.rows.map(|r| if r.id == k { ..r, label: "${r.label} !!!" } else r) }, 1)
	Select(k) => { ..ref, sel: Ok(k) }
	Deselect => { ..ref, sel: Err(None) }
	SwapRows => if ref.rows.len() > 998 { ..ref, rows: ref_swap(ref.rows, 1, 998) } else ref
	Swap(i, j) => { ..ref, rows: ref_swap(ref.rows, i, j) }
	Remove(k) => { ..ref, rows: ref.rows.drop_if(|r| r.id == k) }
	Clear => { ..ref, rows: [] }
	Touch(k) => { ..ref, rows: ref.rows.map(|r| if r.id == k { ..r, clicks: r.clicks + 1 } else r) }
	Relabel(k, l) => { ..ref, rows: ref.rows.map(|r| if r.id == k { ..r, label: l } else r) }
	AddTodo(t) => { ..ref, todos: ref.todos.append({ id: ref.next_todo, title: t, done: False }), next_todo: ref.next_todo + 1 }
	ToggleTodo(k) => { ..ref, todos: ref.todos.map(|t| if t.id == k { ..t, done: !t.done } else t) }
	RemoveTodo(k) => { ..ref, todos: ref.todos.drop_if(|t| t.id == k) }
	RenameTodo(k, title) => { ..ref, todos: ref.todos.map(|t| if t.id == k { ..t, title } else t) }
	ClearAll => { ..ref, rows: [], todos: [] }
}

is_sel : Try(U64, [None]), U64 -> Bool
is_sel = |sel, id| match sel {
	Ok(k) => k == id
	Err(None) => False
}

## Exact number of rank-1 derivations the engine must run for this step, and
## the (site, key) pairs allowed to be evaluated. Creates evaluate label and
## class; an item change evaluates both; a selection change evaluates class.
Expect : { evals : U64, changed : List((U32, U64)), counts_changed : U64 }

expected_work : Ref, Ref, Bench.Msg -> Expect
expected_work = |before, after, msg| {
	rebuilt = match msg {
		Run(_) => True
		_ => False
	}
	var $evals = 0.U64
	var $changed = []
	for r in after.rows {
		old = if rebuilt Err(NotFound) else before.rows.find_first(|o| o.id == r.id)
		n = match old {
			Err(_) => 2
			Ok(o) => if o != r 2 else if is_sel(before.sel, r.id) != is_sel(after.sel, r.id) 1 else 0
		}
		if n > 0 {
			$changed = $changed.append((1.U32, r.id))
		}
		$evals = $evals + n
	}
	for t in after.todos {
		n = match before.todos.find_first(|o| o.id == t.id) {
			Err(_) => 2
			Ok(o) => if o != t 2 else 0
		}
		if n > 0 {
			$changed = $changed.append((2.U32, t.id))
		}
		$evals = $evals + n
	}
	rows_changed = if before.rows.len() != after.rows.len() 1 else 0
	todos_changed = if before.todos.len() != after.todos.len() 1 else 0
	{ evals: $evals, changed: $changed, counts_changed: rows_changed + todos_changed }
}

# ======================================================================
# DOM simulator: an independent decoder of the command stream.

DNode : { live : Bool, key : U64, text : Str, cls : U8 }

## Two fixed sites: site 1 renders into parent 1, site 2 into parent 2.
Dom : { n1 : List(DNode), n2 : List(DNode), c1 : List(U32), c2 : List(U32), h1 : Str, h2 : Str, summary : Str }

dom_init : Dom
dom_init = { n1: [], n2: [], c1: [], c2: [], h1: "0", h2: "0", summary: "0" }

rd_u32 : List(U8), U64 -> U32
rd_u32 = |b, at| {
	b0 = (b.get(at) ?? crash "short command").to_u32()
	b1 = (b.get(at + 1) ?? crash "short command").to_u32()
	b2 = (b.get(at + 2) ?? crash "short command").to_u32()
	b3 = (b.get(at + 3) ?? crash "short command").to_u32()
	b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
}

rd_u64 : List(U8), U64 -> U64
rd_u64 = |b, at| rd_u32(b, at).to_u64() + rd_u32(b, at + 4).to_u64().shl_wrap(32)

rd_str : List(U8), U64 -> { s : Str, next : U64 }
rd_str = |b, at| {
	n = rd_u32(b, at).to_u64()
	bytes = b.sublist({ start: at + 4, len: n })
	if bytes.len() != n {
		crash "short string"
	}
	{ s: Str.from_utf8(bytes) ?? crash "bad utf8", next: at + 4 + n }
}

site_of : U32 -> U64
site_of = |node| node.shr_zf_wrap(24).to_u64()

slot_of : U32 -> U64
slot_of = |node| (node - node.shr_zf_wrap(24).shl_wrap(24)).to_u64()

live_in : List(DNode), U32 -> DNode
live_in = |nodes, node| {
	n = nodes.get(slot_of(node) - 1) ?? crash "unknown node"
	if !n.live {
		crash "command targets a dead node"
	}
	n
}

get_node : Dom, U32 -> DNode
get_node = |dom, node| if site_of(node) == 1 live_in(dom.n1, node) else if site_of(node) == 2 live_in(dom.n2, node) else crash "unknown site"

set_in : List(DNode), U32, DNode -> List(DNode)
set_in = |nodes, node, value| {
	slot = slot_of(node) - 1
	var $list = nodes
	while $list.len() <= slot {
		$list = $list.append({ live: False, key: 0, text: "", cls: 0 })
	}
	$list.set(slot, value) ?? crash "slot"
}

detach_in : List(U32), U32 -> List(U32)
detach_in = |kids, node| {
	pos = kids.find_first_index(|k| k == node) ?? crash "node not attached"
	kids.drop_at(pos)
}

place_in : List(U32), U32, U32 -> List(U32)
place_in = |kids, node, before| {
	if before == 0 {
		kids.append(node)
	} else {
		pos = kids.find_first_index(|k| k == before) ?? crash "MOVE before a detached node"
		split = kids.split_at(pos)
		split.before.append(node).concat(split.others)
	}
}

parse_u64 : Str -> U64
parse_u64 = |s| {
	var $n = 0.U64
	for c in s.iter_utf8() {
		if c < 48 or c > 57 {
			crash "key text is not decimal"
		}
		$n = $n * 10 + (c - 48).to_u64()
	}
	$n
}

dom_apply : Dom, List(U8) -> Dom
dom_apply = |dom0, b| {
	{ n1, n2, c1, c2, h1, h2, summary } = dom0
	var $n1 = n1
	var $n2 = n2
	var $c1 = c1
	var $c2 = c2
	var $h1 = h1
	var $h2 = h2
	var $sum = summary
	var $at = 0.U64
	while $at < b.len() {
		op = b.get($at) ?? 0
		if op == 1 {
			node = rd_u32(b, $at + 1)
			parent = rd_u32(b, $at + 5)
			tpl = rd_u32(b, $at + 9)
			kt = rd_str(b, $at + 13)
			key = parse_u64(kt.s)
			t = rd_str(b, kt.next)
			cls = b.get(t.next) ?? crash "short"
			value = { live: True, key, text: t.s, cls }
			if site_of(node) != parent.to_u64() or tpl.to_u64() != site_of(node) {
				crash "row created under a foreign parent or template"
			}
			if parent == 1 {
				match $n1.get(slot_of(node) - 1) {
					Ok(existing) => if existing.live crash "CREATE over a live node" else {}
					Err(_) => {}
				}
				$n1 = set_in($n1, node, value)
				$c1 = $c1.append(node)
			} else {
				match $n2.get(slot_of(node) - 1) {
					Ok(existing) => if existing.live crash "CREATE over a live node" else {}
					Err(_) => {}
				}
				$n2 = set_in($n2, node, value)
				$c2 = $c2.append(node)
			}
			$at = t.next + 1
		} else if op == 12 {
			node = rd_u32(b, $at + 1)
			t = rd_str(b, $at + 5)
			if node == Engine.summary_node {
				$sum = t.s
			} else if node == 16777216 {
				$h1 = t.s
			} else if node == 33554432 {
				$h2 = t.s
			} else {
				crash "SETTEXT on an unknown node"
			}
			$at = t.next
		} else if op == 2 {
			node = rd_u32(b, $at + 1)
			if (b.get($at + 5) ?? 0) != 1 {
				crash "TEXT on a non-label hole"
			}
			t = rd_str(b, $at + 6)
			if slot_of(node) == 0 {
				crash "TEXT on a site node"
			} else if site_of(node) == 1 {
				n = live_in($n1, node)
				if n.text == t.s {
					crash "TEXT command did not change the text"
				}
				$n1 = set_in($n1, node, { live: True, key: n.key, text: t.s, cls: n.cls })
			} else {
				n = live_in($n2, node)
				if n.text == t.s {
					crash "TEXT command did not change the text"
				}
				$n2 = set_in($n2, node, { live: True, key: n.key, text: t.s, cls: n.cls })
			}
			$at = t.next
		} else if op == 3 {
			node = rd_u32(b, $at + 1)
			if (b.get($at + 5) ?? 0) != 2 {
				crash "CLASS on a non-class hole"
			}
			c = b.get($at + 6) ?? crash "short"
			if site_of(node) == 1 {
				n = live_in($n1, node)
				if n.cls == c {
					crash "CLASS command did not change the class"
				}
				$n1 = set_in($n1, node, { live: True, key: n.key, text: n.text, cls: c })
			} else {
				n = live_in($n2, node)
				if n.cls == c {
					crash "CLASS command did not change the class"
				}
				$n2 = set_in($n2, node, { live: True, key: n.key, text: n.text, cls: c })
			}
			$at = $at + 7
		} else if op == 4 {
			node = rd_u32(b, $at + 1)
			before = rd_u32(b, $at + 5)
			if site_of(node) == 1 {
				_ = live_in($n1, node)
				$c1 = place_in(detach_in($c1, node), node, before)
			} else {
				_ = live_in($n2, node)
				$c2 = place_in(detach_in($c2, node), node, before)
			}
			$at = $at + 9
		} else if op == 5 {
			node = rd_u32(b, $at + 1)
			if site_of(node) == 1 {
				n = live_in($n1, node)
				$n1 = set_in($n1, node, { live: False, key: n.key, text: n.text, cls: n.cls })
				$c1 = detach_in($c1, node)
			} else {
				n = live_in($n2, node)
				$n2 = set_in($n2, node, { live: False, key: n.key, text: n.text, cls: n.cls })
				$c2 = detach_in($c2, node)
			}
			$at = $at + 5
		} else if op == 6 {
			parent = rd_u32(b, $at + 1)
			if rd_u32(b, $at + 5) != parent {
				crash "CLEAR names the wrong site"
			}
			if parent == 1 {
				$n1 = $n1.map(|n| { live: False, key: n.key, text: n.text, cls: n.cls })
				$c1 = []
			} else {
				$n2 = $n2.map(|n| { live: False, key: n.key, text: n.text, cls: n.cls })
				$c2 = []
			}
			$at = $at + 9
		} else {
			crash "unknown command opcode"
		}
	}
	{ n1: $n1, n2: $n2, c1: $c1, c2: $c2, h1: $h1, h2: $h2, summary: $sum }
}

## Compare the rendered DOM with the reference model.
check_dom : Dom, Ref -> {}
check_dom = |dom, ref| {
	if dom.c1.len() != ref.rows.len() {
		crash "row count differs from reference"
	}
	var $i = 0.U64
	for node in dom.c1 {
		n = get_node(dom, node)
		r = ref.rows.get($i) ?? crash "ref"
		cls = if is_sel(ref.sel, r.id) 1 else 0
		if n.key != r.id or n.text != r.label or n.cls != cls {
			crash "row differs from reference: ${Str.inspect(n)} vs ${Str.inspect(r)}"
		}
		$i = $i + 1
	}
	if dom.c2.len() != ref.todos.len() {
		crash "todo count differs from reference"
	}
	var $j = 0.U64
	for node in dom.c2 {
		n = get_node(dom, node)
		t = ref.todos.get($j) ?? crash "ref"
		cls = if t.done 2 else 0
		if n.key != t.id or n.text != t.title or n.cls != cls {
			crash "todo differs from reference"
		}
		$j = $j + 1
	}
	if dom.h1 != ref.rows.len().to_str() or dom.h2 != ref.todos.len().to_str() {
		crash "count text differs from reference"
	}
	if dom.summary != (ref.rows.len() + ref.todos.len()).to_str() {
		crash "summary differs from reference"
	}
	{}
}

node_at : Dom, U64, U64 -> Try(U32, [None])
node_at = |dom, parent, pos| {
	kids = if parent == 1 dom.c1 else dom.c2
	if kids.is_empty() {
		Err(None)
	} else {
		Ok(kids.get(pos % kids.len()) ?? crash "pos")
	}
}

key_at : Dom, U64, U64 -> Try(U64, [None])
key_at = |dom, parent, pos| match node_at(dom, parent, pos) {
	Ok(node) => Ok(get_node(dom, node).key)
	Err(None) => Err(None)
}

# ======================================================================
# One step: input to the engine, message for the reference model.

Step : { input : Engine.Input(Bench.Msg), msg : Bench.Msg }

decode_step : Dom, Ref, U8, U8 -> Try(Step, [Skip])
decode_step = |dom, ref, op, arg| {
	a = arg.to_u64()
	m = |msg| Ok({ input: Msg(msg), msg })
	fire = |parent, handler, mk| match node_at(dom, parent, a) {
		Ok(node) => Ok({ input: Fire(node, handler), msg: mk(get_node(dom, node).key) })
		Err(None) => Err(Skip)
	}
	match op % 20 {
		0 => m(Run(a % 24))
		1 => m(Add(a % 12))
		2 => m(UpdateEvery10)
		3 => match key_at(dom, 1, a) {
			Ok(k) => m(UpdateOne(k))
			Err(None) => Err(Skip)
		}
		4 => fire(1, 1, |k| Select(k))
		5 => m(Deselect)
		6 => m(Swap(a % 16, a.shr_zf_wrap(4)))
		7 => fire(1, 2, |k| Remove(k))
		8 => m(Clear)
		9 => match key_at(dom, 1, a) {
			Ok(k) => m(Touch(k))
			Err(None) => Err(Skip)
		}
		10 => match key_at(dom, 1, a) {
			Ok(k) => {
				same = (ref.rows.find_first(|r| r.id == k) ?? crash "ref").label
				m(Relabel(k, same))
			}
			Err(None) => Err(Skip)
		}
		11 => match key_at(dom, 1, a) {
			Ok(k) => m(Relabel(k, if a % 2 == 0 "short" else "a relabelled row that needs the heap"))
			Err(None) => Err(Skip)
		}
		12 => m(AddTodo(if a % 2 == 0 "todo ${a.to_str()}" else "a todo with a long heap title ${a.to_str()}"))
		13 => fire(2, 1, |k| ToggleTodo(k))
		14 => fire(2, 2, |k| RemoveTodo(k))
		15 => match key_at(dom, 2, a) {
			Ok(k) => m(RenameTodo(k, if a % 3 == 0 "renamed" else (ref.todos.find_first(|t| t.id == k) ?? crash "ref").title))
			Err(None) => Err(Skip)
		}
		16 => m(ClearAll)
		18 => match key_at(dom, 1, a) {
			Ok(k) => m(UpdateTwice(k))
			Err(None) => Err(Skip)
		}
		19 => match key_at(dom, 1, a) {
			Ok(k) => m(UpdateAndAdd(k))
			Err(None) => Err(Skip)
		}
		_ => m(Select(a % 40))
	}
}

## Emit the engine's logical trace as fuzz marks, classifying each rank-1
## evaluation as allowed (changed row) or forbidden (unchanged row).
replay_trace! : List(Engine.Ev), List((U32, U64)) => {}
replay_trace! = |log, changed| {
	for ev in log {
		match ev.kind {
			Eval => {
				if ev.rank == 1 {
					if changed.contains((ev.site, ev.key)) {
						Fuzz.mark!("eval-r1")
					} else {
						Fuzz.mark!("eval-r1-unchanged-row")
					}
				} else if ev.rank == 2 {
					Fuzz.mark!("eval-r2")
				} else {
					Fuzz.mark!("eval-r3")
				}
			}
			Prune => {}
			SourcePrune => {}
		}
	}
}

# ======================================================================
# Inputs

Input : { mode : U8, size : U64, program : List(U8) }

run_program! : List(U8) => Fuzz.Outcome
run_program! = |program| {
	if program.len() > 256 {
		return Fuzz.reject
	}
	var $app = Bench.init(True)
	var $dom = dom_init
	var $ref = ref_init
	var $i = 0.U64
	while $i + 1 < program.len() {
		op = program.get($i) ?? 0
		arg = program.get($i + 1) ?? 0
		$i = $i + 2
		match decode_step($dom, $ref, op, arg) {
			Err(Skip) => {}
			Ok(step) => {
				next_ref = ref_apply($ref, step.msg)
				exp = expected_work($ref, next_ref, step.msg)
				w = Fuzz.start_measure!("step")
				rules = [Count("eval-r1", exp.evals), Forbidden("eval-r1-unchanged-row"), Count("eval-r3", if exp.counts_changed > 0 1 else 0)]
				ordered = if exp.evals > 0 and exp.counts_changed > 0 [Before("eval-r1", "eval-r2"), Before("eval-r2", "eval-r3")] else if exp.counts_changed > 0 [Before("eval-r2", "eval-r3")] else []
				Fuzz.trace_rules!(rules.concat(ordered))
				$app = $app.apply(step.input, Bench.update)
				replay_trace!($app.trace(), exp.changed)
				_ = w.finish!()
				$dom = dom_apply($dom, $app.commands())
				$ref = next_ref
				check_dom($dom, $ref)
			}
		}
	}
	Fuzz.keep
}

## Measured benchmark script at one size. Tracing is off; every engine call is
## a separate region; the DOM is checked against the reference at the end.
bench! : U64 => Fuzz.Outcome
bench! = |n| {
	var $app = Bench.init(False)
	var $dom = dom_init
	var $ref = ref_init
	steps : List((Str, U8, U64))
	steps = [
		("create", 0, 0),
		("update-every-10th", 2, 0),
		("update-one", 3, 5),
		("select", 4, 3),
		("select-other", 4, 7),
		("select-same", 4, 7),
		("swap", 19, 0),
		("remove", 7, 2),
		("touch-derived-prune", 9, 4),
		("relabel-equal-source-prune", 10, 4),
		("todo-add", 12, 1),
		("todo-add-2", 12, 2),
		("todo-toggle", 13, 0),
		("append-1k", 20, 0),
		("clear", 8, 0),
	]
	var $si = 0.U64
	while $si < steps.len() {
		(name, op, arg) = steps.get($si) ?? crash "step"
		$si = $si + 1
		# Decode twice so the engine's input does not share its message with the
		# reference model's copy (see the report: sharing the message value made
		# the engine copy its row column).
		decode = || if op == 0 {
			Ok({ input: Msg(Run(n)), msg: Run(n) })
		} else if op == 19 {
			Ok({ input: Msg(SwapRows), msg: SwapRows })
		} else if op == 20 {
			Ok({ input: Msg(Add(1000)), msg: Add(1000) })
		} else {
			decode_step($dom, $ref, op, arg.to_u8_wrap())
		}
		step = decode()
		fresh = decode()
		match (step, fresh) {
			(Err(Skip), _) => crash "bench step could not be decoded"
			(_, Err(Skip)) => crash "bench step could not be decoded"
			(Ok({ input: _, msg }), Ok({ input, msg: _ })) => {
				$ref = ref_apply($ref, msg)
				w = Fuzz.start_measure!(name)
				$app = $app.apply(input, Bench.update)
				_ = w.finish!()
				$dom = dom_apply($dom, $app.commands())
				if name == "create" or name == "clear" {
					check_dom($dom, $ref)
				}
			}
		}
	}
	check_dom($dom, $ref)
	Fuzz.keep
}

## The jfb app through the host entry (`State.step` with the command buffer
## handed back each call), firing the same (node, handler) events the browser
## sends. Used to compare native allocation counts with the Wasm host's.
jfb! : {} => Fuzz.Outcome
jfb! = |_| {
	(s0, b0) = Jfb.init({}).take_commands()
	var $s = s0
	var $b = b0
	steps : List((Str, U32, U32))
	steps = [
		("jfb-create-10k", 1000, 1),
		("jfb-update-every-10th", 1000, 3),
		("jfb-select", 16777221, 1),
		("jfb-select-other", 16777223, 1),
		("jfb-swap", 1000, 5),
		("jfb-remove", 16777219, 2),
		("jfb-append-1k", 1000, 2),
		("jfb-clear", 1000, 4),
		("jfb-create-1k", 1000, 0),
		("jfb-replace-1k", 1000, 0),
		("jfb-clear-1k", 1000, 4),
	]
	for (name, node, handler) in steps {
		w = Fuzz.start_measure!(name)
		(s1, b1) = $s.step($b, Fire(node, handler), Jfb.update)
		_ = w.finish!()
		$s = s1
		$b = b1
	}
	if $s.stale() != 0 {
		crash "jfb step was stale"
	}
	Fuzz.keep
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 9 {
		return Fuzz.reject
	}
	if mode == 2 {
		return jfb!({})
	}
	if mode == 0 {
		if size > 100_000 or size < 1000 {
			return Fuzz.reject
		}
		bench!(size)
	} else {
		run_program!(program)
	}
}

ex_bench : Str, U64 -> Fuzz.Example(Input)
ex_bench = |name, size| Fuzz.example({ name, revision: "1", make: || { mode: 0, size, program: [] } })

ex_prog : Str, List(U8) -> Fuzz.Example(Input)
ex_prog = |name, program| Fuzz.example({ name, revision: "1", make: || { mode: 1, size: 0, program } })

target = Fuzz.target_with!({
	name: "p1-engine",
	examples: [
		Fuzz.example({ name: "jfb-host-path", revision: "1", make: || { mode: 2, size: 0, program: [] } }),
		ex_bench("bench-1k", 1000),
		ex_bench("bench-10k", 10000),
		ex_bench("bench-100k", 100000),
		ex_prog("run-select-update", [0, 20, 4, 3, 2, 0, 4, 5, 9, 1, 10, 2, 7, 0, 6, 33, 12, 0, 13, 0, 16, 0]),
		ex_prog("todos", [12, 1, 12, 2, 13, 0, 15, 0, 15, 3, 14, 1, 0, 5, 16, 0]),
		ex_prog("update-twice", [0, 10, 18, 3, 4, 2, 18, 2, 9, 2, 11, 3, 10, 3]),
		ex_prog("update-and-add", [0, 6, 19, 2, 4, 1, 19, 1, 12, 0, 16, 0]),
		Fuzz.saved({ name: "index-backshift-wrap", revision: "1", bytes: index_backshift_wrap }),
	],
	generator: { mode: Fuzz.constant(1), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 96) }.Fuzz,
	test!,
	show: Str.inspect,
})

upd2 : Bench.Tx, Bench.Msg -> Bench.Tx
upd2 = |tx, msg| match msg {
	Touch(k) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, k, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
	_ => tx
}

upd4 : Bench.Tx, Bench.Msg -> Bench.Tx
upd4 = |tx, msg| match msg {
	Touch(k) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, k, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
	ClearAll => {
		{ model, sites, ctx } = tx
		{ left, right } = sites
		(l, c1) = left.clear(ctx)
		(r, c2) = right.clear(c1)
		{ model, sites: Engine.Both.new(l, r), ctx: c2 }
	}
	_ => tx
}

upd5 : Bench.Tx, Bench.Msg -> Bench.Tx
upd5 = |tx, msg| match msg {
	Touch(k) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, k, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
	Relabel(key, label) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, key, |i| { id: i.id, label, clicks: i.clicks }))
	AddTodo(title) => Bench.on_right(tx, |s, m, c| Bench.done(s.push({ id: m.next_todo, title, done: False }, c), m))
	UpdateEvery10 => Bench.on_left(tx, |s, m, c| Bench.update_every_10(s, m, c))
	_ => tx
}

upd6 : Bench.Tx, Bench.Msg -> Bench.Tx
upd6 = |tx, msg| match msg {
	Touch(k) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, k, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
	SwapRows => Bench.on_left(tx, |s, m, c| if s.len() > 998 Bench.done(s.swap_positions(1, 998, c), m) else { site: s, model: m, ctx: c })
	_ => tx
}

upd7 : Bench.Tx, Bench.Msg -> Bench.Tx
upd7 = |tx, msg| match msg {
	Touch(k) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, k, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
	Run(n) => Bench.on_left(tx, |s, m, c| Bench.run_rows(s, m, c, n))
	_ => tx
}

upd3 : Bench.Tx, Bench.Msg -> Bench.Tx
upd3 = |tx, msg| match msg {
	Touch(k) => touch_only(tx, k)
	_ => tx
}

touch_only : Bench.Tx, U64 -> Bench.Tx
touch_only = |tx, key| {
	{ model, sites, ctx } = tx
	{ left, right } = sites
	item = left.get(key) ?? crash "key"
	(s, c) = left.set(key, { id: item.id, label: item.label, clicks: item.clicks + 1 }, ctx)
	{ model, sites: Engine.Both.new(s, right), ctx: c }
}
