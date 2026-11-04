app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Block : { tag : U64, items : List(U64) }

Inst := [Inst((U64 -> Inst))]

call : Inst, U64 -> Inst
call = |Inst(f), x| f(x)

step : Block, U64 -> Block
step = |block, x| {
	{ tag, items } = block
	{ tag, items: items.set(0, x) ?? crash "empty" }
}

inst : Block -> Inst
inst = |block| Inst(|x| inst(step(block, x)))

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = inst({ tag: 0, items: List.repeat(0, n) })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		$r = call($r, $i)
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
