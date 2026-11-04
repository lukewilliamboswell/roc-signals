app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import Dom
import Spec
import MdApp

## Native timing of the p4 markdown editor: mount, then one transaction per
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
	for n in [1, 10] {
		doc = Str.join_with(List.repeat(MdApp.sample_document, n), "\n\n")
		var $run = 0.U64
		while $run < 11 {
			view = MdApp.main_with(doc)
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
			$s = timed!(n, $s, "append-word", Role("button", "Append a word"), "click", "")
			$s = timed!(n, $s, "toggle-numbering", Label("Number the outline"), "change", "false")
			$s = timed!(n, $s, "reading-speed", Label("Reading speed"), "change", "300")
			$s = timed!(n, $s, "append-section", Role("button", "Append a section"), "click", "")
			_ = $s
			$run = $run + 1
		}
	}
	Ok({})
}
