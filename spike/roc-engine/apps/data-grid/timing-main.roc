app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import Dom
import Spec
import GridData
import GridApp

## Native timing of the p4 data grid: mount, then one transaction per
## event (Engine.event + take_cmds only; locating the node and decoding the
## DOM are outside the timed region). One line per sample: "n case nanos".

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
	for n in [1200, 12000] {
		data = GridData.generate_rows(n)
		var $run = 0.U64
		while $run < 11 {
			view = GridApp.main_with(data)
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
			$s = timed!(n, $s, "note-edit", Label("Note for Node-0003"), "input", "needs review")
			$s = timed!(n, $s, "select-row", Label("Select Node-0004"), "change", "true")
			$s = timed!(n, $s, "next-page", Role("button", "Next page"), "click", "")
			$s = timed!(n, $s, "sort-score", Role("button", "Sort by score"), "click", "")
			$s = timed!(n, $s, "filter", Label("Filter"), "input", "Node-1")
			_ = $s
			$run = $run + 1
		}
	}
	Ok({})
}
