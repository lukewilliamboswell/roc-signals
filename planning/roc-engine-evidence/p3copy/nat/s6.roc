app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

In(outer, s) := { outer : outer, value : s }
Handler(ctx) : { mask : U64, run : (ctx -> ctx) }
State(ctx, s) : { mask : U64, modify : (ctx, (s -> s) -> ctx) }
Msg := [Fire(List(U32), U64, U32)]
Out(ctx) := [Pending(ctx, U64)]
Inst(ctx) := [Inst((ctx, Msg -> (Inst(ctx), Out(ctx))))]
Block(ctx) : { handlers : List(Handler(ctx)), children : List(Inst(ctx)) }

update : State(ctx, s), (s -> s) -> Handler(ctx)
update = |{ mask, modify }, f| { mask, run: |e| modify(e, f) }

noop : {} -> Inst(ctx)
noop = |_| Inst(|env, _msg| (noop({}), Pending(env, 0)))

call : Inst(ctx), ctx, Msg -> (Inst(ctx), Out(ctx))
call = |Inst(f), env, msg| f(env, msg)

fire_leaf : Block(ctx), ctx, U32 -> (Block(ctx), Out(ctx))
fire_leaf = |block, env, h| {
	match block.handlers.get(h.to_u64()) {
		Ok(handler) => (block, Pending((handler.run)(env), handler.mask))
		Err(_) => (block, Pending(env, 0))
	}
}

fire_kid : Block(ctx), ctx, List(U32), U64, U32 -> (Block(ctx), Out(ctx))
fire_kid = |block, env, path, pos, h| {
	k = (path.get(pos) ?? 0).to_u64()
	{ handlers, children } = block
	match children.replace(k, noop({})) {
		Ok({ list, prev }) => {
			(next, out) = call(prev, env, Fire(path, pos + 1, h))
			({ handlers, children: list.set(k, next) ?? crash "child" }, out)
		}
		Err(_) => ({ handlers, children }, Pending(env, 0))
	}
}

state_inst : s, Block(In(ctx, s)) -> Inst(ctx)
state_inst = |s, block| Inst(|env, msg| {
	match msg {
		Fire(_path, _pos, h) => {
			(b2, out) = fire_leaf(block, In.{ outer: env, value: s }, h)
			match out {
				Pending(next_inner, mask) => {
					{ outer: next_outer, value: s2 } = next_inner
					(state_inst(s2, b2), Pending(next_outer, mask))
				}
			}
		}
	}
})

block_inst : Block(ctx) -> Inst(ctx)
block_inst = |block| Inst(|env, msg| {
	match msg {
		Fire(path, pos, h) => {
			(b2, out) = fire_kid(block, env, path, pos, h)
			(block_inst(b2), out)
		}
	}
})

handle : {} -> State(In(o, s), s)
handle = |_| {
	mask: 2,
	modify: |e, f| {
		{ outer, value } = e
		In.{ outer, value: f(value) }
	},
}

poke : List(U64) -> List(U64)
poke = |xs| {
	{ list, prev } = xs.replace(0, 0) ?? crash "empty"
	list.set(0, prev + 1) ?? crash "empty"
}

run! : Str => Str
run! = |input| {
	n = 1_000_000 + Str.count_utf8_bytes(input)
	var $r = block_inst({ handlers: [], children: [state_inst(List.repeat(0, n), { handlers: [update(handle({}), poke)], children: [] })] })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		path = [0]
		(next, _) = call($r, {}, Fire(path, 0, 0))
		$r = next
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
