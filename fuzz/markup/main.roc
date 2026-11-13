app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	parser: "../../../roc-parser/package/main.roc",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Engine
import pf.MarkupLiteral
import pf.Html
import parser.Html as ParsedHtml
import parser.Svg as ParsedSvg
import parser.MarkupTemplate
import Reference

Input : { shape : U8, tree : List(U8), values : List(U8), events : List(U8) }

## Bytes describe valid nested fragments and histories of data updates, rather
## than malformed source. The independent model walks a separately parsed tree;
## the engine result is read through the independent command decoder. Every
## step checks expanded names, exact attributes, comments, text and settledness.
run : Input -> {}
run = |input| {
	segments = source(input)
	mode = if input.shape % 6 == 2 or input.shape % 6 == 3 {
		SvgFragment
	} else HtmlFragment
	parsed = match mode {
		HtmlFragment => ParsedHtml.parse_segments(segments, { authored_structure: Exact })
		SvgFragment => ParsedSvg.parse_segments(segments, { authored_structure: Exact })
	} ?? crash "markup generator produced invalid source"
	plan = MarkupLiteral.compile(segments, mode) ?? crash "generated checked source failed literal lowering"
	parts = segments.len() - 1
	element = Engine.state(
		0.U64,
		|state| Engine.element(
			"main",
			[],
			[
				Html.button("Next", [Engine.attr("aria-label", "Next")], state.update(|phase| phase + 1)),
				Html.button("Same", [Engine.attr("aria-label", "Same")], state.update(|phase| phase)),
				MarkupLiteral.render(plan, indices(parts).map(|slot| state.signal().map(|phase| value(input.values, phase, slot)))),
			],
		),
	)
	(initial, commands) = Core.take_cmds(Core.mount(element), [])
	var $engine = initial
	var $dom = Dom.apply(Dom.new({}), commands)
	var $phase = 0.U64
	assert_picture($engine, $dom, parsed, input.values, $phase, parts)
	for event in input.events.take_first(24) {
		caption = if (event % 3 == 0) "Same" else "Next"
		button = Dom.find($dom, $dom.root, |node| node.tag == "button" and Dom.attr_of(node, "aria-label") == caption) ?? crash "markup update button missing"
		listener = Dom.target($dom, button, "click", True) ?? crash "markup update listener missing"
		(after, emitted) = Core.take_cmds(Core.event($engine, listener.node, listener.handler, ""), [])
		$engine = after
		$dom = Dom.apply($dom, emitted)
		if event % 3 != 0 {
			$phase = $phase + 1
		}
		assert_picture($engine, $dom, parsed, input.values, $phase, parts)
	}
	{}
}

## Only the data changes; characters resembling markup, entity references and
## future adoption marks must remain data through every generated history.
value : List(U8), U64, U64 -> Str
value = |bytes, phase, slot| "${Str.from_utf8_lossy(bytes.take_first(80))}<>&\u(FEFF)<!--roc:node=7-->:${phase.to_str()}:${slot.to_str()}"

indices : U64 -> List(U64)
indices = |count| {
	var $items = []
	for index in 0.U64..<count {
		$items = $items.append(index)
	}
	$items
}

source : Input -> List(Str)
source = |input| match input.shape % 6 {
	0 => {
		depth = input.tree.len() % 5
		opening = Str.join_with(indices(depth).map(|_| "<div>"), "")
		closing = Str.join_with(indices(depth).map(|_| "</div>"), "")
		var $segments = []
		var $fixed = "\n<div data-n='app-node' data-h='app-hole'>${opening}"
		for byte in input.tree.take_first(8).concat([0]) {
			$segments = $segments.append("${$fixed}<p data-value='")
			$segments = $segments.append("'>")
			$fixed = "</p><!--roc:row=${byte.to_str()}--> "
		}
		$segments.append("${$fixed}${closing}</div>\n")
	}
	1 => ["<select><button><selectedcontent></selectedcontent></button><option selected>", "</option></select>"]
	2 => ["<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20'><path d='M0 0L1 1' pathLength='", "'/><!--roc:node=8--><text>", "</text></svg>"]
	3 => ["<svg xmlns='http://www.w3.org/2000/svg'><foreignObject><h:div xmlns:h='http://www.w3.org/1999/xhtml' data-value='", "'>", "<!--foreign comment--><h:template><h:span>", "</h:span><!--xml template comment--></h:template></h:div></foreignObject></svg>"]
	4 => ["<div><math><mrow><mi>x</mi><mo>+</mo><mn>", "</mn></mrow></math><p>", "</p><!--math comment--></div>"]
	_ => ["<template data-n='app-node'><span>", "</span><!--roc:node=9--></template>"]
}

assert_picture : Core.App({}), Dom.Model, MarkupTemplate.Plan, List(U8), U64, U64 -> {}
assert_picture = |engine, dom, parsed, bytes, phase, parts| {
	main = Dom.find(dom, dom.root, |node| node.tag == "main") ?? crash "markup main missing"
	root = (dom.nodes.get(main) ?? crash "markup main index").kids.get(2) ?? crash "markup fragment missing"
	actual = [picture(dom, root)]
	wanted = Reference.render(parsed, indices(parts).map(|slot| value(bytes, phase, slot)))
	if actual != wanted {
		crash "markup differs after phase ${phase.to_str()}: ${Str.inspect(actual)}, reference ${Str.inspect(wanted)}"
	}
	if Core.settled(engine).is_err() {
		crash "markup left a stale signal reader"
	}
	{}
}

picture : Dom.Model, U64 -> Reference.Node
picture = |dom, index| {
	node = dom.nodes.get(index) ?? crash "markup oracle child index"
	match node.kind {
		1 => Element({
			name: { namespace: node.namespace, local: node.tag, prefix: node.prefix },
			attributes: node.attrs.map(|(name, text)| { name: { namespace: name.namespace, local: name.local, prefix: name.prefix }, value: text }),
			children: node.kids.map(|child| picture(dom, child)),
			content: match node.content {
				None => []
				Some(fragment) => Dom.node(dom, fragment).kids.map(|child| picture(dom, child))
			},
		})
		2 => Text(node.text)
		3 => Comment(node.text)
		_ => crash "markup oracle node kind"
	}
}

test! : Input => Fuzz.Outcome
test! = |input| {
	Fuzz.expect_no_leaks!(|| run(input))
	Fuzz.keep
}

fixed : List({ name : Str, input : Input })
fixed = [
	{ name: "nested-attributes-text-comments", input: { shape: 0, tree: [1, 2, 3, 4], values: [60, 38, 62, 0, 255], events: [1, 0, 2, 0, 1] } },
	{ name: "selectedcontent-clone-fanout", input: { shape: 1, tree: [], values: [99, 104, 111, 115, 101, 110], events: [1, 0, 2] } },
	{ name: "svg-case-and-comments", input: { shape: 2, tree: [], values: [49, 50], events: [1, 1, 0] } },
	{ name: "prefixed-xhtml-in-svg", input: { shape: 3, tree: [], values: [120], events: [1, 0, 1] } },
	{ name: "embedded-mathml", input: { shape: 4, tree: [], values: [195, 169], events: [1, 2, 0] } },
	{ name: "inert-template-content", input: { shape: 5, tree: [], values: [120], events: [1, 0, 1] } },
]

## The same histories also run as a pure preflight; this does not replace the
## optimized roc-fuzz replay's allocation and leak assertions.
expect {
	for case in fixed {
		run(case.input)
	}
	True
}

target = Fuzz.target_with!({
	name: "markup",
	examples: fixed.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || case.input })),
	generator: { shape: Fuzz.u8, tree: Fuzz.list(Fuzz.u8, 8), values: Fuzz.list(Fuzz.u8, 80), events: Fuzz.list(Fuzz.u8, 24) }.Fuzz,
	test!,
	show: Str.inspect,
})
