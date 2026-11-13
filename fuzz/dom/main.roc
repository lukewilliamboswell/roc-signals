app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Dom

## Exercise both direct creation and recursive template construction against
## an independent small tree. Allocator traffic must stay proportional to
## the nodes created, including when template decoding inlines list appends.
Shape : [Elements, TemplateRows]

Input : { count : U64, shape : Shape }

u32 : U32 -> List(U8)
u32 = |number| [number.to_u8_wrap(), number.shr_zf_wrap(8).to_u8_wrap(), number.shr_zf_wrap(16).to_u8_wrap(), number.shr_zf_wrap(24).to_u8_wrap()]

text : Str -> List(U8)
text = |value| u32(value.count_utf8_bytes().to_u32_wrap()).concat(value.to_utf8())

commands : Input -> List(U8)
commands = |{ count, shape }| {
	var $bytes = [0.U8]
	if shape == TemplateRows {
		# Element li, no attributes, one literal text child, no holes.
		template = [1.U8].concat(text("li")).concat([0, 1, 2]).concat(text("row text")).append(0)
		$bytes = $bytes.append(7).concat(u32(0)).concat(u32(template.len().to_u32_wrap())).concat(template)
	}
	for row in 0.U64..<count {
		id = (row + 1).to_u32_wrap()
		$bytes = match shape {
			Elements => $bytes.append(8).concat(u32(id)).concat(u32(0)).concat(u32(0)).concat(text("li"))
			TemplateRows => $bytes.append(1).concat(u32(id)).concat(u32(0)).concat(u32(0)).concat(u32(0))
		}
	}
	$bytes
}

check : Input, Dom.Model -> {}
check = |{ count, shape }, model| {
	stride = if (shape == Elements) 1.U64 else 2
	if model.nodes.len() != 1 + count * stride or Dom.node(model, 0).kids.len() != count {
		crash "DOM model: incorrect node or root child count"
	}
	for row in 0.U64..<count {
		index = 1 + row * stride
		node = Dom.node(model, index)
		if Dom.lookup(model, (row + 1).to_u32_wrap()) != index or node.parent != 1 or node.tag != "li" or Dom.node(model, 0).kids.get(row) != Ok(index) {
			crash "DOM model: wrong binding, parent, tag or child order"
		}
		match shape {
			Elements if !node.kids.is_empty() => crash "DOM model: unexpected static child"
			TemplateRows => {
				child = Dom.node(model, index + 1)
				if node.kids != [index + 1] or child.parent != index + 1 or child.text != "row text" or node.rn != (row + 1).to_u32_wrap() {
					crash "DOM model: wrong template subtree"
				}
			}
			_ => {}
		}
	}
	if shape == TemplateRows and (model.rows.get(0) ?? crash "DOM model: missing row site").len() != count {
		crash "DOM model: wrong row membership"
	}
	{}
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
	examples: [Elements, TemplateRows].map(|shape| [0.U64, 1, 100, 200, 400, 1000].map(|count| Fuzz.example({ name: "${Str.inspect(shape)}-${count.to_str()}", revision: "1", make: || { count, shape } }))).join(),
	generator: { count: Fuzz.u64_in(0, 1000), shape: Fuzz.map(Fuzz.u8, |byte| if (byte % 2 == 0) Elements else TemplateRows) }.Fuzz,
	test!,
	show: Str.inspect,
})
