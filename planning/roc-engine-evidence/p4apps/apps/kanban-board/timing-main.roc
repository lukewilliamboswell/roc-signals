app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import Dom
import Spec
import Kanban
import KanbanApp

## Native timing of the p4 kanban board: mount, then one transaction per
## event (Engine.event + take_cmds only; locating the node and decoding the
## DOM are outside the timed region). One line per sample: "n case nanos".

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

timed! : U64, Spec.S, Str, Spec.Loc, Str, Str => Spec.S
timed! = |n, s, name, loc, ev, payload| {
	i = Spec.find(s.dom, loc) ?? crash "${name}: no ${Spec.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "${name}: no handler"
	{ eng, dom, steps } = s
	t0 = Monotonic.now!()
	(a, c) = Engine.take_cmds(Engine.event(eng, node, h, payload), [])
	d = Monotonic.since(Monotonic.now!(), t0)
	_ = Stdout.line!("${n.to_str()} ${name} ${d.to_nanos().to_str()}")
	{ eng: a, dom: Dom.apply(dom, c), steps: steps + 1 }
}

main! : List(_) => Try({}, [Exit(I32)])
main! = |_args| {
	for n in [40, 400] {
		mid = "Card ${((n // 2) // 4 * 4).to_str()}"
		var $run = 0.U64
		while $run < 11 {
			view = KanbanApp.main_with(board_of(n))
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
			$s = timed!(n, $s, "flag", Role("button", "Flag: ${mid}"), "click", "")
			$s = timed!(n, $s, "move-right", Role("button", "Move right: ${mid}"), "click", "")
			$s = timed!(n, $s, "type-draft", Label("New card title"), "input", "Fresh card")
			$s = timed!(n, $s, "wip-limit", Label("WIP limit"), "input", "3")
			_ = $s
			$run = $run + 1
		}
	}
	Ok({})
}
