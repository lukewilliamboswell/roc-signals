app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import Dom
import Spec
import Form
import FormApp

## Native timing of the p4 form-builder: mount, then one transaction per
## event (Engine.event + take_cmds only; locating the node and decoding the
## DOM are outside the timed region). One line per sample: "n case nanos".

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
	for n in [20, 200] {
		mid = "f${((n // 2) // 4 * 4 + 1).to_str()}"
		var $run = 0.U64
		while $run < 11 {
			view = FormApp.main_with(schema_of(n))
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
			$s = timed!(n, $s, "edit-label", Label("Label ${mid}"), "input", "Renamed")
			$s = timed!(n, $s, "answer", Label("Answer ${mid}"), "input", "Ada")
			$s = timed!(n, $s, "toggle-required", Label("Required ${mid}"), "change", "true")
			_ = $s
			$run = $run + 1
		}
	}
	Ok({})
}
