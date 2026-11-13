app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Dom

## Exercise both direct creation and recursive template construction against
## an independent small tree. Allocator traffic must stay proportional to
## the nodes created, including when template decoding inlines list appends.
Shape : [Elements, TemplateRows, ContentRows]

Input : { count : U64, shape : Shape }

u32 : U32 -> List(U8)
u32 = |number| [number.to_u8_wrap(), number.shr_zf_wrap(8).to_u8_wrap(), number.shr_zf_wrap(16).to_u8_wrap(), number.shr_zf_wrap(24).to_u8_wrap()]

text : Str -> List(U8)
text = |value| u32(value.count_utf8_bytes().to_u32_wrap()).concat(value.to_utf8())

commands : Input -> List(U8)
commands = |{ count, shape }| {
	var $bytes = [0.U8]
	if shape != Elements {
		# Element li, no attributes, one literal text child, no holes.
		template = if shape == ContentRows {
			# Template content contains an element reference plus text. The fragment
			# is intrinsic DOM data and has no emitted command or engine address.
			# Aliases occupy count+1..2*count, disjoint from row ids and dense like
			# the engine allocator, so address capacity scales with this workload.
			[1.U8, 0].concat(text("")).concat(text("template")).concat([1, 0, 1, 1, 0]).concat(text("")).concat(text("span")).concat([0, 0, 1, 2]).concat(text("row text")).concat([1, 5, 1, 1, 0])
		} else {
			[1.U8, 0].concat(text("")).concat(text("li")).concat([0, 0, 1, 2]).concat(text("row text")).append(0)
		}
		$bytes = $bytes.append(7).concat(u32(0)).concat(u32(template.len().to_u32_wrap())).concat(template)
	}
	for row in 0.U64..<count {
		id = (row + 1).to_u32_wrap()
		$bytes = match shape {
			Elements => $bytes.append(8).concat(u32(id)).concat(u32(0)).concat(u32(0)).append(0).concat(text("")).concat(text("li")).append(0)
			TemplateRows => $bytes.append(1).concat(u32(id)).concat(u32(0)).concat(u32(0)).concat(u32(0))
			ContentRows => $bytes.append(1).concat(u32(id)).concat(u32(0)).concat(u32(0)).concat(u32(0)).concat(u32(id + count.to_u32_wrap()))
		}
		if shape == Elements {
			# URI identity joins builtin and explicit-URI encodings. A replacement
			# keeps the original prefix, while raw colon text is a separate attribute.
			$bytes = $bytes.append(9).concat(u32(id)).append(0).concat(text("a")).concat(text("key")).append(1).concat(text("before"))
			$bytes = $bytes.append(9).concat(u32(id)).append(3).concat(text("")).concat(text("a:key")).append(1).concat(text("raw"))
			$bytes = $bytes.append(9).concat(u32(id)).append(4).concat(text("http://www.w3.org/1999/xhtml")).concat(text("b")).concat(text("key")).append(1).concat(text("after"))
		}
	}
	if shape == ContentRows {
		for row in 0.U64..<count {
			$bytes = $bytes.append(5).concat(u32((row + 1).to_u32_wrap()))
		}
		for row in 0.U64..<count {
			id = (row + 1).to_u32_wrap()
			$bytes = $bytes.append(1).concat(u32(id)).concat(u32(0)).concat(u32(0)).concat(u32(0)).concat(u32(id + count.to_u32_wrap()))
		}
	}
	$bytes
}

check : Input, Dom.Model -> {}
check = |{ count, shape }, model| {
	stride = if (shape == Elements) 1.U64 else if (shape == ContentRows) 4 else 2
	if model.nodes.len() != 1 + count * stride * (if (shape == ContentRows) 2 else 1) or Dom.node(model, 0).kids.len() != count {
		crash "DOM model: incorrect node or root child count"
	}
	for row in 0.U64..<count {
		index = 1 + row * stride + (if (shape == ContentRows) count * stride else 0)
		node = Dom.node(model, index)
		if Dom.lookup(model, (row + 1).to_u32_wrap()) != index or node.parent != 1 or node.tag != (if (shape == ContentRows) "template" else "li") or node.namespace != "http://www.w3.org/1999/xhtml" or Dom.node(model, 0).kids.get(row) != Ok(index) {
			crash "DOM model: wrong binding, parent, tag or child order"
		}
		match shape {
			Elements => {
				expected = [({ namespace: "http://www.w3.org/1999/xhtml", prefix: "a", local: "key" }, "after"), ({ namespace: "", prefix: "", local: "a:key" }, "raw")]
				if !node.kids.is_empty() or node.attrs != expected {
					crash "DOM model: namespace alias, prefix retention or raw attribute identity differs"
				}
			}
			ContentRows => {
				fragment = match node.content {
					Some(value) => value
					None => crash "DOM model: missing intrinsic fragment"
				}
				content = Dom.node(model, fragment)
				child = Dom.node(model, index + 2)
				leaf = Dom.node(model, index + 3)
				old_child = Dom.node(model, 1 + row * stride + 2)
				if fragment != index + 1 or !node.kids.is_empty() or node.container != 1 or content.kind != 4 or content.parent != 0 or content.kids != [index + 2] or child.parent != fragment + 1 or child.kids != [index + 3] or leaf.text != "row text" or Dom.text_of(model, index) != "" or !content.ids.is_empty() or !old_child.ids.is_empty() or Dom.lookup(model, (row + count + 1).to_u32_wrap()) != index + 2 {
					crash "DOM model: incorrect inert content ownership, text observation or recycled alias"
				}
			}
			TemplateRows => {
				child = Dom.node(model, index + 1)
				if node.kids != [index + 1] or child.parent != index + 1 or child.text != "row text" or node.rn != (row + 1).to_u32_wrap() {
					crash "DOM model: wrong template subtree"
				}
			}
		}
	}
	if shape != Elements and (model.rows.get(0) ?? crash "DOM model: missing row site").len() != count {
		crash "DOM model: wrong row membership"
	}
	{}
}

## Small direct, cloned and inert-content histories exercise the independent
## model before an optimized fixed replay can reach allocation measurements.
expect {
	for shape in [Elements, TemplateRows, ContentRows] {
		for count in [0.U64, 1, 3] {
			input = { count, shape }
			check(input, Dom.apply(Dom.new({}), commands(input)))
		}
	}
	True
}

decode! : Input, Str => Fuzz.Stats
decode! = |input, label| {
	bytes = commands(input)
	{ value: model, stats } = Fuzz.measure!(label, || Dom.apply(Dom.new({}), bytes))
	check(input, model)
	stats
}

test! : Input => Fuzz.Outcome
test! = |input| {
	small = decode!({ ..input, count: input.count // 10 }, "small")
	large = decode!(input, "large")
	# Ten times as many rows must not require quadratic allocator traffic.
	# Geometric capacity and fixed decoder metadata have ample headroom;
	# no particular allocator count or machine timing is a baseline.
	if large.requested_bytes > small.requested_bytes * 20 + 65536 {
		crash "DOM model: tenfold growth caused disproportionate allocation traffic"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "dom",
	examples: [Elements, TemplateRows, ContentRows].map(|shape| [0.U64, 1, 100, 200, 400, 1000].map(|count| Fuzz.example({ name: "${Str.inspect(shape)}-${count.to_str()}", revision: "3", make: || { count, shape } }))).join(),
	generator: {
		count: Fuzz.u64_in(0, 1000),
		shape: Fuzz.map(
			Fuzz.u8,
			|byte| match byte % 3 {
				0 => Elements
				1 => TemplateRows
				_ => ContentRows
			},
		),
	}.Fuzz,
	test!,
	show: Str.inspect,
})
