app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

In(outer, s) := { outer : outer, value : s }
Handler(ctx) : { mask : U64, run : (ctx -> ctx) }
State(ctx, s) : { mask : U64, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }
Msg := [Fire(List(U32), U64, U32), Changed(U64)]
Out(ctx) := [Pending(ctx, U64)]
Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]
Tx : { cmds : List(U8), routes : List(List(U32)) }
Block(ctx) : { handlers : List(Handler(ctx)), children : List(Inst(ctx)) }

update : State(ctx, s), (s -> s) -> Handler(ctx)
update = |{ mask, get: _, modify }, f| { mask, run: |e| modify(e, f) }

noop : {} -> Inst(ctx)
noop = |_| Inst(|env, _msg, tx| (noop({}), Pending(env, 0), tx))

call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
call = |Inst(f), env, msg, tx| f(env, msg, tx)

fire_leaf : Block(ctx), ctx, U32, Tx -> (Block(ctx), Out(ctx), Tx)
fire_leaf = |block, env, h, tx| {
	match block.handlers.get(h.to_u64()) {
		Ok(handler) => (block, Pending((handler.run)(env), handler.mask), tx)
		Err(_) => (block, Pending(env, 0), tx)
	}
}

fire_kid : Block(ctx), ctx, List(U32), U64, U32, Tx -> (Block(ctx), Out(ctx), Tx)
fire_kid = |block, env, path, pos, h, tx| {
	k = (path.get(pos) ?? 0).to_u64()
	{ handlers, children } = block
	match children.replace(k, noop({})) {
		Ok({ list, prev }) => {
			(next, out, tx1) = call(prev, env, Fire(path, pos + 1, h), tx)
			({ handlers, children: list.set(k, next) ?? crash "child" }, out, tx1)
		}
		Err(_) => ({ handlers, children }, Pending(env, 0), tx)
	}
}

state_inst : s, Block(In(ctx, s)) -> Inst(ctx)
state_inst = |s, block| Inst(|env, msg, tx| {
	match msg {
		Changed(_) => (state_inst(s, block), Pending(env, 0), tx)
		Fire(_path, _pos, h) => {
			(b2, out, t2) = fire_leaf(block, In.{ outer: env, value: s }, h, tx)
			match out {
				Pending(next_inner, mask) => {
					{ outer: next_outer, value: s2 } = next_inner
					(state_inst(s2, b2), Pending(next_outer, mask), t2)
				}
			}
		}
	}
})

block_inst : Block(ctx) -> Inst(ctx)
block_inst = |block| Inst(|env, msg, tx| {
	match msg {
		Changed(_) => (block_inst(block), Pending(env, 0), tx)
		Fire(path, pos, h) => {
			(b2, out, t2) = fire_kid(block, env, path, pos, h, tx)
			(block_inst(b2), out, t2)
		}
	}
})

handle : {} -> State(In(o, s), s)
handle = |_| {
	mask: 2,
	get: |e| e.value,
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
	var $tx = { cmds: [], routes: [[0]] }
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		path = $tx.routes.get(0) ?? []
		(next, _, t2) = call($r, {}, Fire(path, 0, 0), $tx)
		$r = next
		$tx = t2
		$i = $i + 1
	}
	"1000 events: ${(Host.alloc_count!() - before).to_str()} allocations"
}
