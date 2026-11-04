## Phase 2 size spike, restructuring R1: a thin context-generic shim over a
## context-free core.
##
## Same application API as Phase 1b's representation D. The difference is the
## description: `Elem(ctx)` is split by its builders into a context-free
## skeleton (`Skel`, plain data) and a preorder list of the dynamic parts that
## touch `ctx` (`Dyn(ctx)`: a read, a click handler, or a child site). Mounting
## evaluates the reads in one generic loop, then hands plain strings and masks
## to `build`, which writes every command, allocates ids, records routes and
## returns a context-free `Frame`. Refresh, fire and dispose likewise only call
## `read`, `run` and child instances generically; hole comparison, command
## writing, mask checks and node release are context-free.
##
## Command stream as in Phase 1b, except that a child site at a non-final
## position is inserted before its next static sibling (INSERT) instead of
## being appended while its parent is built.
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

	## Context-free skeleton. Holes are consumed in preorder: an element's
	## attribute holes, then its children.
	SAttr := [SStatic(Str, Str), SDyn(Str), SClick]
	Skel := [SNode(Str, List(SAttr), List(Skel)), SText(Str), SDynText, SSite]

	Dyn(ctx) := [DRead(Val(ctx, Str)), DClick(Handler(ctx)), DSite(Mount(ctx))]

	Elem(ctx) := { skel : Skel, dyns : List(Dyn(ctx)) }

	Args : { depth : U64, path : List(U32), parent : U32, before : U32 }

	Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

	Msg := [Fire(List(U32), U64, U32), Changed(U64), Dispose(Bool)]

	Out(ctx) := [Done, Pending(ctx, U64)]

	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

	Route := [NoRoute, Route(List(U32), U32)]

	Tx := { cmds : List(U8), next : U32, free : List(U32), routes : List(Route), evals : U64 }

	## Context-free per-hole state; `reads` in the block is aligned with `holes`.
	HoleF : { node : U32, mask : U64, attr : Str, last : Str }

	## Where a child site mounts; aligned with the block's `children`.
	SitePos : { parent : U32, before : U32, top : Bool, reads : U64 }

	Frame : {
		holes : List(HoleF),
		sites : List(SitePos),
		nodes : List(U32),
		tops : List(U32),
		reads : U64,
	}

	Block(ctx) : { frame : Frame, reads : List(Val(ctx, Str)), handlers : List(Handler(ctx)), children : List(Inst(ctx)) }

	## ------------------------------------------------------------------
	## Context-free core.
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

	cmd_id : Tx, U8, U32 -> Tx
	cmd_id = |{ cmds, next, free, routes, evals }, op, id| { cmds: Engine.put_u32(cmds.append(op), id), next, free, routes, evals }

	cmd_id_str : Tx, U8, U32, Str -> Tx
	cmd_id_str = |{ cmds, next, free, routes, evals }, op, id, s| { cmds: Engine.put_str(Engine.put_u32(cmds.append(op), id), s), next, free, routes, evals }

	cmd_id_str2 : Tx, U8, U32, Str, Str -> Tx
	cmd_id_str2 = |{ cmds, next, free, routes, evals }, op, id, a, b| { cmds: Engine.put_str(Engine.put_str(Engine.put_u32(cmds.append(op), id), a), b), next, free, routes, evals }

	count_eval : Tx -> Tx
	count_eval = |{ cmds, next, free, routes, evals }| { cmds, next, free, routes, evals: evals + 1 }

	alloc_id : Tx -> (U32, Tx)
	alloc_id = |{ cmds, next, free, routes, evals }| {
		match free.last() {
			Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, evals })
			Err(_) => (next, { cmds, next: next + 1, free, routes, evals })
		}
	}

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

	place : Tx, U32, U32, U32 -> Tx
	place = |{ cmds, next, free, routes, evals }, parent, before, id| {
		c2 = if before == 0 {
			Engine.put_u32(Engine.put_u32(cmds.append(4), parent), id)
		} else {
			Engine.put_u32(Engine.put_u32(Engine.put_u32(cmds.append(5), parent), id), before)
		}
		{ cmds: c2, next, free, routes, evals }
	}

	bit : U64 -> U64
	bit = |depth| 1.U64.shl_wrap(depth.to_u8_wrap())

	## Build state threaded through the skeleton walk. `pending` holds sites
	## waiting for their next static sibling, which becomes their `before`.
	B : {
		frame : Frame,
		tx : Tx,
		cursor : U64,
		handler : U32,
		pending : List(U64),
	}

	## Build a skeleton. `vals`/`masks` are aligned with the block's dynamic
	## parts in preorder (empty string and 0 for non-reads). Child-site
	## positions are recorded in `frame.sites`; the caller mounts them.
	build : Skel, List(Str), List(U64), List(U32), U32, U32, Tx -> (Frame, Tx)
	build = |skel, vals, masks, path, parent, before, tx| {
		frame0 = { holes: [], sites: [], nodes: [], tops: [], reads: 0 }
		b0 = { frame: frame0, tx, cursor: 0, handler: 0, pending: [] }
		b1 = Engine.build_kid(b0, skel, vals, masks, path, parent, before, True)
		b2 = Engine.close_pending(b1, before)
		(b2.frame, b2.tx)
	}

	close_pending : B, U32 -> B
	close_pending = |{ frame, tx, cursor, handler, pending }, before| {
		{ holes, sites, nodes, tops, reads } = frame
		var $s = sites
		for k in pending {
			$s = $s.update(k, |p| { parent: p.parent, before, top: p.top, reads: p.reads }) ?? $s
		}
		{ frame: { holes, sites: $s, nodes, tops, reads }, tx, cursor, handler, pending: [] }
	}

	add_node : B, U32, Bool -> B
	add_node = |{ frame, tx, cursor, handler, pending }, id, top| {
		{ holes, sites, nodes, tops, reads } = frame
		f2 = { holes, sites, nodes: nodes.append(id), tops: if top tops.append(id) else tops, reads }
		{ frame: f2, tx, cursor, handler, pending }
	}

	add_hole : B, U32, Str, Str, U64 -> B
	add_hole = |{ frame, tx, cursor, handler, pending }, id, attr, v, m| {
		{ holes, sites, nodes, tops, reads } = frame
		f2 = { holes: holes.append({ node: id, mask: m, attr, last: v }), sites, nodes, tops, reads: reads.bitwise_or(m) }
		{ frame: f2, tx: Engine.count_eval(tx), cursor: cursor + 1, handler, pending }
	}

	with_tx : B, Tx -> B
	with_tx = |{ frame, tx: _, cursor, handler, pending }, tx| { frame, tx, cursor, handler, pending }

	build_kid : B, Skel, List(Str), List(U64), List(U32), U32, U32, Bool -> B
	build_kid = |b, skel, vals, masks, path, parent, before, top| {
		at = if top before else 0
		match skel {
			SNode(tag, attrs, kids) => {
				(id, tx1) = Engine.alloc_id(b.tx)
				var $b = Engine.add_node(Engine.with_tx(b, Engine.cmd_id_str(tx1, 1, id, tag)), id, top)
				for attr in attrs {
					$b = match attr {
						SStatic(name, value) => Engine.with_tx($b, Engine.cmd_id_str2($b.tx, 3, id, name, value))
						SDyn(name) => {
							v = vals.get($b.cursor) ?? ""
							m = masks.get($b.cursor) ?? 0
							b2 = Engine.with_tx($b, Engine.cmd_id_str2($b.tx, 3, id, name, v))
							Engine.add_hole(b2, id, name, v, m)
						}
						SClick => {
							t1 = Engine.set_route(Engine.cmd_id_str($b.tx, 8, id, "click"), id, path, $b.handler)
							{ frame, tx: _, cursor, handler, pending } = $b
							{ frame, tx: t1, cursor: cursor + 1, handler: handler + 1, pending }
						}
					}
				}
				outer_pending = $b.pending
				$b = { frame: $b.frame, tx: $b.tx, cursor: $b.cursor, handler: $b.handler, pending: [] }
				for kid in kids {
					$b = Engine.build_kid($b, kid, vals, masks, path, id, 0, False)
				}
				b3 = Engine.close_pending($b, 0)
				{ frame, tx, cursor, handler, pending: _ } = b3
				t4 = Engine.place(tx, parent, at, id)
				Engine.static_done({ frame, tx: t4, cursor, handler, pending: outer_pending }, id)
			}
			SText(s) => {
				(id, tx1) = Engine.alloc_id(b.tx)
				t2 = Engine.place(Engine.cmd_id_str(tx1, 2, id, s), parent, at, id)
				Engine.static_done(Engine.add_node(Engine.with_tx(b, t2), id, top), id)
			}
			SDynText => {
				(id, tx1) = Engine.alloc_id(b.tx)
				v = vals.get(b.cursor) ?? ""
				m = masks.get(b.cursor) ?? 0
				t2 = Engine.place(Engine.cmd_id_str(tx1, 2, id, v), parent, at, id)
				Engine.static_done(Engine.add_hole(Engine.add_node(Engine.with_tx(b, t2), id, top), id, "", v, m), id)
			}
			SSite => {
				{ frame, tx, cursor, handler, pending } = b
				{ holes, sites, nodes, tops, reads } = frame
				k = sites.len()
				f2 = { holes, sites: sites.append({ parent, before: at, top, reads: 0 }), nodes, tops, reads }
				{ frame: f2, tx, cursor: cursor + 1, handler, pending: pending.append(k) }
			}
		}
	}

	## A static node `id` was just placed: pending sites go before it.
	static_done : B, U32 -> B
	static_done = |b, id| if b.pending.is_empty() b else Engine.close_pending(b, id)

	hole_hits : Frame, U64 -> List(U64)
	hole_hits = |frame, mask| {
		var $out = []
		var $i = 0.U64
		for h in frame.holes {
			if h.mask.bitwise_and(mask) != 0 {
				$out = $out.append($i)
			}
			$i = $i + 1
		}
		$out
	}

	site_hits : Frame, U64 -> List(U64)
	site_hits = |frame, mask| {
		var $out = []
		var $i = 0.U64
		for s in frame.sites {
			if s.reads.bitwise_and(mask) != 0 {
				$out = $out.append($i)
			}
			$i = $i + 1
		}
		$out
	}

	## Store a re-evaluated hole value, emitting a command only if it changed.
	set_hole : Frame, U64, Str, Tx -> (Frame, Tx)
	set_hole = |{ holes, sites, nodes, tops, reads }, i, v, tx| {
		{ list, prev } = holes.replace(i, { node: 0, mask: 0, attr: "", last: "" }) ?? crash "hole"
		{ node, mask, attr, last } = prev
		t1 = Engine.count_eval(tx)
		if v == last {
			({ holes: list.set(i, { node, mask, attr, last }) ?? crash "hole", sites, nodes, tops, reads }, t1)
		} else {
			t2 = if attr.is_empty() Engine.cmd_id_str(t1, 7, node, v) else Engine.cmd_id_str2(t1, 9, node, attr, v)
			({ holes: list.set(i, { node, mask, attr, last: v }) ?? crash "hole", sites, nodes, tops, reads }, t2)
		}
	}

	set_site_reads : Frame, U64, U64 -> Frame
	set_site_reads = |{ holes, sites, nodes, tops, reads }, k, r| {
		s2 = sites.update(k, |p| { parent: p.parent, before: p.before, top: p.top, reads: r }) ?? sites
		{ holes, sites: s2, nodes, tops, reads: reads.bitwise_or(r) }
	}

	site_pos : Frame, U64 -> SitePos
	site_pos = |frame, k| frame.sites.get(k) ?? crash "site"

	dispose_frame : Frame, Bool, Tx -> Tx
	dispose_frame = |{ holes: _, sites: _, nodes, tops, reads: _ }, remove, tx| {
		var $tx = tx
		if remove {
			for id in tops {
				$tx = Engine.cmd_id($tx, 6, id)
			}
		}
		for id in nodes {
			$tx = Engine.free_id($tx, id)
		}
		$tx
	}

	site_removes : Frame, U64, Bool -> Bool
	site_removes = |frame, k, remove| remove and ((frame.sites.get(k) ?? { parent: 0, before: 0, top: False, reads: 0 }).top)

	## ------------------------------------------------------------------
	## Context-generic shim.
	noop : {} -> Inst(ctx)
	noop = |_| Inst(|_env, _msg, tx| (Engine.noop({}), Done, tx))

	call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
	call = |Inst(f), env, msg, tx| f(env, msg, tx)

	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Tx -> (Block(ctx), Tx)
	mount_block = |env, { skel, dyns }, depth, path, parent, before, tx| {
		var $vals = List.with_capacity(dyns.len())
		var $masks = List.with_capacity(dyns.len())
		var $reads = []
		var $handlers = []
		var $mounts = []
		for d in dyns {
			match d {
				DRead(v) => {
					$vals = $vals.append((v.read)(env))
					$masks = $masks.append(v.mask)
					$reads = $reads.append(v)
				}
				DClick(h) => {
					$vals = $vals.append("")
					$masks = $masks.append(0)
					$handlers = $handlers.append(h)
				}
				DSite(m) => {
					$vals = $vals.append("")
					$masks = $masks.append(0)
					$mounts = $mounts.append(m)
				}
			}
		}
		(frame0, tx1) = Engine.build(skel, $vals, $masks, path, parent, before, tx)
		var $frame = frame0
		var $tx = tx1
		var $kids = List.with_capacity($mounts.len())
		var $k = 0.U64
		for Mount(m) in $mounts {
			pos = Engine.site_pos($frame, $k)
			(inst, r, t2) = m(env, { depth, path: path.append($k.to_u32_wrap()), parent: pos.parent, before: pos.before }, $tx)
			$frame = Engine.set_site_reads($frame, $k, r)
			$kids = $kids.append(inst)
			$tx = t2
			$k = $k + 1
		}
		({ frame: $frame, reads: $reads, handlers: $handlers, children: $kids }, $tx)
	}

	refresh : Block(ctx), ctx, U64, Tx -> (Block(ctx), Tx)
	refresh = |{ frame, reads, handlers, children }, env, mask, tx| {
		var $frame = frame
		var $tx = tx
		for i in Engine.hole_hits(frame, mask) {
			r = reads.get(i) ?? crash "read"
			v = (r.read)(env)
			(f2, t2) = Engine.set_hole($frame, i, v, $tx)
			$frame = f2
			$tx = t2
		}
		var $kids = children
		for j in Engine.site_hits(frame, mask) {
			{ list, prev } = $kids.replace(j, Engine.noop({})) ?? crash "child"
			(next, _, t3) = Engine.call(prev, env, Changed(mask), $tx)
			$kids = list.set(j, next) ?? crash "child"
			$tx = t3
		}
		({ frame: $frame, reads, handlers, children: $kids }, $tx)
	}

	fire_block : Block(ctx), ctx, List(U32), U64, U32, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_block = |block, env, path, pos, h, tx| {
		if pos >= path.len() {
			handler = block.handlers.get(h.to_u64()) ?? crash "missing handler"
			next_env = (handler.run)(env)
			(block, Pending(next_env, handler.mask), tx)
		} else {
			k = (path.get(pos) ?? 0).to_u64()
			{ frame, reads, handlers, children } = block
			{ list, prev } = children.replace(k, Engine.noop({})) ?? crash "missing child site"
			(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
			({ frame, reads, handlers, children: list.set(k, next) ?? crash "child" }, out, tx1)
		}
	}

	dispose_block : Block(ctx), ctx, Bool, Tx -> Tx
	dispose_block = |{ frame, reads: _, handlers: _, children }, env, remove, tx| {
		var $tx = tx
		var $j = 0.U64
		for kid in children {
			(_, _, t1) = Engine.call(kid, env, Dispose(Engine.site_removes(frame, $j, remove)), $tx)
			$tx = t1
			$j = $j + 1
		}
		Engine.dispose_frame(frame, remove, $tx)
	}

	## ------------------------------------------------------------------
	## Site kinds.
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
				t2 = if remove Engine.cmd_id(t1, 6, w.anchor) else t1
				(Engine.noop({}), Done, Engine.free_id(t2, w.anchor))
			}
		}
	})

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
	State(ctx, s) := { depth : U64 }.{
		val : State(ctx, s) -> Val(In(ctx, s), s)
		val = |st| { mask: Engine.bit(st.depth), read: |e| e.value }

		update : State(ctx, s), (s -> s) -> Handler(In(ctx, s))
		update = |st, f| { mask: Engine.bit(st.depth), run: |e| In.{ outer: e.outer, value: f(e.value) } }

		lift : State(ctx, s), Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |_st, { mask, read }| { mask, read: |e| read(e.outer) }

		lift_handler : State(ctx, s), Handler(ctx) -> Handler(In(ctx, s))
		lift_handler = |_st, { mask, run }| { mask, run: |e| In.{ outer: run(e.outer), value: e.value } }
	}

	site : Mount(ctx) -> Elem(ctx)
	site = |m| { skel: SSite, dyns: [DSite(m)] }

	state : s, (State(ctx, s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [s.is_eq : s, s -> Bool]
	state = |init, body| Engine.site(Mount(|env, args, tx| {
		depth = args.depth + 1
		elem = body(State.{ depth: depth })
		(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, tx)
		reads = block.frame.reads
		(Engine.state_inst(init, block, depth), reads, tx1)
	}))

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Engine.site(Mount(|env, args, tx| {
		(anchor, tx1) = Engine.alloc_id(tx)
		tx2 = Engine.place(Engine.cmd_id_str(tx1, 2, anchor, ""), args.parent, args.before, anchor)
		c = (cond.read)(env)
		elem = if c yes() else no()
		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, args.parent, anchor, Engine.count_eval(tx2))
		reads = block.frame.reads.bitwise_or(cond.mask)
		w = { cond, yes, no, anchor, parent: args.parent, depth: args.depth, path: args.path }
		(Engine.when_inst(w, c, block), reads, tx3)
	}))

	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value }

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| {
		var $sattrs = List.with_capacity(attrs.len())
		var $dyns = []
		for a in attrs {
			match a {
				Static(n, v) => {
					$sattrs = $sattrs.append(SStatic(n, v))
				}
				Dyn(n, v) => {
					$sattrs = $sattrs.append(SDyn(n))
					$dyns = $dyns.append(DRead(v))
				}
				OnClick(h) => {
					$sattrs = $sattrs.append(SClick)
					$dyns = $dyns.append(DClick(h))
				}
			}
		}
		var $skels = List.with_capacity(kids.len())
		for { skel, dyns } in kids {
			$skels = $skels.append(skel)
			$dyns = $dyns.concat(dyns)
		}
		{ skel: SNode(tag, $sattrs, $skels), dyns: $dyns }
	}

	text : Str -> Elem(ctx)
	text = |s| { skel: SText(s), dyns: [] }

	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| { skel: SDynText, dyns: [DRead(v)] }

	class : Str -> Attr(ctx)
	class = |c| Static("class", c)

	test_id : Str -> Attr(ctx)
	test_id = |c| Static("data-testid", c)

	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| Dyn("class", v)

	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| OnClick(h)

	## ------------------------------------------------------------------
	App := { root : Inst(Root), tx : Tx }

	new_tx : {} -> Tx
	new_tx = |_| { cmds: [], next: 1, free: [], routes: [], evals: 0 }

	mount : Elem(Root), U32 -> App
	mount = |elem, first_id| {
		{ cmds, next: _, free, routes, evals } = Engine.new_tx({})
		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, { cmds, next: first_id, free, routes, evals })
		{ root: Engine.block_inst(block), tx }
	}

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

	take_cmds : App -> (App, List(U8))
	take_cmds = |{ root, tx }| {
		{ cmds, next, free, routes, evals } = tx
		({ root, tx: { cmds: List.with_capacity(cmds.len()), next, free, routes, evals } }, cmds)
	}

	evals : App -> U64
	evals = |a| a.tx.evals
}
