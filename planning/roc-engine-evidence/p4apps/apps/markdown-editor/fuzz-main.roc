app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
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

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program: _ }| {
	if mode == 0 {
		bench!(size)
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
		ex("bench-1", 0, 1),
		ex("bench-10", 0, 10),
	],
	generator: { mode: Fuzz.constant(1), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 8) }.Fuzz,
	test!,
	show: Str.inspect,
})
