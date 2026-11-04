app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Inst := [Inst((U64 -> Inst))]
Block : { tag : U64, children : List(Inst) }

noop : {} -> Inst
noop = |_| Inst(|_| noop({}))

call : Inst, U64 -> Inst
call = |Inst(f), pos| f(pos)

fire : Block, U64 -> Block
fire = |block, pos| {
	if pos >= 2 {
		block
	} else {
		{ tag, children } = block
		{ list, prev } = children.replace(0, noop({})) ?? crash "child"
		{ tag, children: list.set(0, call(prev, pos + 1)) ?? crash "child" }
	}
}

site : Block -> Inst
site = |block| Inst(|pos| site(fire(block, pos)))

leaf : List(U64) -> Inst
leaf = |xs| Inst(|_| leaf(xs.set(0, 7) ?? crash "empty"))

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = site({ tag: 0, children: [site({ tag: 0, children: [site({ tag: 0, children: [leaf(List.repeat(0, n))] })] })] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		$r = call($r, 0)
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
