app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

In(outer, s) := { outer : outer, value : s }
Out(ctx) := [Done, Pending(ctx)]
Inst(ctx) := [Inst((ctx, U64 -> (Inst(ctx), Out(ctx))))]
Block(ctx) : { handlers : List((ctx -> ctx)), children : List(Inst(ctx)) }

noop : {} -> Inst(ctx)
noop = |_| Inst(|env, _| (noop({}), Pending(env)))

call : Inst(ctx), ctx, U64 -> (Inst(ctx), Out(ctx))
call = |Inst(f), env, pos| f(env, pos)

fire_block : Block(ctx), ctx, U64 -> (Block(ctx), Out(ctx))
fire_block = |block, env, pos| {
	if pos >= 1 {
		match block.handlers.get(0) {
			Ok(handler) => (block, Pending(handler(env)))
			Err(_) => (block, Pending(env))
		}
	} else {
		{ handlers, children } = block
		match children.replace(0, noop({})) {
			Ok({ list, prev }) => {
				(next, out) = call(prev, env, pos + 1)
				({ handlers, children: list.set(0, next) ?? crash "child" }, out)
			}
			Err(_) => ({ handlers, children }, Pending(env))
		}
	}
}

state_inst : s, Block(In(ctx, s)) -> Inst(ctx)
state_inst = |s, block| Inst(|env, pos| {
	(b2, out) = fire_block(block, In.{ outer: env, value: s }, pos)
	match out {
		Done => crash "fire"
		Pending(next) => {
			{ outer, value: s2 } = next
			(state_inst(s2, b2), Pending(outer))
		}
	}
})

block_inst : Block(ctx) -> Inst(ctx)
block_inst = |block| Inst(|env, pos| {
	(b2, out) = fire_block(block, env, pos)
	(block_inst(b2), out)
})

poke : List(U64) -> List(U64)
poke = |value| {
	{ list, prev } = value.replace(0, 0) ?? crash "empty"
	list.set(0, prev + 1) ?? crash "empty"
}

State(ctx, s) : { modify : (ctx, (s -> s) -> ctx) }

update : State(ctx, s), (s -> s) -> (ctx -> ctx)
update = |{ modify }, f| |e| modify(e, f)

handle : {} -> State(In(o, s), s)
handle = |_| {
	modify: |e, f| {
		{ outer, value } = e
		In.{ outer, value: f(value) }
	},
}

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = block_inst({ handlers: [], children: [state_inst(List.repeat(0, n), { handlers: [update(handle({}), poke)], children: [] })] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		(next, _) = call($r, {}, 0)
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
