app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import ControlsApp
import ManyApp

## Native tests of focus references and focus/blur events (apps/controls):
## Focus/SelectText/Blur effects resolve their reference at the end of the
## turn into one FOCUS command naming the referenced element; a missing
## reference emits nothing and is counted stale; focus/blur handlers receive
## the control's value as payload.

fire! : Spec.S, Spec.Loc, Str, Str => (Spec.S, List(Dom.FxCmd))
fire! = |s, loc, ev, payload| {
	i = Spec.find(s.dom, loc) ?? crash "no ${Spec.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "no ${ev} handler on ${Spec.show_loc(loc)}"
	(a, c) = Engine.take_cmds(Engine.event(s.eng, node, h, payload), [])
	(d2, _, fx) = Dom.apply_fx(s.dom, c)
	({ eng: a, dom: d2, steps: s.steps + 1 }, fx)
}

node_of : Spec.S, Spec.Loc -> U32
node_of = |s, loc| {
	i = Spec.find(s.dom, loc) ?? crash "no ${Spec.show_loc(loc)}"
	n = Dom.node(s.dom, i)
	n.rn
}

expect_fx! : Str, List(Dom.FxCmd), List(Dom.FxCmd) => {}
expect_fx! = |what, got, want| if got != want crash "${what}: ${Str.inspect(got)}, expected ${Str.inspect(want)}" else {}

focus! : {} => Fuzz.Outcome
focus! = |_| {
	s0 = Spec.start(ControlsApp.main({}))
	plain = node_of(s0, Label("Plain"))
	upper = node_of(s0, Label("Upper"))
	(s1, f1) = fire!(s0, Role("button", "Focus upper"), "click", "")
	expect_fx!("focus upper", f1, [Focus(1, upper)])
	(s2, f2) = fire!(s1, Role("button", "Select plain"), "click", "")
	expect_fx!("select plain", f2, [Focus(3, plain)])
	(s3, f3) = fire!(s2, Role("button", "Blur plain"), "click", "")
	expect_fx!("blur plain", f3, [Focus(2, plain)])
	stale0 = Engine.fx_stats(s3.eng).stale
	(s4, f4) = fire!(s3, Role("button", "Focus missing"), "click", "")
	expect_fx!("missing ref", f4, [])
	if Engine.fx_stats(s4.eng).stale != stale0 + 1 {
		crash "missing ref not counted stale"
	}
	(s5, _) = fire!(s4, Label("Plain"), "focus", "hello world")
	(s6, _) = fire!(s5, Label("Plain"), "blur", "hello there")
	log = Dom.text_of(s6.dom, Spec.find(s6.dom, TestId("log")) ?? crash "no log")
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
	s0 = Spec.start(ManyApp.main(n))
	click = |s, loc| Spec.one(s, Click(loc)) ?? crash "click ${Spec.show_loc(loc)}"
	log = |s| Dom.text_of(s.dom, Spec.find(s.dom, TestId("log")) ?? crash "no log")
	s1 = click(s0, Label("g0r4999-b"))
	if log(s1) != "g0r4999-b" {
		crash "first click: ${log(s1)}"
	}
	s2 = click(click(s1, Role("button", "Shrink")), Role("button", "Grow"))
	match Spec.find(s2.dom, Label("g0r0-a")) {
		Ok(_) => crash "old rows still present"
		Err(_) => {}
	}
	s3 = click(click(s2, Label("g1r4999-a")), Label("g1r0-b"))
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
	test!: |{ mode, pad }| if mode == 1 many!(5000 + pad.to_u64()) else focus!({}),
	show: Str.inspect,
})
