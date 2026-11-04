app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Leaf := [Leaf((U64 -> Leaf))]
Root := [Root((U64 -> Root))]
Block : { tag : U64, children : List(Leaf) }

leaf : List(U64) -> Leaf
leaf = |xs| Leaf(|x| leaf(xs.set(0, x) ?? crash "empty"))

step : Block, U64 -> (Block, U64)
step = |{ tag, children }, x| {
	{ list, prev: Leaf(f) } = children.replace(0, leaf([])) ?? crash "child"
	({ tag, children: list.set(0, f(x)) ?? crash "child" }, x)
}

root : Block -> Root
root = |block| Root(|x| root(step(block, x).0))

run! : Str => Str
run! = |input| {
	var $r = root({ tag: 0, children: [leaf(List.repeat(0, 1_000_000 + input.count_utf8_bytes()))] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		Root(f) = $r
		$r = f($i)
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
