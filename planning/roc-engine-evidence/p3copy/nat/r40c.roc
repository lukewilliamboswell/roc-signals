app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# A closure captures a record holding a list of lists. Each call replaces the
# inner list, writes one element, and rebuilds the closure. Nothing else
# references the record, so every List.replace / List.set should be in place.
Block : { tag : U64, rows : List(U64) }

Root := [Root((U64 -> Root))]

step : Block, U64 -> Block
step = |{ tag, rows }, x| {
	match rows.replace(0, 0) {
		Ok({ list, prev }) => { tag, rows: list.set(0, prev + x) ?? crash "rows" }
		Err(_) => crash "rows"
	}
}

root : Block -> Root
root = |block| Root(|x| {
	root(step(block, x))
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + input.count_utf8_bytes()
	var $r = root({ tag: 0, rows: List.repeat(0, n) })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		Root(f) = $r
		$r = f($i)
		$i = $i + 1
	}
	"1000 calls: ${(Host.alloc_count!() - before).to_str()} allocations"
}
