app [target] {
	pf: platform "../../../platform/test.roc",
	ts: "../../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.SpecRunner
import ControlsApp
import ManyApp

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Engine.App, dom : Dom.Model, steps : U64 }

start : Engine.Elem(Engine.Root) -> S
start = |view| {
	(a, c) = Engine.take_cmds(Engine.mount(view), [])
	{ eng: a, dom: Dom.apply(Dom.new({}), c), steps: 0 }
}

## Native tests of focus references and focus/blur events (apps/controls):
## Focus/SelectText/Blur effects resolve their reference at the end of the
## turn into one FOCUS command naming the referenced element; a missing
## reference emits nothing and is counted stale; focus/blur handlers receive
## the control's value as payload.

fire! : S, Scm.Loc, Str, Str => (S, List(Dom.FxCmd))
fire! = |s, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "no ${Scm.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "no ${ev} handler on ${Scm.show_loc(loc)}"
	(a, c) = Engine.take_cmds(Engine.event(s.eng, node, h, payload), [])
	(d2, _, fx) = Dom.apply_fx(s.dom, c)
	({ eng: a, dom: d2, steps: s.steps + 1 }, fx)
}

node_of : S, Scm.Loc -> U32
node_of = |s, loc| {
	i = SpecRunner.find(s.dom, loc) ?? crash "no ${Scm.show_loc(loc)}"
	n = Dom.node(s.dom, i)
	n.rn
}

expect_fx! : Str, List(Dom.FxCmd), List(Dom.FxCmd) => {}
expect_fx! = |what, got, want| if (got != want) crash "${what}: ${Str.inspect(got)}, expected ${Str.inspect(want)}" else {}

focus! : {} => Fuzz.Outcome
focus! = |_| {
	s0 = start(ControlsApp.main({}))
	plain = node_of(s0, Label("Plain"))
	upper = node_of(s0, Label("Upper"))
	(s1, f1) = fire!(s0, Role({ role: "button", name: "Focus upper" }), "click", "")
	expect_fx!("focus upper", f1, [Focus(1, upper)])
	(s2, f2) = fire!(s1, Role({ role: "button", name: "Select plain" }), "click", "")
	expect_fx!("select plain", f2, [Focus(3, plain)])
	(s3, f3) = fire!(s2, Role({ role: "button", name: "Blur plain" }), "click", "")
	expect_fx!("blur plain", f3, [Focus(2, plain)])
	stale0 = Engine.fx_stats(s3.eng).stale
	(s4, f4) = fire!(s3, Role({ role: "button", name: "Focus missing" }), "click", "")
	expect_fx!("missing ref", f4, [])
	if Engine.fx_stats(s4.eng).stale != stale0 + 1 {
		crash "missing ref not counted stale"
	}
	(s5, _) = fire!(s4, Label("Plain"), "focus", "hello world")
	(s6, _) = fire!(s5, Label("Plain"), "blur", "hello there")
	log = Dom.text_of(s6.dom, SpecRunner.find(s6.dom, TestId("log")) ?? crash "no log")
	if log != "focus:hello world|blur:hello there" {
		crash "focus/blur payloads: ${log}"
	}
	Fuzz.keep
}

## More than 4,095 each sites (5,001 at mount; 5,000 rows each with a
## nested each), shrunk and regrown with new keys so site and node ids are
## recycled; clicks deep in the newest rows must route to the right row.
many! : U64 => Fuzz.Outcome
many! = |n| {
	s0 = start(ManyApp.main(n))
	click! = |s, loc| fire!(s, loc, "click", "").0
	log = |s| Dom.text_of(s.dom, SpecRunner.find(s.dom, TestId("log")) ?? crash "no log")
	s1 = click!(s0, Label("g0r4999-b"))
	if log(s1) != "g0r4999-b" {
		crash "first click: ${log(s1)}"
	}
	s2 = click!(click!(s1, Role({ role: "button", name: "Shrink" })), Role({ role: "button", name: "Grow" }))
	match SpecRunner.find(s2.dom, Label("g0r0-a")) {
		Ok(_) => crash "old rows still present"
		Err(_) => {}
	}
	s3 = click!(click!(s2, Label("g1r4999-a")), Label("g1r0-b"))
	if log(s3) != "g0r4999-b|g1r4999-a|g1r0-b" {
		crash "after regrow: ${log(s3)}"
	}
	Fuzz.keep
}

Input : { mode : U8, pad : U8 }

target = Fuzz.target_with!({
	name: "controls",
	examples: [
		Fuzz.example({ name: "focus", revision: "1", make: || { mode: 0, pad: 0 } }),
		Fuzz.example({ name: "many-sites", revision: "1", make: || { mode: 1, pad: 0 } }),
	],
	generator: { mode: Fuzz.constant(0), pad: Fuzz.constant(0) }.Fuzz,
	test!: |{ mode, pad }| if (mode == 1) many!(5000 + pad.to_u64()) else focus!({}),
	show: Str.inspect,
})
