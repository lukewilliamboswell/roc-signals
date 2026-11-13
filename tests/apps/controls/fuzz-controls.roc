app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Engine
import pf.Dom
import pf.Scm
import pf.SpecRunner
import ControlsApp
import ManyApp

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Core.App, dom : Dom.Model, steps : U64 }

start : Engine.Elem(Engine.Root) -> S
start = |view| {
	(a, c) = Core.take_cmds(Core.mount(view), [])
	dom = Dom.apply(Dom.new({}), c)
	settled(a, dom, { eng: a, dom, steps: 0 })
}

## The settle check: a pass over every layer of the engine (on a discarded
## copy) must emit nothing, or the last call left a reader stale.
settled : Core.App, Dom.Model, a -> a
settled = |eng, dom, value|
	match Core.settled(eng) {
		Ok(_) => value
		Err({ cmds, note }) => crash "a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(dom, cmds).1)} ${note}"
	}

## Native tests of focus references and focus/blur events (apps/controls):
## Focus/SelectText/Blur effects resolve their reference at the end of the
## turn into one FOCUS command naming the referenced element; a missing
## reference emits nothing and is counted stale; focus/blur handlers receive
## the control's value as payload. Every call must leave the engine settled:
## a pass over every layer emits nothing (`Core.settled`).

fire! : S, Scm.Loc, Str, Str => (S, List(Dom.FxCmd))
fire! = |s, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "no ${Scm.show_loc(loc)}"
	target = Dom.target(s.dom, i, ev, Bool.True) ?? crash "no ${ev} handler on ${Scm.show_loc(loc)}"
	(a, c) = Core.take_cmds(Core.event(s.eng, target.node, target.handler, payload), [])
	(d2, _, fx) = Dom.apply_fx(s.dom, c)
	settled(a, d2, ({ eng: a, dom: d2, steps: s.steps + 1 }, fx))
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
	stale0 = Core.fx_stats(s3.eng).stale
	(s4, f4) = fire!(s3, Role({ role: "button", name: "Focus missing" }), "click", "")
	expect_fx!("missing ref", f4, [])
	if Core.fx_stats(s4.eng).stale != stale0 + 1 {
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

## Generated reorder, disposal, recreation and rename histories are checked
## against a reference model of which row owns each address. The runner
## applies FOCUS commands, so each step checks the focused element, as well
## as propagation and command counters, rather than only an emitted command.
reference_focus! : List(U8) => Fuzz.Outcome
reference_focus! = |events| {
	program = Core.driver(ControlsApp.program)
	var $s = SpecRunner.start(program, { name: "reference history", setup: [], steps: [] }) ?? crash "reference history did not mount"
	var $has_a = True
	var $names = PerRow
	var $selected = "a"
	for event in events {
		button = |name| Role({ role: "button", name })
		operation = event % 11
		action = match operation {
			0 => "Focus row a"
			1 => "Focus row b"
			2 => "Reverse reference rows"
			3 => "Remove row a"
			4 => "Restore reference rows"
			5 => "Use selected reference"
			6 => "Select row b"
			7 => "Clear reference names"
			8 => "Focus current row"
			9 => "Focus empty name"
			_ => ""
		}
		expected = match operation {
			0 if $has_a and $names == PerRow => Label("Row a")
			1 if $names == PerRow => Label("Row b")
			8 if $names == Selected and ($selected == "b" or $has_a) => Label("Row ${$selected}")
			10 => Label("Row b")
			_ => button(action)
		}
		loc = if (operation == 10) Label("Row b") else button(action)
		$s = SpecRunner.one(program, $s, Click(loc)) ?? crash "reference history: click failed on ${Scm.show_loc(loc)}"
		focused = SpecRunner.find($s.dom, expected) ?? crash "reference history: expected target missing"
		if $s.focused != focused + 1 {
			crash "reference history: ${Scm.show_loc(loc)} should focus ${Scm.show_loc(expected)}"
		}
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => crash "reference history: ${message}"
		}
		match SpecRunner.check_counters($s) {
			Ok(_) => {}
			Err(message) => crash "reference history: ${message}"
		}
		match operation {
			3 => {
				$has_a = False
			}
			4 => {
				$has_a = True
			}
			5 => {
				$names = Selected
			}
			6 => {
				$selected = "b"
			}
			7 => {
				$names = Unnamed
			}
			_ => {}
		}
	}
	Fuzz.keep
}

Input : { mode : U8, pad : U8, events : List(U8) }

target = Fuzz.target_with!({
	name: "controls",
	examples: [
		Fuzz.example({ name: "focus", revision: "2", make: || { mode: 0, pad: 0, events: [] } }),
		Fuzz.example({ name: "many-sites", revision: "2", make: || { mode: 1, pad: 0, events: [] } }),
		Fuzz.example({ name: "reference-history", revision: "1", make: || { mode: 2, pad: 0, events: [0, 2, 0, 3, 0, 4, 0, 5, 8, 6, 8, 2, 8, 7, 8, 9, 10] } }),
	],
	generator: { mode: Fuzz.constant(2), pad: Fuzz.constant(0), events: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!: |{ mode, pad, events }| match mode {
		0 => focus!({})
		1 => many!(5000 + pad.to_u64())
		_ => reference_focus!(events)
	},
	show: Str.inspect,
})
