app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import MdApp
import Markdown
import Stats
import Outline
import Edit

## The engine-level state the benches measure transactions on.
B : { eng : Engine.App, dom : Dom.Model, steps : U64 }

## Markdown Editor on the Roc-owned engine.
## - "bench-N": the sample document repeated N times, then measured single
##   transactions: append a word (a paragraph edit: the heading spine stays
##   equal), toggle numbering, change reading speed, append a section.

mstep! : B, Str, Scm.Loc, Str, Str => B
mstep! = |s, name, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "${name}: no ${Scm.show_loc(loc)}"
	(node, h) = Dom.target(s.dom, i, ev) ?? crash "${name}: no handler"
	{ eng, dom, steps } = s
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(Engine.event(eng, node, h, payload), [])
	_ = w.finish!()
	{ eng: a, dom: Dom.apply(dom, c), steps: steps + 1 }
}

doc_of : U64 -> Str
doc_of = |n| Str.join_with(List.repeat(MdApp.sample_document, n), "\n\n")

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	view = MdApp.main_with(doc_of(n))
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	# The app's own work for one paragraph edit, outside the engine.
	edited = Edit.append_word(doc_of(n))
	wj = Fuzz.start_measure!("app-parse-counts-headings")
	bl = Markdown.parse(edited)
	ct = Stats.counts(edited)
	hd = Outline.headings(bl)
	_ = wj.finish!()
	_ = (ct, hd)
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	$s = mstep!($s, "append-word", Role({ role: "button", name: "Append a word" }), "click", "")
	$s = mstep!($s, "append-word-again", Role({ role: "button", name: "Append a word" }), "click", "")
	$s = mstep!($s, "toggle-numbering", Label("Number the outline"), "change", "false")
	$s = mstep!($s, "reading-speed", Label("Reading speed"), "change", "300")
	$s = mstep!($s, "append-section", Role({ role: "button", name: "Append a section" }), "click", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)

## (Append then remove a section is not an exact inverse in this app: each
## round trip leaves one more trailing newline, so it grows by design.)
cycle = [Click(Role({ role: "button", name: "Load heading drill" })), Click(Role({ role: "button", name: "Load document without headings" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 2,000 seeded random events per example (five examples,
## seeds 1-5: 10k events; the DOM oracle makes one 10k walk exceed the
## per-input timeout here), leak-checked, then the round trip 48 times on
## the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : U64 => Fuzz.Outcome
soak_10k! = |seed| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), seed, 2000, |s| s))
	(s1, evs) = Soak.triples(MdApp.program, SpecRunner.mount(MdApp.program, "/", []), cycle, |s| s)
	counts = Soak.replay!(MdApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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
		if (size > 50) Fuzz.reject else bench!(size)
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!(size)
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "markdown-editor",
	examples: [
		ex("soak-2k-s1", 3, 1),
		ex("soak-2k-s2", 3, 2),
		ex("soak-2k-s3", 3, 3),
		ex("soak-2k-s4", 3, 4),
		ex("soak-2k-s5", 3, 5),
		ex("bench-1", 0, 1),
		ex("bench-10", 0, 10),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
