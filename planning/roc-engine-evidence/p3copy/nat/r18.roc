app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

In(outer, s) : { outer : outer, value : s }
Inst(ctx) := [Inst((ctx -> (Inst(ctx), ctx)))]
Block(ctx) : { handlers : U64, children : List(Inst(ctx)) }

noop : {} -> Inst(ctx)
noop = |_| Inst(|env| (noop({}), env))

call : Inst(ctx), ctx -> (Inst(ctx), ctx)
call = |Inst(f), env| f(env)

state_inst : s, (In(ctx, s) -> In(ctx, s)) -> Inst(ctx)
state_inst = |s, h| Inst(|env| {
	{ outer, value: s2 } = h({ outer: env, value: s })
	(state_inst(s2, h), outer)
})

block_inst : U64, List(Inst(ctx)) -> Inst(ctx)
block_inst = |handlers, children| Inst(|env| {
	match children.replace(0, noop({})) {
		Ok({ list, prev }) => {
			(next, out) = call(prev, env)
			(block_inst(handlers, list.set(0, next) ?? crash "child"), out)
		}
		Err(_) => crash "child"
	}
})

poke : In(o, List(U64)) -> In(o, List(U64))
poke = |e| {
	{ outer, value } = e
	{ list, prev } = value.replace(0, 0) ?? crash "empty"
	{ outer, value: list.set(0, prev + 1) ?? crash "empty" }
}

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = block_inst(0, [state_inst(List.repeat(0, n), poke)])
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, {})
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
