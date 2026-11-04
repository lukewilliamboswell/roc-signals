app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

Engine := [].{
	Root := [Root]
	In(outer, s) := { outer : outer, value : s }
	Handler(ctx) := { mask : U64, run : (ctx -> ctx) }
	State(ctx, s) := { mask : U64, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }.{
		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ mask, get: _, modify }, f| { mask, run: |e| modify(e, f) }
	}
	Attr(ctx) := [Static(Str, Str), On(Str, Handler(ctx))]
	Elem(ctx) := [Element(Str, List(Attr(ctx)), List(Elem(ctx))), Site(Mount(ctx))]
	Mount(ctx) := [Mount((ctx, Tx -> (Inst(ctx), Tx)))]
	Msg := [Fire(List(U32), U64, U32), Changed(U64)]
	Out(ctx) := [Pending(ctx, U64)]
	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]
	Tx : { cmds : List(U8), routes : List(List(U32)) }
	Block(ctx) : { handlers : List(Handler(ctx)), children : List(Inst(ctx)) }

	mount_elem : Block(ctx), ctx, Elem(ctx), List(U32), Tx -> (Block(ctx), Tx)
	mount_elem = |block, env, elem, path, tx| {
		match elem {
			Element(_tag, attrs, kids) => {
				var $b = block
				var $t = tx
				for attr in attrs {
					match attr {
						Static(_, _) => {}
						On(_, h) => {
							{ handlers, children } = $b
							$b = { handlers: handlers.append(h), children }
							{ cmds, routes } = $t
							$t = { cmds: cmds.append(11), routes: routes.append(path) }
						}
					}
				}
				for kid in kids {
					(b3, t3) = Engine.mount_elem($b, env, kid, path, $t)
					$b = b3
					$t = t3
				}
				($b, $t)
			}
			Site(Mount(mount)) => {
				k = block.children.len().to_u32_wrap()
				{ handlers, children } = block
				_ = k
				(inst, tx1) = mount(env, tx)
				({ handlers, children: children.append(inst) }, tx1)
			}
		}
	}

	noop : {} -> Inst(ctx)
	noop = |_| Inst(|env, msg, tx| {
		match msg {
			Fire(_, _, _) => (Engine.noop({}), Pending(env, 0), tx)
			Changed(_) => (Engine.noop({}), Pending(env, 0), tx)
		}
	})

	call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
	call = |Inst(f), env, msg, tx| f(env, msg, tx)

	fire_leaf : Block(ctx), ctx, U32, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_leaf = |block, env, h, tx| {
		match block.handlers.get(h.to_u64()) {
			Ok(handler) => {
				next_env = (handler.run)(env)
				(block, Pending(next_env, handler.mask), tx)
			}
			Err(_) => (block, Pending(env, 0), tx)
		}
	}

	fire_kid : Block(ctx), ctx, List(U32), U64, U32, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_kid = |block, env, path, pos, h, tx| {
		k = (path.get(pos) ?? 0).to_u64()
		{ handlers, children } = block
		match children.replace(k, Engine.noop({})) {
			Ok({ list, prev }) => {
				(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
				({ handlers, children: list.set(k, next) ?? crash "child" }, out, tx1)
			}
			Err(_) => ({ handlers, children }, Pending(env, 0), tx)
		}
	}

	state_inst : s, Block(In(ctx, s)) -> Inst(ctx)
	state_inst = |s, block| Inst(|env, msg, tx| {
		match msg {
			Changed(_) => (Engine.state_inst(s, block), Pending(env, 0), tx)
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_leaf(block, In.{ outer: env, value: s }, h, tx)
				match out {
					Pending(next_inner, mask) => {
						{ outer: next_outer, value: s2 } = next_inner
						(Engine.state_inst(s2, b2), Pending(next_outer, mask), t2)
					}
				}
			}
		}
	})

	block_inst : Block(ctx) -> Inst(ctx)
	block_inst = |block| Inst(|env, msg, tx| {
		match msg {
			Changed(_) => (Engine.block_inst(block), Pending(env, 0), tx)
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_kid(block, env, path, pos, h, tx)
				(Engine.block_inst(b2), out, t2)
			}
		}
	})

	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Site(Mount(|env, tx| {
		handle = {
			mask: 2,
			get: |e| e.value,
			modify: |e, f| {
				{ outer, value } = e
				In.{ outer, value: f(value) }
			},
		}
		elem = body(handle)
		(block, tx1) = Engine.mount_elem({ handlers: [], children: [] }, In.{ outer: env, value: init }, elem, [0], tx)
		(Engine.state_inst(init, block), tx1)
	}))

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Element(tag, attrs, kids)
	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Static(name, value)
	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| On("click", h)

	App := { root : Inst(Root), tx : Tx }

	Program(state) : {
		init : () -> (state, List(U8)),
		event : state, List(U8), U32, U32 -> (state, List(U8)),
	}

	program : (() -> Elem(Root)) -> Program(App)
	program = |view| {
		init: || {
			(block, tx) = Engine.mount_elem({ handlers: [], children: [] }, Root, view(), [], { cmds: [], routes: [] })
			({ root: Engine.block_inst(block), tx: { cmds: [], routes: tx.routes } }, [])
		},
		event: |inst, buf, node, _handler| {
			{ root, tx } = inst
			{ cmds: _, routes } = tx
			match routes.get(node.to_u64()) {
				Ok(path) => {
					(root2, _, tx2) = Engine.call(root, Root, Fire(path, 0, 0), { cmds: buf.clear(), routes })
					{ cmds, routes: r2 } = tx2
					({ root: root2, tx: { cmds: [], routes: r2 } }, cmds)
				}
				Err(_) => ({ root, tx: { cmds: [], routes } }, buf)
			}
		},
	}
}

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
	prog = Engine.program(|| Engine.state(seq(n), |st| Engine.element("button", [Engine.attr("id", "b"), Engine.on_click(st.update(poke))], [])))
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
