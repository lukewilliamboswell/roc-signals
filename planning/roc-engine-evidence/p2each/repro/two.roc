app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# Representation D closer to the engine: an environment threaded in and
# handed back, a noop member, and a parent site that owns a child list and
# forwards messages by the replace pattern.
Msg := [Set(U64), Fwd(U64), Len]

Inst(env) := [Inst((env, Msg -> (Inst(env), env, U64)))]

noop : {} -> Inst(env)
noop = |_| Inst(|e, _| (noop({}), e, 0))

leaf : List(U64) -> Inst(env)
leaf = |xs| Inst(|e, msg| {
	match msg {
		Set(i) => (leaf(xs.set(i, 7) ?? xs), e, 1)
		Fwd(i) => (leaf(xs.set(i, 8) ?? xs), e, 1)
		Len => (leaf(xs), e, xs.len())
	}
})

## A parent holding children, like a block site.
parent : List(Inst(env)) -> Inst(env)
parent = |kids| Inst(|e, msg| {
	match msg {
		Fwd(i) => {
			{ list, prev } = kids.replace(0, noop({})) ?? crash "kid"
			(k2, e2, n) = call(prev, e, Set(i))
			(parent(list.set(0, k2) ?? crash "kid"), e2, n)
		}
		_ => (parent(kids), e, 0)
	}
})

call : Inst(env), env, Msg -> (Inst(env), env, U64)
call = |Inst(f), e, msg| f(e, msg)

measure! : Inst(Str), Msg => U64
measure! = |inst0, msg| {
	before = Host.alloc_count!()
	var $s = inst0
	var $e = "env"
	var $i = 0
	while $i < 1000 {
		(next, e2, _) = call($s, $e, match msg { Set(_) => Set($i), Fwd(_) => Fwd($i), Len => Len })
		$s = next
		$e = e2
		$i = $i + 1
	}
	Host.alloc_count!() - before
}

run! : Str => Str
run! = |input| {
	n = 10_000 + Str.count_utf8_bytes(input)
	a = measure!(leaf(List.repeat(0, n)), Set(0))
	b = measure!(parent([leaf(List.repeat(0, n))]), Fwd(0))
	"1000 updates: leaf ${a.to_str()} allocations, through parent ${b.to_str()} allocations"
}
