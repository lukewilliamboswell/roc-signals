app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Inst := [Inst((U64 -> Inst))]
Block : { tag : U64, children : List(Inst) }

noop : {} -> Inst
noop = |_| Inst(|_| noop({}))

call : Inst, U64 -> Inst
call = |Inst(f), x| f(x)

fire_kid : Block, U64 -> (Block, U64)
fire_kid = |block, x| {
	{ tag, children } = block
	match children.replace(0, noop({})) {
		Ok({ list, prev }) => ({ tag, children: list.set(0, call(prev, x)) ?? crash "child" }, x)
		Err(_) => crash "child"
	}
}

leaf : List(U64) -> Inst
leaf = |xs| Inst(|x| leaf(xs.set(0, x) ?? crash "empty"))

root : Block -> Inst
root = |block| Inst(|x| {
	(b2, _) = fire_kid(block, x)
	root(b2)
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = root({ tag: 0, children: [leaf(List.repeat(0, n))] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		$r = call($r, $i)
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
