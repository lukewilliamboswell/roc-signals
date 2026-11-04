app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# A closure captures a record holding a list. Each call replaces one element
# and rebuilds the closure from the result. Nothing else references the
# record, so List.replace and List.set should both update in place.
Block := [Block({ tag : U64, rows : List(U64) })]

Root := [Root((U64 -> Root))]

step : Block, U64 -> (Block, U64)
step = |Block({ tag, rows }), x| {
	match rows.replace(0, 0) {
		Ok({ list, prev }) => (Block({ tag, rows: list.set(0, prev + x) ?? crash "rows" }), x)
		Err(_) => crash "rows"
	}
}

root : Block -> Root
root = |block| Root(|x| {
	(next, _) = step(block, x)
	root(next)
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + input.count_utf8_bytes()
	var $r = root(Block({ tag: 0, rows: List.repeat(0, n) }))
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		Root(f) = $r
		$r = f($i)
		$i = $i + 1
	}
	"1000 calls: ${(Host.alloc_count!() - before).to_str()} allocations"
}
