import Engine
import Dom
import Jfb

## Driver helpers for engine tests: a running app plus its decoded DOM.
T1 := [].{
	S : { eng : Engine.App, dom : Dom.Model }

	start : Engine.Elem(Engine.Root) -> S
	start = |view| {
		(a, c) = Engine.take_cmds(Engine.mount(view), [])
		{ eng: a, dom: Dom.apply(Dom.new({}), c) }
	}

	click_node : S, U64 -> (S, List(U8))
	click_node = |{ eng, dom }, i| {
		(node, h) = Dom.click_target(dom, i) ?? crash "no handler at node"
		(a, c) = Engine.take_cmds(Engine.event(eng, node, h), [])
		({ eng: a, dom: Dom.apply(dom, c) }, c)
	}

	click_id : S, Str -> S
	click_id = |s, id| T1.click_node(s, Dom.by_attr(s.dom, "id", id) ?? crash "no element ${id}").0

	tbody : S -> List(U64)
	tbody = |s| Dom.node(s.dom, Dom.by_attr(s.dom, "id", "tbody") ?? crash "tbody").kids

	row_summary : S -> List(Str)
	row_summary = |s| T1.tbody(s).map(|tr| {
		n = Dom.node(s.dom, tr)
		"${Dom.text_of(s.dom, n.kids.get(0) ?? 0)}:${Dom.text_of(s.dom, n.kids.get(1) ?? 0)}:${Dom.attr_of(n, "class")}"
	})

	## Click the select (col 1) or remove (col 2) link of the row with this id.
	click_row : S, Str, U64 -> S
	click_row = |s, id, col| {
		tr = T1.tbody(s).find_first(|r| Dom.text_of(s.dom, Dom.node(s.dom, r).kids.get(0) ?? 0) == id) ?? crash "no row ${id}"
		td = Dom.node(s.dom, tr).kids.get(col) ?? crash "td"
		a = Dom.node(s.dom, td).kids.get(0) ?? crash "a"
		T1.click_node(s, a).0
	}
}

## Expected DOM rows for a reference model and selection.
expected : Jfb.Model, Str -> List(Str)
expected = |m, sel| m.rows.map(|r| {
	k = r.id.to_str()
	"${k}:${r.label}:${if k == sel "danger" else ""}"
})

## One scripted session checked against the reference after every step.
expect {
	var $s = T1.start(Jfb.view({}))
	var $m = Jfb.initial
	var $sel = ""
	var $ok = True
	steps = ["run", "sel:3", "sel:7", "update", "swaprows", "rm:2", "add", "rm:7", "sel:1001", "swaprows", "run", "sel:2500", "rm:2500", "sel:2001", "clear", "add", "update", "clear", "clear"]
	for st in steps {
		if st == "run" {
			$s = T1.click_id($s, "run")
			$m = Jfb.run($m, 1000)
		} else if st == "add" {
			$s = T1.click_id($s, "add")
			$m = Jfb.add_rows($m, 1000)
		} else if st == "update" {
			$s = T1.click_id($s, "update")
			$m = Jfb.update_every_10($m)
		} else if st == "swaprows" {
			$s = T1.click_id($s, "swaprows")
			$m = Jfb.swap_rows($m)
		} else if st == "clear" {
			$s = T1.click_id($s, "clear")
			$m = Jfb.clear($m)
		} else if st.starts_with("sel:") {
			k = st.drop_prefix("sel:")
			$s = T1.click_row($s, k, 1)
			$sel = k
		} else {
			k = st.drop_prefix("rm:")
			$s = T1.click_row($s, k, 2)
			$m = Jfb.remove($m, $m.rows.find_first(|r| r.id.to_str() == k).map_ok(|r| r.id) ?? 0)
		}
		got = T1.row_summary($s)
		want = expected($m, $sel)
		if got != want {
			dbg st
			dbg got.len()
			dbg want.len()
			dbg got.sublist({ start: 0, len: 4 })
			dbg want.sublist({ start: 0, len: 4 })
			$ok = False
		}
	}
	$ok
}
