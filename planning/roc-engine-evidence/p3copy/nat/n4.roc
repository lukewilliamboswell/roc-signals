app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

In(outer, s) : { outer : outer, value : s }
Inst(ctx) := [Inst((ctx, U64 -> (Inst(ctx), ctx)))]
Block(ctx) : { handlers : List((ctx -> ctx)), children : List(Inst(ctx)) }

noop : {} -> Inst(ctx)
noop = |_| Inst(|env, _| (noop({}), env))

call : Inst(ctx), ctx, U64 -> (Inst(ctx), ctx)
call = |Inst(f), env, pos| f(env, pos)

fire_block : Block(ctx), ctx, U64 -> (Block(ctx), ctx)
fire_block = |block, env, pos| {
	if pos >= 2 {
		match block.handlers.get(0) {
			Ok(handler) => (block, handler(env))
			Err(_) => (block, env)
		}
	} else {
		{ handlers, children } = block
		{ list, prev } = children.replace(0, noop({})) ?? crash "child"
		(next, out) = call(prev, env, pos + 1)
		({ handlers, children: list.set(0, next) ?? crash "child" }, out)
	}
}

state_inst : s, Block(In(ctx, s)) -> Inst(ctx)
state_inst = |s, block| Inst(|env, pos| {
	(b2, next) = fire_block(block, { outer: env, value: s }, pos)
	{ outer, value: s2 } = next
	(state_inst(s2, b2), outer)
})

block_inst : Block(ctx) -> Inst(ctx)
block_inst = |block| Inst(|env, pos| {
	(b2, out) = fire_block(block, env, pos)
	(block_inst(b2), out)
})

poke : a -> a
poke = |e| {
	e
}

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	inner = state_inst(0.U64, { handlers: [poke], children: [] })
	var $r = block_inst({ handlers: [], children: [state_inst(n, { handlers: [], children: [inner] })] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, {}, 0)
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
