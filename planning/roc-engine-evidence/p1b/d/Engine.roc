## Phase 1b engine, representation D: one closure per site.
##
## Every dynamic site (a state, a conditional, the root) is a single closure
## that captures that site's typed state and its block of mounted content, and
## takes a message. Only that closure references the state, so consuming the
## closure and rebuilding it updates the state in place (see the Phase 1b
## probe; two closures sharing a capture copy, roc-lang/roc#12841).
##
## Values are typed by an environment `ctx` that each state site extends:
## `In(outer, s)`. A `Val(ctx, a)` reads from that environment and records the
## absolute depths of the layers it reads (`mask`). A handler is an environment
## transformer; its result flows back up the dispatch path and each state site
## takes its own layer. Propagation starts at the highest changed layer and
## descends only into children whose read masks intersect the changed mask.
##
## Command stream (little endian), one List(U8):
##   1 ELEM id tag | 2 TEXT id str | 3 ATTR id name value | 4 APPEND parent child
##   5 INSERT parent child before | 6 REMOVE id | 7 SET_TEXT id str
##   8 LISTEN id event | 9 SET_ATTR id name value
## ids are u32, strings are u32 length + bytes.
Engine := [].{
	Root := [Root]

	In(outer, s) := { outer : outer, value : s }

	Val(ctx, a) := { mask : U64, read : (ctx -> a) }.{
		map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		map = |{ mask, read }, f| { mask, read: |env| f(read(env)) }

		map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		map2 = |l, r, f| {
			lr = l.read
			rr = r.read
			{ mask: l.mask.bitwise_or(r.mask), read: |env| f(lr(env), rr(env)) }
		}
	}

	Handler(ctx) := { mask : U64, run : (ctx -> ctx) }

	Attr(ctx) := [Static(Str, Str), Dyn(Str, Val(ctx, Str)), OnClick(Handler(ctx))]

	Elem(ctx) := [
		Element(Str, List(Attr(ctx)), List(Elem(ctx))),
		Text(Str),
		TextV(Val(ctx, Str)),
		Site(Mount(ctx)),
	]

	Args : { depth : U64, path : List(U32), parent : U32, before : U32 }

	Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

	Msg := [Fire(List(U32), U64, U32), Changed(U64), Dispose(Bool)]

	Out(ctx) := [Done, Pending(ctx, U64)]

	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

	Route := [NoRoute, Route(List(U32), U32)]

	Tx := { cmds : List(U8), next : U32, free : List(U32), routes : List(Route), evals : U64 }

	Hole(ctx) : { node : U32, mask : U64, attr : Str, read : (ctx -> Str), last : Str }

	Block(ctx) : {
		holes : List(Hole(ctx)),
		handlers : List(Handler(ctx)),
		children : List(Inst(ctx)),
		child_reads : List(U64),
		child_top : List(Bool),
		nodes : List(U32),
		tops : List(U32),
		reads : U64,
	}

	## ------------------------------------------------------------------
	## Command encoding.
	put_u32 : List(U8), U32 -> List(U8)
	put_u32 = |buf, v| buf.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

	put_str : List(U8), Str -> List(U8)
	put_str = |buf, s| {
		var $b = Engine.put_u32(buf, s.count_utf8_bytes().to_u32_wrap())
		for byte in s.iter_utf8() {
			$b = $b.append(byte)
		}
		$b
	}

	emit : Tx, (List(U8) -> List(U8)) -> Tx
	emit = |{ cmds, next, free, routes, evals }, write| { cmds: write(cmds), next, free, routes, evals }

	count_eval : Tx -> Tx
	count_eval = |{ cmds, next, free, routes, evals }| { cmds, next, free, routes, evals: evals + 1 }

	## Allocate a node id, reusing a freed one first.
	alloc_id : Tx -> (U32, Tx)
	alloc_id = |{ cmds, next, free, routes, evals }| {
		match free.last() {
			Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, evals })
			Err(_) => (next, { cmds, next: next + 1, free, routes, evals })
		}
	}

	## Release a node id and its route.
	free_id : Tx, U32 -> Tx
	free_id = |{ cmds, next, free, routes, evals }, id| {
		routes2 = if id.to_u64() < routes.len() routes.set(id.to_u64(), NoRoute) ?? routes else routes
		{ cmds, next, free: free.append(id), routes: routes2, evals }
	}

	set_route : Tx, U32, List(U32), U32 -> Tx
	set_route = |{ cmds, next, free, routes, evals }, id, path, handler| {
		var $r = routes
		while $r.len() <= id.to_u64() {
			$r = $r.append(NoRoute)
		}
		{ cmds, next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, evals }
	}

	## Attach a freshly created top-level node at the mount position.
	place : Tx, U32, U32, U32 -> Tx
	place = |tx, parent, before, id| {
		if before == 0 {
			Engine.emit(tx, |c| Engine.put_u32(Engine.put_u32(c.append(4), parent), id))
		} else {
			Engine.emit(tx, |c| Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(5), parent), id), before))
		}
	}

	bit : U64 -> U64
	bit = |depth| 1.U64.shl_wrap(depth.to_u8_wrap())

	## ------------------------------------------------------------------
	## Blocks: the static content of one site, flattened at mount.
	empty_block : {} -> Block(ctx)
	empty_block = |_| { holes: [], handlers: [], children: [], child_reads: [], child_top: [], nodes: [], tops: [], reads: 0 }

	## Mount one description into `block`. `top` says whether it sits directly at
	## the block's insertion point (so the block must remove it on dispose).
	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Tx -> (Block(ctx), Tx)
	mount_elem = |block, env, elem, depth, path, parent, before, top, tx| {
		match elem {
			Element(tag, attrs, kids) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(c.append(1), id), tag))
				var $b = Engine.add_node(block, id, top)
				var $t = tx2
				for attr in attrs {
					(b2, t2) = Engine.mount_attr($b, env, attr, id, path, $t)
					$b = b2
					$t = t2
				}
				for kid in kids {
					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, $t)
					$b = b3
					$t = t3
				}
				t4 = if top Engine.place($t, parent, before, id) else Engine.place($t, parent, 0, id)
				($b, t4)
			}
			Text(s) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(c.append(2), id), s))
				tx3 = if top Engine.place(tx2, parent, before, id) else Engine.place(tx2, parent, 0, id)
				(Engine.add_node(block, id, top), tx3)
			}
			TextV({ mask, read }) => {
				(id, tx1) = Engine.alloc_id(tx)
				s = read(env)
				tx2 = Engine.emit(Engine.count_eval(tx1), |c| Engine.put_str(Engine.put_u32(c.append(2), id), s))
				tx3 = if top Engine.place(tx2, parent, before, id) else Engine.place(tx2, parent, 0, id)
				b1 = Engine.add_node(block, id, top)
				(Engine.add_hole(b1, { node: id, mask, attr: "", read, last: s }), tx3)
			}
			Site(Mount(mount)) => {
				k = block.children.len().to_u32_wrap()
				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: if top before else 0 }, tx)
				(Engine.add_child(block, inst, reads, top), tx1)
			}
		}
	}

	mount_attr : Block(ctx), ctx, Attr(ctx), U32, List(U32), Tx -> (Block(ctx), Tx)
	mount_attr = |block, env, attr, id, path, tx| {
		match attr {
			Static(name, value) => (block, Engine.emit(tx, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c.append(3), id), name), value)))
			Dyn(name, { mask, read }) => {
				v = read(env)
				tx1 = Engine.emit(Engine.count_eval(tx), |c| Engine.put_str(Engine.put_str(Engine.put_u32(c.append(3), id), name), v))
				(Engine.add_hole(block, { node: id, mask, attr: name, read, last: v }), tx1)
			}
			OnClick(handler) => {
				h = block.handlers.len().to_u32_wrap()
				tx1 = Engine.emit(tx, |c| Engine.put_str(Engine.put_u32(c.append(8), id), "click"))
				(Engine.add_handler(block, handler), Engine.set_route(tx1, id, path, h))
			}
		}
	}

	add_node : Block(ctx), U32, Bool -> Block(ctx)
	add_node = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, id, top| {
		{ holes, handlers, children, child_reads, child_top, nodes: nodes.append(id), tops: if top tops.append(id) else tops, reads }
	}

	add_hole : Block(ctx), Hole(ctx) -> Block(ctx)
	add_hole = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, hole| {
		m = hole.mask
		{ holes: holes.append(hole), handlers, children, child_reads, child_top, nodes, tops, reads: reads.bitwise_or(m) }
	}

	add_handler : Block(ctx), Handler(ctx) -> Block(ctx)
	add_handler = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, h| {
		{ holes, handlers: handlers.append(h), children, child_reads, child_top, nodes, tops, reads }
	}

	add_child : Block(ctx), Inst(ctx), U64, Bool -> Block(ctx)
	add_child = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, inst, r, top| {
		{ holes, handlers, children: children.append(inst), child_reads: child_reads.append(r), child_top: child_top.append(top), nodes, tops, reads: reads.bitwise_or(r) }
	}

	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Tx -> (Block(ctx), Tx)
	mount_block = |env, elem, depth, path, parent, before, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, tx)

	noop : {} -> Inst(ctx)
	noop = |_| Inst(|_env, _msg, tx| (Engine.noop({}), Done, tx))

	call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
	call = |Inst(f), env, msg, tx| f(env, msg, tx)

	## Re-evaluate the holes that read a changed layer, then descend into the
	## children whose subtrees read one.
	refresh : Block(ctx), ctx, U64, Tx -> (Block(ctx), Tx)
	refresh = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, env, mask, tx| {
		var $holes = holes
		var $tx = tx
		var $i = 0.U64
		while $i < $holes.len() {
			hm = $holes.get($i).map_ok(|h| h.mask) ?? 0
			if hm.bitwise_and(mask) != 0 {
				{ list, prev } = $holes.replace($i, { node: 0, mask: 0, attr: "", read: |_| "", last: "" }) ?? crash "hole"
				{ node, mask: m, attr, read, last } = prev
				v = read(env)
				t1 = Engine.count_eval($tx)
				if v == last {
					$holes = list.set($i, { node, mask: m, attr, read, last }) ?? crash "hole"
					$tx = t1
				} else {
					is_text = attr.is_empty()
					$tx = if is_text {
						Engine.emit(t1, |c| Engine.put_str(Engine.put_u32(c.append(7), node), v))
					} else {
						Engine.emit(t1, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c.append(9), node), attr), v))
					}
					$holes = list.set($i, { node, mask: m, attr, read, last: v }) ?? crash "hole"
				}
			}
			$i = $i + 1
		}
		var $kids = children
		var $j = 0.U64
		while $j < $kids.len() {
			r = child_reads.get($j) ?? 0
			if r.bitwise_and(mask) != 0 {
				{ list, prev } = $kids.replace($j, Engine.noop({})) ?? crash "child"
				(next, _, t2) = Engine.call(prev, env, Changed(mask), $tx)
				$kids = list.set($j, next) ?? crash "child"
				$tx = t2
			}
			$j = $j + 1
		}
		({ holes: $holes, handlers, children: $kids, child_reads, child_top, nodes, tops, reads }, $tx)
	}

	## Route a click down the site path; the owning block runs the handler.
	fire_block : Block(ctx), ctx, List(U32), U64, U32, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_block = |block, env, path, pos, h, tx| {
		if pos >= path.len() {
			handler = block.handlers.get(h.to_u64()) ?? crash "missing handler"
			next_env = (handler.run)(env)
			(block, Pending(next_env, handler.mask), tx)
		} else {
			k = (path.get(pos) ?? 0).to_u64()
			{ holes, handlers, children, child_reads, child_top, nodes, tops, reads } = block
			{ list, prev } = children.replace(k, Engine.noop({})) ?? crash "missing child site"
			(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
			({ holes, handlers, children: list.set(k, next) ?? crash "child", child_reads, child_top, nodes, tops, reads }, out, tx1)
		}
	}

	dispose_block : Block(ctx), ctx, Bool, Tx -> Tx
	dispose_block = |{ holes: _, handlers: _, children, child_reads: _, child_top, nodes, tops, reads: _ }, env, remove, tx| {
		var $tx = tx
		var $j = 0.U64
		for kid in children {
			kid_top = child_top.get($j) ?? False
			(_, _, t1) = Engine.call(kid, env, Dispose(remove and kid_top), $tx)
			$tx = t1
			$j = $j + 1
		}
		if remove {
			for id in tops {
				$tx = Engine.emit($tx, |c| Engine.put_u32(c.append(6), id))
			}
		}
		for id in nodes {
			$tx = Engine.free_id($tx, id)
		}
		$tx
	}

	## ------------------------------------------------------------------
	## Site kinds.

	## A state site: `s` is this layer's value at absolute depth `depth`.
	state_inst : s, Block(In(ctx, s)), U64 -> Inst(ctx)
		where [s.is_eq : s, s -> Bool]
	state_inst = |s, block, depth| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				(b2, t2) = Engine.refresh(block, In.{ outer: env, value: s }, mask, tx)
				(Engine.state_inst(s, b2, depth), Done, t2)
			}
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_block(block, In.{ outer: env, value: s }, path, pos, h, tx)
				match out {
					Done => (Engine.state_inst(s, b2, depth), Done, t2)
					Pending(next_inner, mask) => {
						{ outer: next_outer, value: s2 } = next_inner
						own = Engine.bit(depth)
						targeted = mask.bitwise_and(own) != 0
						changed = targeted and s2 != s
						mask2 = if changed mask else mask.bitwise_and(own.bitwise_not())
						above = mask2.bitwise_and(own - 1)
						s_new = if changed s2 else s
						if above != 0 {
							(Engine.state_inst(s_new, b2, depth), Pending(next_outer, mask2), t2)
						} else if mask2 == 0 {
							(Engine.state_inst(s_new, b2, depth), Done, t2)
						} else {
							(b3, t3) = Engine.refresh(b2, In.{ outer: env, value: s_new }, mask2, t2)
							(Engine.state_inst(s_new, b3, depth), Done, t3)
						}
					}
				}
			}
			Dispose(remove) => {
				t2 = Engine.dispose_block(block, In.{ outer: env, value: s }, remove, tx)
				(Engine.noop({}), Done, t2)
			}
		}
	})

	## A conditional site. The branch is rebuilt when the condition changes.
	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, parent : U32, depth : U64, path : List(U32) }

	when_inst : When(ctx), Bool, Block(ctx) -> Inst(ctx)
	when_inst = |w, cur, block| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				cm = w.cond.mask
				if cm.bitwise_and(mask) != 0 {
					c = (w.cond.read)(env)
					t1 = Engine.count_eval(tx)
					if c == cur {
						(b2, t2) = Engine.refresh(block, env, mask, t1)
						(Engine.when_inst(w, cur, b2), Done, t2)
					} else {
						t2 = Engine.dispose_block(block, env, True, t1)
						elem = if c (w.yes)() else (w.no)()
						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, w.parent, w.anchor, t2)
						(Engine.when_inst(w, c, b3), Done, t3)
					}
				} else {
					(b2, t2) = Engine.refresh(block, env, mask, tx)
					(Engine.when_inst(w, cur, b2), Done, t2)
				}
			}
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_block(block, env, path, pos, h, tx)
				(Engine.when_inst(w, cur, b2), out, t2)
			}
			Dispose(remove) => {
				t1 = Engine.dispose_block(block, env, remove, tx)
				t2 = if remove Engine.emit(t1, |c| Engine.put_u32(c.append(6), w.anchor)) else t1
				(Engine.noop({}), Done, Engine.free_id(t2, w.anchor))
			}
		}
	})

	## A plain block site (the root).
	block_inst : Block(ctx) -> Inst(ctx)
	block_inst = |block| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				(b2, t2) = Engine.refresh(block, env, mask, tx)
				(Engine.block_inst(b2), Done, t2)
			}
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_block(block, env, path, pos, h, tx)
				(Engine.block_inst(b2), out, t2)
			}
			Dispose(remove) => (Engine.noop({}), Done, Engine.dispose_block(block, env, remove, tx))
		}
	})

	## ------------------------------------------------------------------
	## Application-facing constructors.

	## A state handle for the layer at `depth`.
	State(ctx, s) := { depth : U64 }.{
		val : State(ctx, s) -> Val(In(ctx, s), s)
		val = |st| { mask: Engine.bit(st.depth), read: |e| e.value }

		update : State(ctx, s), (s -> s) -> Handler(In(ctx, s))
		update = |st, f| { mask: Engine.bit(st.depth), run: |e| In.{ outer: e.outer, value: f(e.value) } }

		## Read a value of the enclosing context inside this state's body.
		lift : State(ctx, s), Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |_st, { mask, read }| { mask, read: |e| read(e.outer) }

		## Use a handler of the enclosing context inside this state's body.
		lift_handler : State(ctx, s), Handler(ctx) -> Handler(In(ctx, s))
		lift_handler = |_st, { mask, run }| { mask, run: |e| In.{ outer: run(e.outer), value: e.value } }
	}

	state : s, (State(ctx, s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [s.is_eq : s, s -> Bool]
	state = |init, body| Site(Mount(|env, args, tx| {
		depth = args.depth + 1
		elem = body(State.{ depth: depth })
		(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, tx)
		reads = block.reads
		(Engine.state_inst(init, block, depth), reads, tx1)
	}))

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Site(Mount(|env, args, tx| {
		(anchor, tx1) = Engine.alloc_id(tx)
		tx2 = Engine.place(Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(c.append(2), anchor), "")), args.parent, args.before, anchor)
		c = (cond.read)(env)
		elem = if c yes() else no()
		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, args.parent, anchor, Engine.count_eval(tx2))
		reads = block.reads.bitwise_or(cond.mask)
		w = { cond, yes, no, anchor, parent: args.parent, depth: args.depth, path: args.path }
		(Engine.when_inst(w, c, block), reads, tx3)
	}))

	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value }

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Element(tag, attrs, kids)

	text : Str -> Elem(ctx)
	text = |s| Text(s)

	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| TextV(v)

	class : Str -> Attr(ctx)
	class = |c| Static("class", c)

	test_id : Str -> Attr(ctx)
	test_id = |c| Static("data-testid", c)

	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| Dyn("class", v)

	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| OnClick(h)

	## ------------------------------------------------------------------
	## The engine state the host would hold in one Box.
	App := { root : Inst(Root), tx : Tx }

	new_tx : {} -> Tx
	new_tx = |_| { cmds: [], next: 1, free: [], routes: [], evals: 0 }

	## Mount the application under host node 0.
	mount : Elem(Root), U32 -> App
	mount = |elem, first_id| {
		{ cmds, next: _, free, routes, evals } = Engine.new_tx({})
		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, { cmds, next: first_id, free, routes, evals })
		{ root: Engine.block_inst(block), tx }
	}

	## Deliver a click on host node `id`. Commands accumulate in `tx.cmds`; the
	## host takes them with `take_cmds`.
	click : App, U32 -> App
	click = |{ root, tx }, id| {
		route = tx.routes.get(id.to_u64()) ?? NoRoute
		match route {
			NoRoute => { root, tx }
			Route(path, h) => {
				(root2, _, tx2) = Engine.call(root, Root, Fire(path, 0, h), tx)
				{ root: root2, tx: tx2 }
			}
		}
	}

	## Hand the accumulated commands to the host and reuse the buffer.
	take_cmds : App -> (App, List(U8))
	take_cmds = |{ root, tx }| {
		{ cmds, next, free, routes, evals } = tx
		({ root, tx: { cmds: List.with_capacity(cmds.len()), next, free, routes, evals } }, cmds)
	}

	evals : App -> U64
	evals = |a| a.tx.evals
}
