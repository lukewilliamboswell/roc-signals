app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.PictureClaims
import pf.PictureCodec
import pf.PicturePlan
import Vectors

## Generated first frames exercise final aliases, omitted text, content
## fragments and control scaffolds without performing any hosted effect.
view : { mode : U8, count : U64, text : Str } -> Core.Elem(Core.Root({}))
view = |props| match props.mode {
	0 => Core.element("div", [], [Core.text(""), Core.text(props.text), Core.text(""), Core.comment("roc:node=9")])
	1 => {
		var $rows = []
		for key in 0..<props.count {
			$rows = $rows.append(key)
		}
		rows = $rows
		Core.state(0.U64, |counter| Core.each(Core.const(rows), |key| key.to_str(), |row| Core.element("article", [Core.attr_s("data-k", row.item().map(U64.to_str)), Core.ref_s(row.item().map(|key| "ref-${key.to_str()}")), Core.on_click(counter.lift_row().update(|value| value + 1))], [Core.text_s(row.item().map(U64.to_str)), Core.when(Core.const(True), || Core.text(props.text), || Core.text("else")), Core.element("input", [Core.prop_s(Core.Prop.value, row.item().map(U64.to_str))], [])])))
	}
	2 => Core.template_content(Core.element("template", [], [Core.element("span", [], [Core.text(props.text)]), Core.comment("inert")]))
	3 => Core.element("textarea", [Core.prop(Core.Prop.value, props.text)], [Core.text("authored"), Core.comment("original")])
	4 => Core.element("select", [Core.prop(Core.Prop.value, "missing")], [Core.element("option", [Core.prop(Core.Prop.value, "present")], [Core.text(props.text)])])
	5 => Core.element("select", [Core.prop(Core.Prop.value, "present")], [Core.element("option", [Core.prop(Core.Prop.value, "present"), Core.attr("selected", "authored")], [Core.text(props.text)])])
	6 => Core.state(True, |visible| Core.element("main", [], [Core.when(visible.signal(), || Core.element("section", [], [Core.text("gone")]), || Core.element("section", [], [Core.text(props.text)])), Core.watch(Core.const({}), |_| [Core.again({})], visible.on_result(|_, _, _| False))]))
	7 => Core.element("template", [], [])
	8 => Core.element("select", [Core.prop(Core.Prop.value, "missing")], [Core.element("option", [Core.attr("selected", ""), Core.attr("data-x", "x"), Core.prop(Core.Prop.value, "present")], [])])
	9 => Core.each(Core.const([0.U64, 1]), |key| key.to_str(), |row| Core.element("article", [Core.ref_s(row.item().map(|key| "static-${key.to_str()}"))], [Core.text(""), Core.comment("static"), Core.template_content(Core.element("template", [], [Core.element("span", [], [Core.text_s(row.item().map(U64.to_str))])])), Core.element("textarea", [Core.prop(Core.Prop.value, props.text)], [Core.text("authored"), Core.comment("original")])]))
	_ => Core.state(True, |visible| Core.element("main", [], [Core.each(visible.signal().map(|shown| if (shown) [0.U64, 1] else [1, 2]), |key| key.to_str(), |row| Core.element("article", [Core.ref_s(row.item().map(|key| "reuse-${key.to_str()}"))], [Core.text_s(row.item().map(U64.to_str)), Core.comment("kept")])), Core.watch(Core.const({}), |_| [Core.again({})], visible.on_result(|_, _, _| False))]))
}

## A deliberately small reference checks every returned binding against the
## oracle's final lifetime and independently walks row holes. Counts require
## all final principals and holes rather than merely accepting returned claims.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	mode = (bytes.get(0) ?? 0) % 11
	count = (bytes.get(1) ?? 0).to_u64() % 5 + 1
	text = match (bytes.get(2) ?? 0) % 4 {
		0 => ""
		1 => "é😀\r"
		2 => "<&"
		_ => "data"
	}
	program = Core.program(|| view({ mode, count, text }))
	picture = Core.init_picture(program, [])
	Core.settled(picture.state) ?? crash "picture-claims: mount did not settle"
	frames = picture.capture ?? crash "picture-claims: bounded capture refused"
	dom = Dom.apply(Dom.new({}), picture.commands)
	rendered = Dom.render(dom, { root: dom.root, scope: Contents, mode: Picture, limits: { max_bytes: 1048576, max_nodes: 1024, max_depth: 32 } }) ?? crash "picture-claims: independent render refused valid frame"
	envelope = PictureClaims.assemble({ dom, rendered, frames, batch: picture.commands, fingerprint: List.repeat(17, 32), expected: List.repeat(34, 32), limits: {} }) ?? crash "picture-claims: valid final frame refused"
	parts = PictureCodec.parts(envelope)
	# This test derives finite allocation facts from the independent native
	# address map, never by reading the engine's App storage.
	var $frontier = 1.U32
	for frame in frames {
		if frame.address >= $frontier {
			$frontier = frame.address + 1
		}
	}
	var $free = []
	for address in 1.U32..<$frontier {
		if (dom.statics.get(address.to_u64()) ?? 0).bitwise_and(1099511627775) == 0 {
			$free = $free.append(address)
		}
	}
	plan = PicturePlan.build({ batch: picture.commands, frames, next: $frontier, free: $free, envelope }) ?? crash "picture-claims: fresh oracle ownership rejected by plan"
	if PicturePlan.operations(plan).len() != frames.keep_if(|frame| frame.opcode != 0 and frame.opcode != 254 and frame.opcode != 255).len() {
		crash "picture-claims: plan omitted an ordinary command"
	}

	match frames.find_first(|frame| frame.opcode == 255) {
		Err(_) => {}
		Ok(first_hole) => {
			missing = frames.keep_if(|frame| frame.opcode != 255 or frame.at != first_hole.at or frame.address != first_hole.address or frame.slot != first_hole.slot)
			if PictureClaims.assemble({ dom, rendered, frames: missing, batch: picture.commands, fingerprint: List.repeat(17, 32), expected: List.repeat(34, 32), limits: {} }).is_ok() {
				crash "picture-claims: missing captured hole accepted"
			}
			wrong = frames.map(
				|frame| if frame.opcode == 255 and frame.at == first_hole.at and frame.address == first_hole.address and frame.slot == first_hole.slot {
					{ ..frame, kind: frame.kind % 6 + 1 }
				} else {
					frame
				},
			)
			if PictureClaims.assemble({ dom, rendered, frames: wrong, batch: picture.commands, fingerprint: List.repeat(17, 32), expected: List.repeat(34, 32), limits: {} }).is_ok() {
				crash "picture-claims: wrong captured hole kind accepted"
			}
		}
	}

	var $expected_principals = 0.U64
	var $expected_holes = 0.U64
	for entry in rendered.logical {
		model_node = Dom.node(dom, entry.model)
		for address in model_node.ids {
			packed = dom.statics.get(address.to_u64()) ?? 0
			if packed.bitwise_and(1099511627775) == entry.model + 1 {
				$expected_principals = $expected_principals + 1
				if packed.shr_zf_wrap(40) != 0 {
					$expected_holes = $expected_holes + model_node.ht.len()
				}
			}
		}
	}
	if parts.bindings.keep_if(|binding| binding.role != Hole and binding.role != TemplateNode).len() != $expected_principals or parts.bindings.keep_if(|binding| binding.role == Hole).len() != $expected_holes {
		crash "picture-claims: omitted or duplicate final binding"
	}
	if parts.bindings.keep_if(|binding| binding.role == Static or binding.role == TemplateNode).len() != rendered.logical.len() {
		crash "picture-claims: construction ownership is not exhaustive"
	}
	for binding in parts.bindings {
		logical = rendered.logical.get(binding.logical.to_u64()) ?? crash "picture-claims: unknown logical claim"
		model = Dom.lookup(dom, binding.address)
		if binding.role == TemplateNode {
			match Dom.node(dom, model).template_nodes {
				Cloned(nodes) => if nodes.get(binding.slot.to_u64()) != Ok(logical.model) {
					crash "picture-claims: template node names another lifetime"
				}
				_ => crash "picture-claims: missing bounded clone cache"
			}
		} else if binding.role == Hole {
			row = Dom.node(dom, model)
			if row.ht.get(binding.slot.to_u64()) != Ok(logical.model) {
				crash "picture-claims: row hole names another lifetime"
			}
		} else if model != logical.model {
			crash "picture-claims: principal names another lifetime"
		}
		# Reference selection uses the final command order, independently of the
		# producer's latest-address dictionary and without content-based identity.
		var $birth = 0.U32
		for frame in frames {
			if frame.address == binding.address and (frame.opcode == 0 or frame.opcode == 1 or frame.opcode == 8 or frame.opcode == 10 or frame.opcode == 26) {
				$birth = frame.at
			}
		}
		if binding.birth_offset != $birth {
			crash "picture-claims: stale incarnation birth"
		}
	}
	canonical = PictureClaims.measurement_bytes(
		envelope,
		{ rendered: rendered },
	) ?? crash "picture-claims: physical measurement refused"
	if PictureClaims.measurement_bytes(envelope, { rendered, max_bytes: canonical.len() }) != Ok(canonical) or PictureClaims.measurement_bytes(envelope, { rendered, max_bytes: canonical.len() - 1 }).is_ok() {
		crash "picture-claims: canonical allocation cap"
	}
	changed = PictureCodec.make({ ..parts, fingerprint: List.repeat(9, 32), expected: List.repeat(8, 32) }, {}) ?? crash "picture-claims: changed opaque hashes refused"
	if PictureClaims.measurement_bytes(
		changed,
		{ rendered: rendered },
	) != Ok(canonical) {
		crash "picture-claims: stored hashes entered canonical input"
	}
	Fuzz.keep
}

## Independent Python struct/hashlib fixtures pin canonical bytes rather than
## deriving expected output from the codec or the JavaScript implementation.
expect Vectors.check({}) == {}

## Pure preflight exercises the same named inputs; it never substitutes for
## the actual optimized fixed-example execution and its leak instrumentation.
expect fixed_cases.all(
	|example| match test((example.make)()) {
		Keep => True
		Reject => False
	},
)

fixed_cases : List({ name : Str, revision : Str, make : () -> List(U8) })
fixed_cases = [
	{ name: "empty-adjacent-text-comments", revision: "1", make: || [0, 0, 0] },
	{ name: "unicode-adjacent-text", revision: "1", make: || [0, 0, 1] },
	{ name: "all-row-hole-kinds-and-aliases", revision: "1", make: || [1, 4, 1] },
	{ name: "intrinsic-content", revision: "1", make: || [2, 0, 2] },
	{ name: "constructed-control-text", revision: "1", make: || [3, 0, 1] },
	{ name: "omitted-control-text", revision: "1", make: || [3, 0, 0] },
	{ name: "no-selection-scaffold", revision: "1", make: || [4, 0, 1] },
	{ name: "selected-attribute-override", revision: "1", make: || [5, 0, 1] },
	{ name: "followup-disposal-id-reuse", revision: "1", make: || [6, 0, 1] },
	{ name: "row-static-empty-comments-content-control", revision: "1", make: || [9, 0, 1] },
	{ name: "row-followup-disposal-id-reuse", revision: "1", make: || [10, 0, 1] },
	{ name: "selected-original-first-attribute", revision: "1", make: || [8, 0, 0] },
	{ name: "raw-template-children-empty", revision: "1", make: || [7, 0, 0] },
]

target = Fuzz.target_with({ name: "picture-claims", generator: Fuzz.raw_bytes, test, show: |bytes| Str.inspect(bytes), examples: fixed_cases.map(Fuzz.example) })
