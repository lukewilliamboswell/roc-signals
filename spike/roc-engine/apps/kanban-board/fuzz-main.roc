app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import Soak
import Kanban
import KanbanApp
import KanbanSpecs

## Kanban Board on the p4 engine.
## - "specs": every original .scm spec replayed through Spec.run.
## - "bench-N": N cards spread over the four columns (filter "", WIP "1"),
##   then measured single transactions on a card in the middle of Backlog.

specs! : {} => Fuzz.Outcome
specs! = |_| {
	for (name, steps) in KanbanSpecs.all {
		match Spec.run(KanbanApp.main({}), steps) {
			Ok(_) => {}
			Err(msg) => crash "spec ${name}: ${msg}"
		}
	}
	Fuzz.keep
}

board_of : U64 -> Kanban.Board
board_of = |n| {
	var $cards = []
	var $i = 0.U64
	while $i < n {
		column = match $i % 4 {
			0 => Backlog
			1 => InProgress
			2 => Review
			_ => Done
		}
		$cards = $cards.append({ title: "Card ${$i.to_str()}", column, flags: 0 })
		$i = $i + 1
	}
	{ cards: Kanban.canonical($cards), draft: "" }
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
	board = board_of(n)
	view = KanbanApp.main_with(board)
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	# The app's own derivation, outside the engine: the four column views.
	wj = Fuzz.start_measure!("app-columns_of")
	cols = KanbanApp.columns_of(board.cards, "", "1")
	_ = wj.finish!()
	_ = cols
	mid = "Card ${((n // 2) // 4 * 4).to_str()}"
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	$s = mstep!($s, "flag", Role("button", "Flag: ${mid}"), "click", "")
	$s = mstep!($s, "flag-again", Role("button", "Flag: ${mid}"), "click", "")
	$s = mstep!($s, "move-right", Role("button", "Move right: ${mid}"), "click", "")
	$s = mstep!($s, "move-left", Role("button", "Move left: ${mid}"), "click", "")
	$s = mstep!($s, "type-draft", Label("New card title"), "input", "Fresh card")
	$s = mstep!($s, "add-card", Role("button", "Add card"), "click", "")
	$s = mstep!($s, "wip-limit", Label("WIP limit"), "input", "3")
	$s = mstep!($s, "filter-one", Label("Filter cards"), "input", mid)
	$s = mstep!($s, "filter-clear", Label("Filter cards"), "input", "")
	$s = mstep!($s, "delete", Role("button", "Delete: ${mid}"), "click", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Spec.Step)
cycle = [Fill(Label("New card title"), "Soak card"), Click(Role("button", "Add card")), Click(Role("button", "Delete: Soak card"))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Spec.start(KanbanApp.main({})), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Spec.start(KanbanApp.main({})), 7, 10000, |s| s))
	(s1, evs) = Soak.triples(Spec.start(KanbanApp.main({})), cycle, |s| s)
	counts = Soak.replay!(s1.eng, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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
		if size > 2000 Fuzz.reject else bench!(size)
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
	name: "p4-kanban-board",
	examples: [
		ex("specs", 1, 0),
		ex("soak-10k", 3, 0),
		ex("bench-40", 0, 40),
		ex("bench-400", 0, 400),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
