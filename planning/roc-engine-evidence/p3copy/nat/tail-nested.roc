
seq : U64 -> List(U64)
seq = |n| {
	var $l = List.with_capacity(n)
	var $i = 0
	while $i < n {
		$l = $l.append($i)
		$i = $i + 1
	}
	$l
}

poke : List(U64) -> List(U64)
poke = |xs| {
	{ list, prev } = xs.replace(0, 0) ?? crash "empty"
	list.set(0, prev + 1) ?? crash "empty"
}

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	prog = Engine.program(|| Engine.state(seq(n), |outer| Engine.state("", |_sel| Engine.element("button", [Engine.attr("id", "b"), Engine.on_click(outer.lift().update(poke))], []))))
	(s0, _) = (prog.init)()
	var $b = s0
	var $buf = []
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, cmds) = (prog.event)($b, $buf, 0, 0)
		$b = next
		$buf = cmds
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
