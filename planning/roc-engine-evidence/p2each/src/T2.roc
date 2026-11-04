import Engine
import Dom
import T1
import Canary
import NestedEach

## Canary and nested-each scenarios run as real programs on the unified
## engine. Each step reports derived evaluations and the command histogram.
T2 := [].{
	Step : { s : T1.S, evals : U64, ops : Str }

	click : T1.S, U64 -> Step
	click = |s, i| {
		e0 = Engine.evals(s.eng)
		{ eng, dom } = s
		(node, h) = Dom.click_target(dom, i) ?? crash "no handler"
		(a, c) = Engine.take_cmds(Engine.event(eng, node, h), [])
		(d2, ops) = Dom.apply_ops(dom, c)
		{ s: { eng: a, dom: d2 }, evals: Engine.evals(a) - e0, ops: Dom.describe(ops) }
	}

	## The n-th (0-based) button whose label is `label`, depth-first.
	nth_button : T1.S, Str, U64 -> U64
	nth_button = |s, label, n| {
		all = T2.collect(s.dom, s.dom.root, |d, node| node.tag == "button" and Dom.text_of(d, node.kids.get(0) ?? 0) == label)
		all.get(n) ?? crash "no button ${label} #${n.to_str()}"
	}

	collect : Dom.Model, U64, (Dom.Model, Dom.DNode -> Bool) -> List(U64)
	collect = |dom, i, pred| {
		n = Dom.node(dom, i)
		var $out = if pred(dom, n) [i] else []
		for k in n.kids {
			$out = $out.concat(T2.collect(dom, k, pred))
		}
		$out
	}

	## The n-th checkbox (input) node.
	nth_input : T1.S, U64 -> U64
	nth_input = |s, n| (T2.collect(s.dom, s.dom.root, |_, node| node.tag == "input")).get(n) ?? crash "no input"

	show : Step -> Str
	show = |st| "evals=${st.evals.to_str()} ${st.ops}"

	html : T1.S -> Str
	html = |s| Dom.render(s.dom, s.dom.root)
}

## Canary: row-local state (Details) in row b is an exact sparse update; the
## conditional child inside a row; toggle, select, add and remove.
expect {
	s0 = T1.start(Canary.main({}))
	dbg T2.html(s0)
	# buttons labelled Details: 0 = featured, 1 = row a, 2 = row b
	d1 = T2.click(s0, T2.nth_button(s0, "Details", 2))
	dbg "details row b: ${T2.show(d1)}"
	dbg T2.html(d1.s)
	d2 = T2.click(d1.s, T2.nth_button(d1.s, "Details", 2))
	dbg "details row b again: ${T2.show(d2)}"
	t1 = T2.click(d2.s, T2.nth_input(d2.s, 1))
	dbg "toggle row a done: ${T2.show(t1)}"
	dbg T2.html(t1.s)
	sl = T2.click(t1.s, T2.nth_button(t1.s, "Select", 1))
	dbg "select row b: ${T2.show(sl)}"
	ad = T2.click(sl.s, Dom.by_attr(sl.s.dom, "id", "add") ?? crash "add")
	dbg "add task: ${T2.show(ad)}"
	rm = T2.click(ad.s, T2.nth_button(ad.s, "Remove", 1))
	dbg "remove row a: ${T2.show(rm)}"
	dbg T2.html(rm.s)
	d1.evals == 2 and d2.evals == 1
}

## Nested each: add an item in group g1 (only g1's inner each runs), then
## remove it with an inner-row handler that reads the outer (group) key.
expect {
	s0 = T1.start(NestedEach.main({}))
	a1 = T2.click(s0, T2.nth_button(s0, "Add item", 0))
	dbg "add item g1: ${T2.show(a1)}"
	a2 = T2.click(a1.s, T2.nth_button(a1.s, "Add item", 1))
	dbg "add item g2: ${T2.show(a2)}"
	a3 = T2.click(a2.s, T2.nth_button(a2.s, "Add item", 0))
	dbg "add 2nd item g1: ${T2.show(a3)}"
	dbg T2.html(a3.s)
	r1 = T2.click(a3.s, T2.nth_button(a3.s, "Remove", 0))
	dbg "remove first g1 item: ${T2.show(r1)}"
	dbg T2.html(r1.s)
	r2 = T2.click(r1.s, T2.nth_button(r1.s, "Remove", 1))
	dbg "remove g2 item: ${T2.show(r2)}"
	dbg T2.html(r2.s)
	T2.html(r2.s) == "<root><div><section><h2>Fruit</h2><button>Add item</button><ul><li>New in Fruit x1<button>Remove</button></li></ul></section><section><h2>Tools</h2><button>Add item</button><ul></ul></section></div></root>"
}
