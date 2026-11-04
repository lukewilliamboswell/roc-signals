app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# A closure captures a record holding a list of lists. Each call replaces the
# inner list, writes one element, and rebuilds the closure. Nothing else
# references the record, so every List.replace / List.set should be in place.
Block : List(U64)

Root := [Root((U64 -> Root))]

step : Block, U64 -> (Block, U64)
step = |rows, x| {
	match rows.replace(0, 0) {
		Ok({ list, prev }) => (list.set(0, prev + x) ?? crash "rows", x)
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
	var $r = root(List.repeat(0, n))
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		Root(f) = $r
		$r = f($i)
		$i = $i + 1
	}
	"1000 calls: ${(Host.alloc_count!() - before).to_str()} allocations"
}
