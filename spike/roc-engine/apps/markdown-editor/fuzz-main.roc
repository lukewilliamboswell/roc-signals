app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import Soak
import MdApp
import Markdown
import Stats
import Outline
import Edit
import MdSpecs

## Markdown Editor on the p4 engine.
## - "specs": every original .scm spec replayed through Spec.run.
## - "bench-N": the sample document repeated N times, then measured single
##   transactions: append a word (a paragraph edit: the heading spine stays
##   equal), toggle numbering, change reading speed, append a section.

specs! : {} => Fuzz.Outcome
specs! = |_| {
	for (name, steps) in MdSpecs.all {
		match Spec.run(MdApp.main({}), steps) {
			Ok(_) => {}
			Err(msg) => crash "spec ${name}: ${msg}"
		}
	}
	Fuzz.keep
}

mstep! : Spec.S, Str, Spec.Loc, Str, Str => Spec.S
mstep! = |s, name, loc, ev, payload| {
	i = Spec.find(s.dom, loc) ?? crash "${name}: no ${Spec.show_loc(loc)}"
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
	$s = mstep!($s, "append-word", Role("button", "Append a word"), "click", "")
	$s = mstep!($s, "append-word-again", Role("button", "Append a word"), "click", "")
	$s = mstep!($s, "toggle-numbering", Label("Number the outline"), "change", "false")
	$s = mstep!($s, "reading-speed", Label("Reading speed"), "change", "300")
	$s = mstep!($s, "append-section", Role("button", "Append a section"), "click", "")
	_ = $s
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Spec.Step)
cycle = [Click(Role("button", "Append a section")), Click(Role("button", "Remove the last section"))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Spec.start(MdApp.main({})), program, |s| s))
	Fuzz.keep
}

## Soak, mode 3: 2,000 seeded random events per example (five examples,
## seeds 1-5: 10k events; the DOM oracle makes one 10k walk exceed the
## per-input timeout here), leak-checked, then the round trip 12 times on
## the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : U64 => Fuzz.Outcome
soak_10k! = |seed| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Spec.start(MdApp.main({})), seed, 2000, |s| s))
	(s1, evs) = Soak.triples(Spec.start(MdApp.main({})), cycle, |s| s)
	counts = Soak.replay!(s1.eng, evs, 12, |a, b| (a, b), |_| Fuzz.live_alloc_count!())
	match Soak.flat(counts, 2) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle live allocations ${Str.inspect(counts)}")
	Fuzz.keep
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 0 {
		if size > 50 Fuzz.reject else bench!(size)
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!(size)
	} else {
		specs!({})
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "p4-markdown-editor",
	examples: [
		ex("specs", 1, 0),
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
