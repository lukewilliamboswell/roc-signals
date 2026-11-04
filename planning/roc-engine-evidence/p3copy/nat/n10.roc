app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Inst := [Inst((U64 -> (Inst, U64)))]
Block : { tag : U64, children : List(Inst) }

noop : {} -> Inst
noop = |_| Inst(|x| (noop({}), x))

call : Inst, U64 -> (Inst, U64)
call = |Inst(f), pos| f(pos)

fire : Block, U64 -> (Block, U64)
fire = |block, pos| {
	if pos >= 2 {
		(block, pos)
	} else {
		{ tag, children } = block
		{ list, prev } = children.replace(0, noop({})) ?? crash "child"
		(next, out) = call(prev, pos + 1)
		({ tag, children: list.set(0, next) ?? crash "child" }, out)
	}
}

site : Block -> Inst
site = |block| Inst(|pos| {
	(b2, out) = fire(block, pos)
	(site(b2), out)
})

leaf : List(U64) -> Inst
leaf = |xs| Inst(|x| (leaf(xs.set(0, 7) ?? crash "empty"), x))

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = site({ tag: 0, children: [site({ tag: 0, children: [site({ tag: 0, children: [leaf(List.repeat(0, n))] })] })] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, 0)
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
