app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Leaf := [Leaf((U64 -> Leaf))]
Inst := [Inst((U64 -> Inst))]
Block : { tag : U64, children : List(Leaf) }

noop : {} -> Leaf
noop = |_| Leaf(|_| noop({}))

call_leaf : Leaf, U64 -> Leaf
call_leaf = |Leaf(f), x| f(x)

call : Inst, U64 -> Inst
call = |Inst(f), x| f(x)

fire_kid : U64, List(Leaf), U64 -> (Block, U64)
fire_kid = |tag, children, x| {
	match children.replace(0, noop({})) {
		Ok({ list, prev }) => ({ tag, children: list.set(0, call_leaf(prev, x)) ?? crash "child" }, x)
		Err(_) => crash "child"
	}
}

leaf : List(U64) -> Leaf
leaf = |xs| Leaf(|x| leaf(xs.set(0, x) ?? crash "empty"))

root : U64, List(Leaf) -> Inst
root = |tag, children| Inst(|x| {
	({ tag: t2, children: c2 }, _) = fire_kid(tag, children, x)
	root(t2, c2)
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = root(0, [leaf(List.repeat(0, n))])
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		$r = call($r, $i)
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
