app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Inst := [Inst((U64 -> (Inst, U64)))]
Block : { tag : U64, items : List(U64) }

call : Inst, U64 -> (Inst, U64)
call = |Inst(f), x| f(x)

step : Block, U64 -> (Block, U64)
step = |block, x| {
	{ tag, items } = block
	({ tag, items: items.set(0, x) ?? crash "empty" }, x)
}

root : Block -> Inst
root = |block| Inst(|x| {
	(b2, out) = step(block, x)
	(root(b2), out)
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = root({ tag: 0, items: List.repeat(0, n) })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, $i)
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
