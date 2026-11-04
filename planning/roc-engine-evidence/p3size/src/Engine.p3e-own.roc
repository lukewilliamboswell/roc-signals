## Phase 3 size spike (p3e): the Phase 2 unified engine (representation D + keyed
## `each` over typed columns) restructured so that the typed layer is thin.
##
## Phase 2 made every engine function generic over the context type `ctx`
## (and, in `each`, over the row item), so each distinct state type and each
## each site re-specialised the whole engine: mounting, command writing,
## refresh, reconcile, LIS, the key index and disposal.
##
## Here the typed values (state values, row items, the reads and handlers
## closures, nested site instances) are only touched by short per-context
## loops. Everything else takes plain data (indices, U32 node ids, Str keys
## and values, List(U8) commands) and so exists once:
##
## - `Elem(ctx)` is a flat pre-order op list (untyped) plus typed side lists
##   (value reads, handlers, nested mounts) in the same order. Mounting walks
##   the op list in a monomorphic walker that stops at each nested site; the
##   per-context loop mounts that site and resumes the walker.
## - A block's holes, node ids and child masks live in an untyped `Core`;
##   refresh is a per-context loop that asks the core which holes a mask hits,
##   evaluates only those reads and hands the strings back to the core.
## - An each site keeps an untyped `EachCore` (template, keys, order, free
##   slots, key index, last hole values, pending masks, selection) and a
##   typed item column. Reconcile's prefix/suffix/swap scan and the
##   placement loop are per item type (they compare items); the general
##   keyed plan (index lookups, removals, LIS) is monomorphic and works on
##   the middle range's keys.
##
## The command stream is identical to Phase 2 (same runtime.mjs).
## Not carried over from Phase 2 (spike scope): nested sites inside an each
## row (dynamic rows) and the `each_fixed` boundary.
Engine := [].{
	Root := [Root]

	In(outer, s) := { outer : outer, value : s }

	Row(outer, item) := { outer : outer, key : Str, item : item }

	Sel(ctx) := [NoSel, Sel(U64, (ctx -> Str))]

	Val(ctx, a) := { mask : U64, read : (ctx -> a), sel : Sel(ctx) }.{
		map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		map = |{ mask, read, sel }, f| { mask, read: |env| f(read(env)), sel }

		map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		map2 = |l, r, f| {
			lr = l.read
			rr = r.read
			m = l.mask.bitwise_or(r.mask).bitwise_or(Engine.sel_mask(l.sel)).bitwise_or(Engine.sel_mask(r.sel))
			{ mask: m, read: |env| f(lr(env), rr(env)), sel: NoSel }
		}

		lift : Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}

		lift_row : Val(ctx, a) -> Val(Row(ctx, item), a)
		lift_row = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}
	}

	sel_mask : Sel(ctx) -> U64
	sel_mask = |sel| match sel {
		NoSel => 0
		Sel(m, _) => m
	}

	eff_mask : Val(ctx, a) -> U64
	eff_mask = |v| v.mask.bitwise_or(Engine.sel_mask(v.sel))

	Handler(ctx) := { mask : U64, run : (ctx -> ctx) }.{
		lift : Handler(ctx) -> Handler(In(ctx, s))
		lift = |{ mask, run }| {
			mask,
			run: |e| {
				{ outer, value } = e
				In.{ outer: run(outer), value }
			},
		}

		lift_row : Handler(ctx) -> Handler(Row(ctx, item))
		lift_row = |{ mask, run }| {
			mask,
			run: |e| {
				{ outer, key, item } = e
				Row.{ outer: run(outer), key, item }
			},
		}
	}

	State(ctx, s) := { mask : U64, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }.{
		val : State(ctx, s) -> Val(ctx, s)
		val = |{ mask, get, modify: _ }| { mask, read: get, sel: NoSel }

		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ mask, get: _, modify }, f| { mask, run: |e| modify(e, f) }

		update_by : State(ctx, s), Val(ctx, b), (s, b -> s) -> Handler(ctx)
		update_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e| {
					b = read(e)
					modify(e, |s| f(s, b))
				},
			}
		}

		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ mask, get, modify }| {
			mask,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, value } = e
				In.{ outer: modify(outer, f), value }
			},
		}

		lift_row : State(ctx, s) -> State(Row(ctx, item), s)
		lift_row = |{ mask, get, modify }| {
			mask,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, key, item } = e
				Row.{ outer: modify(outer, f), key, item }
			},
		}
	}

	Keyed(ctx, v) : { mask : U64, selected : (ctx -> Str), yes : v, no : v }

	keyed : Val(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sv, yes, no| {
		{ mask, read, sel } = sv
		{ mask: mask.bitwise_or(Engine.sel_mask(sel)), selected: read, yes, no }
	}

	RowRef(outer, item) := { depth : U64 }.{
		key : RowRef(outer, item) -> Val(Row(outer, item), Str)
		key = |_| { mask: 0, read: |e| e.key, sel: NoSel }

		field : RowRef(outer, item), (item -> a) -> Val(Row(outer, item), a)
		field = |{ depth }, f| { mask: Engine.bit(depth), read: |e| f(e.item), sel: NoSel }

		select : RowRef(outer, item), Keyed(outer, v) -> Val(Row(outer, item), v)
		select = |_, kd| {
			{ mask, selected, yes, no } = kd
			{ mask: 0, read: |e| if selected(e.outer) == e.key yes else no, sel: Sel(mask, |e| selected(e.outer)) }
		}
	}

	## ------------------------------------------------------------------
	## Elements: a flat, untyped pre-order op list plus typed side lists.
	##   Open(tag, nkids) ... attr ops ... kid subtrees ... Close
	## AttrH/TextH carry (mask, selector mask) and consume one `reads` entry;
	## OnA consumes one `handlers` entry; SiteOp consumes one `mounts` entry.
	Op := [Open(Str, U64), AttrS(Str, Str), AttrH(Str, U64, U64), OnA, TextS(Str), TextH(U64, U64), SiteOp, Close]

	Read(ctx) : { read : (ctx -> Str), skey : (ctx -> Str) }

	Elem(ctx) := { ops : List(Op), reads : List(Read(ctx)), handlers : List(Handler(ctx)), mounts : List(Mount(ctx)) }

	Attr(ctx) := [AStatic(Str, Str), ADyn(Str, Val(ctx, Str)), AOn(Handler(ctx))]

	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool }

	Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

	Msg := [Fire(List(U32), U64, U32), Changed(U64), Dispose(Bool)]

	Out(ctx) := [Done, Pending(ctx, U64)]

	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

	Route := [NoRoute, Route(List(U32), U32)]

	## The id tables live behind a one-element list so a Tx is seven words:
	## Roc passes call arguments through memory, so every out-of-line call
	## pays per word of every record it passes.
	Ids : { next : U32, free : List(U32), routes : List(Route), paths : List(List(U32)), site_free : List(U32) }

	Tx : { cmds : List(U8), evals : U64, ids : List(Ids) }

	ids_empty : Ids
	ids_empty = { next: 0, free: [], routes: [], paths: [], site_free: [] }

	take_ids : Tx -> (Tx, Ids)
	take_ids = |{ cmds, evals, ids }| {
		{ list, prev } = ids.replace(0, Engine.ids_empty) ?? crash "ids"
		({ cmds, evals, ids: list }, prev)
	}

	put_ids : Tx, Ids -> Tx
	put_ids = |{ cmds, evals, ids }, v| { cmds, evals, ids: ids.set(0, v) ?? crash "ids" }

	read_of : Val(ctx, Str) -> (Read(ctx), U64, U64)
	read_of = |{ mask, read, sel }| match sel {
		NoSel => ({ read, skey: |_| "" }, mask, 0)
		Sel(m, k) => ({ read, skey: k }, mask, m)
	}

	## ------------------------------------------------------------------
	## Command encoding (monomorphic).
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

	cmd_node : Tx, U8, U32, U32, U32, Str -> Tx
	cmd_node = |{ cmds, evals, ids }, op, id, parent, before, s| {
		{ cmds: Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(cmds.append(op), id), parent), before), s), evals, ids }
	}

	cmd_attr : Tx, U8, U32, Str, Str -> Tx
	cmd_attr = |{ cmds, evals, ids }, op, id, name, value| {
		c0 = Engine.put_u32(cmds.append(op), id)
		c1 = if op == 9 Engine.put_str(c0, name) else c0
		{ cmds: Engine.put_str(c1, value), evals, ids }
	}

	cmd_ids : Tx, U8, U32, U32 -> Tx
	cmd_ids = |{ cmds, evals, ids }, op, a, b| {
		c0 = Engine.put_u32(cmds.append(op), a)
		{ cmds: if op == 5 c0 else Engine.put_u32(c0, b), evals, ids }
	}

	cmd_raw : Tx, List(U8) -> Tx
	cmd_raw = |{ cmds, evals, ids }, bytes| { cmds: cmds.concat(bytes), evals, ids }

	count_evals : Tx, U64 -> Tx
	count_evals = |{ cmds, evals, ids }, n| { cmds, evals: evals + n, ids }

	alloc_id : Tx -> (U32, Tx)
	alloc_id = |tx| {
		(t1, d) = Engine.take_ids(tx)
		{ next, free, routes, paths, site_free } = d
		match free.last() {
			Ok(id) => (id, Engine.put_ids(t1, { next, free: free.drop_last(1), routes, paths, site_free }))
			Err(_) => {
				if next >= 1048575 {
					crash "static node ids exhausted"
				}
				(next, Engine.put_ids(t1, { next: next + 1, free, routes, paths, site_free }))
			}
		}
	}

	free_id : Tx, U32 -> Tx
	free_id = |tx, id| {
		(t1, d) = Engine.take_ids(tx)
		{ next, free, routes, paths, site_free } = d
		routes2 = if id.to_u64() < routes.len() routes.set(id.to_u64(), NoRoute) ?? routes else routes
		Engine.put_ids(t1, { next, free: free.append(id), routes: routes2, paths, site_free })
	}

	set_route : Tx, U32, List(U32), U32 -> Tx
	set_route = |tx, id, path, handler| {
		(t1, d) = Engine.take_ids(tx)
		{ next, free, routes, paths, site_free } = d
		var $r = routes
		while $r.len() <= id.to_u64() {
			$r = $r.append(NoRoute)
		}
		Engine.put_ids(t1, { next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, paths, site_free })
	}

	alloc_site : Tx, List(U32) -> (U32, Tx)
	alloc_site = |tx, path| {
		(t1, d) = Engine.take_ids(tx)
		{ next, free, routes, paths, site_free } = d
		match site_free.last() {
			Ok(s) => (s, Engine.put_ids(t1, { next, free, routes, paths: paths.set(s.to_u64(), path) ?? crash "site", site_free: site_free.drop_last(1) }))
			Err(_) => {
				s = paths.len().to_u32_wrap()
				if s >= 4095 {
					crash "each sites exhausted"
				}
				(s, Engine.put_ids(t1, { next, free, routes, paths: paths.append(path), site_free }))
			}
		}
	}

	free_site : Tx, U32 -> Tx
	free_site = |tx, s| {
		(t1, d) = Engine.take_ids(tx)
		{ next, free, routes, paths, site_free } = d
		Engine.put_ids(t1, { next, free, routes, paths: paths.set(s.to_u64(), []) ?? paths, site_free: site_free.append(s) })
	}

	bit : U64 -> U64
	bit = |depth| 1.U64.shl_wrap(depth.to_u8_wrap())

	upto : U64 -> U64
	upto = |depth| Engine.bit(depth).shl_wrap(1) - 1

	## ------------------------------------------------------------------
	## Untyped block core.
	HoleC : { node : U32, mask : U64, attr : Str, last : Str }

	Core : {
		holes : List(HoleC),
		nhandlers : U32,
		kreads : List(U64),
		ktop : List(Bool),
		nodes : List(U32),
		tops : List(U32),
		reads : U64,
	}

	core_empty : Core
	core_empty = { holes: [], nhandlers: 0, kreads: [], ktop: [], nodes: [], tops: [], reads: 0 }

	add_node : Core, U32, Bool -> Core
	add_node = |{ holes, nhandlers, kreads, ktop, nodes, tops, reads }, id, top| {
		{ holes, nhandlers, kreads, ktop, nodes: nodes.append(id), tops: if top tops.append(id) else tops, reads }
	}

	add_hole : Core, HoleC -> Core
	add_hole = |{ holes, nhandlers, kreads, ktop, nodes, tops, reads }, hole| {
		m = hole.mask
		{ holes: holes.append(hole), nhandlers, kreads, ktop, nodes, tops, reads: reads.bitwise_or(m) }
	}

	add_kid : Core, U64, Bool -> Core
	add_kid = |{ holes, nhandlers, kreads, ktop, nodes, tops, reads }, r, top| {
		{ holes, nhandlers, kreads: kreads.append(r), ktop: ktop.append(top), nodes, tops, reads: reads.bitwise_or(r) }
	}

	next_handler : Core -> (Core, U32)
	next_handler = |{ holes, nhandlers, kreads, ktop, nodes, tops, reads }| ({ holes, nhandlers: nhandlers + 1, kreads, ktop, nodes, tops, reads }, nhandlers)

	Walk : { pos : U64, stack : List(U32), soles : List(Bool), parent : U32, before : U32, hi : U64 }

	Step : [AtSite(Args, Bool), Finished]

	walk_new : U32, U32 -> Walk
	walk_new = |parent, before| { pos: 0, stack: [], soles: [], parent, before, hi: 0 }

	## Mount ops from the walker's position until the next nested site (whose
	## mount arguments are returned) or the end. `vals` holds the already
	## evaluated value holes in op order.
	walk : Core, Walk, List(Op), List(Str), U64, List(U32), Tx -> (Core, Walk, Step, Tx)
	walk = |core, w, ops, vals, depth, path, tx| {
		{ pos, stack, soles, parent, before, hi } = w
		var $core = core
		var $tx = tx
		var $pos = pos
		var $stack = stack
		var $soles = soles
		var $hi = hi
		while $pos < ops.len() {
			op = ops.get($pos) ?? crash "op"
			$pos = $pos + 1
			top = $stack.is_empty()
			cur = $stack.last() ?? parent
			at = if top before else 0
			match op {
				Open(tag, nk) => {
					(id, t1) = Engine.alloc_id($tx)
					$tx = Engine.cmd_node(t1, 8, id, cur, at, tag)
					$core = Engine.add_node($core, id, top)
					$stack = $stack.append(id)
					$soles = $soles.append(nk == 1)
				}
				AttrS(name, value) => {
					$tx = Engine.cmd_attr($tx, 9, cur, name, value)
				}
				AttrH(name, m, sm) => {
					v = vals.get($hi) ?? crash "val"
					$hi = $hi + 1
					$tx = Engine.cmd_attr($tx, 9, cur, name, v)
					$core = Engine.add_hole($core, { node: cur, mask: m.bitwise_or(sm), attr: name, last: v })
				}
				OnA => {
					(c2, h) = Engine.next_handler($core)
					$core = c2
					$tx = Engine.set_route(Engine.cmd_ids($tx, 11, cur, h), cur, path, h)
				}
				TextS(s) => {
					(id, t1) = Engine.alloc_id($tx)
					$tx = Engine.cmd_node(t1, 10, id, cur, at, s)
					$core = Engine.add_node($core, id, top)
				}
				TextH(m, sm) => {
					v = vals.get($hi) ?? crash "val"
					$hi = $hi + 1
					(id, t1) = Engine.alloc_id($tx)
					$tx = Engine.cmd_node(t1, 10, id, cur, at, v)
					$core = Engine.add_hole(Engine.add_node($core, id, top), { node: id, mask: m.bitwise_or(sm), attr: "", last: v })
				}
				SiteOp => {
					k = $core.kreads.len().to_u32_wrap()
					sole = ($soles.last() ?? False) and !top
					args = { depth, path: path.append(k), parent: cur, before: at, sole }
					return ($core, { pos: $pos, stack: $stack, soles: $soles, parent, before, hi: $hi }, AtSite(args, top), $tx)
				}
				Close => {
					$stack = $stack.drop_last(1)
					$soles = $soles.drop_last(1)
				}
			}
		}
		($core, { pos: $pos, stack: $stack, soles: $soles, parent, before, hi: $hi }, Finished, $tx)
	}

	## Does the mask hit hole `i`?
	hole_hit : Core, U64, U64 -> Bool
	hole_hit = |core, i, mask| (core.holes.get(i).map_ok(|h| h.mask) ?? 0).bitwise_and(mask) != 0

	kid_hit : Core, U64, U64 -> Bool
	kid_hit = |core, j, mask| (core.kreads.get(j) ?? 0).bitwise_and(mask) != 0

	## A re-evaluated hole value: prune if equal, else emit and remember.
	hole_put : Core, U64, Str, Tx -> (Core, Tx)
	hole_put = |{ holes, nhandlers, kreads, ktop, nodes, tops, reads }, i, v, tx| {
		{ list, prev } = holes.replace(i, { node: 0, mask: 0, attr: "", last: "" }) ?? crash "hole"
		{ node, mask, attr, last } = prev
		t1 = Engine.count_evals(tx, 1)
		if v == last {
			({ holes: list.set(i, { node, mask, attr, last }) ?? crash "hole", nhandlers, kreads, ktop, nodes, tops, reads }, t1)
		} else {
			t2 = if attr.is_empty() Engine.cmd_attr(t1, 12, node, "", v) else Engine.cmd_attr(t1, 9, node, attr, v)
			({ holes: list.set(i, { node, mask, attr, last: v }) ?? crash "hole", nhandlers, kreads, ktop, nodes, tops, reads }, t2)
		}
	}

	## Remove (optionally) and release a block's own nodes.
	dispose_core : Core, Bool, Tx -> Tx
	dispose_core = |core, remove, tx| {
		var $tx = tx
		if remove {
			for id in core.tops {
				$tx = Engine.cmd_ids($tx, 5, id, 0)
			}
		}
		for id in core.nodes {
			$tx = Engine.free_id($tx, id)
		}
		$tx
	}

	## ------------------------------------------------------------------
	## Typed per-context block layer: these are the only block functions
	## specialised per context, and they only loop and call.
	TBlock(ctx) : { core : Core, reads : List(Read(ctx)), handlers : List(Handler(ctx)), kids : List(Inst(ctx)) }

	noop : {} -> Inst(ctx)
	noop = |_| Inst(|env, msg, tx| {
		match msg {
			Fire(_, _, _) => (Engine.noop({}), Pending(env, 0), tx)
			_ => (Engine.noop({}), Done, tx)
		}
	})

	call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
	call = |Inst(f), env, msg, tx| f(env, msg, tx)

	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Tx -> (TBlock(ctx), Tx)
	mount_block = |env, elem, depth, path, parent, before, tx| {
		{ ops, reads, handlers, mounts } = elem
		var $vals = List.with_capacity(reads.len())
		for r in reads {
			$vals = $vals.append((r.read)(env))
		}
		var $core = Engine.core_empty
		var $w = Engine.walk_new(parent, before)
		var $tx = Engine.count_evals(tx, reads.len())
		var $kids = []
		var $go = True
		while $go {
			(c2, w2, step, t2) = Engine.walk($core, $w, ops, $vals, depth, path, $tx)
			$w = w2
			match step {
				AtSite(args, top) => {
					match mounts.get($kids.len()) {
						Ok(Mount(f)) => {
							(inst, r, t3) = f(env, args, t2)
							$kids = $kids.append(inst)
							$core = Engine.add_kid(c2, r, top)
							$tx = t3
						}
						Err(_) => crash "mount"
					}
				}
				Finished => {
					$core = c2
					$tx = t2
					$go = False
				}
			}
		}
		({ core: $core, reads, handlers, kids: $kids }, $tx)
	}

	refresh : TBlock(ctx), ctx, U64, Tx -> (TBlock(ctx), Tx)
	refresh = |{ core, reads, handlers, kids }, env, mask, tx| {
		var $core = core
		var $tx = tx
		var $i = 0.U64
		n = reads.len()
		while $i < n {
			if Engine.hole_hit($core, $i, mask) {
				v = match reads.get($i) {
					Ok(r) => (r.read)(env)
					Err(_) => crash "read"
				}
				(c2, t2) = Engine.hole_put($core, $i, v, $tx)
				$core = c2
				$tx = t2
			}
			$i = $i + 1
		}
		var $kids = kids
		var $j = 0.U64
		while $j < $kids.len() {
			if Engine.kid_hit($core, $j, mask) {
				{ list, prev } = $kids.replace($j, Engine.noop({})) ?? crash "child"
				(next, _, t2) = Engine.call(prev, env, Changed(mask), $tx)
				$kids = list.set($j, next) ?? crash "child"
				$tx = t2
			}
			$j = $j + 1
		}
		({ core: $core, reads, handlers, kids: $kids }, $tx)
	}

	fire_block : TBlock(ctx), ctx, List(U32), U64, U32, Tx -> (TBlock(ctx), Out(ctx), Tx)
	fire_block = |block, env, path, pos, h, tx| {
		if pos >= path.len() {
			match block.handlers.get(h.to_u64()) {
				Ok(handler) => (block, Pending((handler.run)(env), handler.mask), tx)
				Err(_) => (block, Pending(env, 0), tx)
			}
		} else {
			k = (path.get(pos) ?? 0).to_u64()
			{ core, reads, handlers, kids } = block
			match kids.replace(k, Engine.noop({})) {
				Ok({ list, prev }) => {
					(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
					({ core, reads, handlers, kids: list.set(k, next) ?? crash "child" }, out, tx1)
				}
				Err(_) => ({ core, reads, handlers, kids }, Pending(env, 0), tx)
			}
		}
	}

	dispose_block : TBlock(ctx), ctx, Bool, Tx -> Tx
	dispose_block = |{ core, reads: _, handlers: _, kids }, env, remove, tx| {
		var $tx = tx
		var $j = 0.U64
		var $ks = kids
		while $j < $ks.len() {
			kt = core.ktop.get($j) ?? False
			{ list, prev } = $ks.replace($j, Engine.noop({})) ?? crash "child"
			(_, _, t1) = Engine.call(prev, env, Dispose(remove and kt), $tx)
			$ks = list
			$tx = t1
			$j = $j + 1
		}
		Engine.dispose_core(core, remove, $tx)
	}

	## ------------------------------------------------------------------
	## Site kinds.
	state_inst : s, TBlock(In(ctx, s)), U64 -> Inst(ctx)
	state_inst = |s, block, depth| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				(b2, t2) = Engine.refresh(block, In.{ outer: env, value: s }, mask, tx)
				(Engine.state_inst(s, b2, depth), Done, t2)
			}
			Fire(path, pos, h) => {
				(b2, out, t2) = Engine.fire_block(block, In.{ outer: env, value: s }, path, pos, h, tx)
				match out {
					Done => crash "fire must hand the environment back"
					Pending(next_inner, mask) => {
						{ outer: next_outer, value: s2 } = next_inner
						own = Engine.bit(depth)
						above = mask.bitwise_and(own - 1)
						if above != 0 or mask.bitwise_and(own) == 0 {
							(Engine.state_inst(s2, b2, depth), Pending(next_outer, mask), t2)
						} else {
							(b3, t3) = Engine.refresh(b2, In.{ outer: next_outer, value: s2 }, own, t2)
							(Engine.state_inst(s2, b3, depth), Pending(next_outer, 0), t3)
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

	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32) }

	when_inst : When(ctx), Bool, TBlock(ctx) -> Inst(ctx)
	when_inst = |w, cur, block| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				cm = Engine.eff_mask(w.cond)
				if cm.bitwise_and(mask) != 0 {
					c = (w.cond.read)(env)
					t1 = Engine.count_evals(tx, 1)
					if c == cur {
						(b2, t2) = Engine.refresh(block, env, mask, t1)
						(Engine.when_inst(w, cur, b2), Done, t2)
					} else {
						t2 = Engine.dispose_block(block, env, True, t1)
						elem = if c (w.yes)() else (w.no)()
						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, t2)
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
				t2 = if remove Engine.cmd_ids(t1, 5, w.anchor, 0) else t1
				(Engine.noop({}), Done, Engine.free_id(t2, w.anchor))
			}
		}
	})

	block_inst : TBlock(ctx) -> Inst(ctx)
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
	## Key index (monomorphic): open addressing Str key -> slot.
	KeyIndex : { hs : List(U64), vals : List(U32), count : U64, bits : U8 }

	index_empty : KeyIndex
	index_empty = { hs: [], vals: [], count: 0, bits: 0 }

	hash_str : Str -> U64
	hash_str = |s| {
		var $h = 14695981039346656037.U64
		for b in s.iter_utf8() {
			$h = $h.bitwise_xor(b.to_u64()).times_wrap(1099511628211)
		}
		$h
	}

	bucket : U64, U8 -> U64
	bucket = |h, bits| h.times_wrap(11400714819323198485).shr_zf_wrap(64 - bits)

	index_find : KeyIndex, List(Str), Str, U64 -> Try(U32, [Missing])
	index_find = |index, keys, key, h| {
		if index.count == 0 {
			return Err(Missing)
		}
		mask = (1.U64.shl_wrap(index.bits)) - 1
		var $b = Engine.bucket(h, index.bits)
		while True {
			v = index.vals.get($b) ?? 0
			if v == 0 {
				return Err(Missing)
			}
			if (index.hs.get($b) ?? 0) == h and (keys.get((v - 1).to_u64()) ?? "") == key {
				return Ok(v - 1)
			}
			$b = ($b + 1).bitwise_and(mask)
		}
	}

	raw_insert : List(U64), List(U32), U8, U64, U32 -> { hs : List(U64), vals : List(U32) }
	raw_insert = |hs, vals, bits, h, slot| {
		mask = (1.U64.shl_wrap(bits)) - 1
		var $b = Engine.bucket(h, bits)
		while (vals.get($b) ?? 0) != 0 {
			$b = ($b + 1).bitwise_and(mask)
		}
		{ hs: hs.set($b, h) ?? crash "index bucket", vals: vals.set($b, slot + 1) ?? crash "index bucket" }
	}

	grow : KeyIndex -> KeyIndex
	grow = |{ hs, vals, count, bits }| {
		new_bits = if bits == 0 4 else bits + 1
		size = 1.U64.shl_wrap(new_bits)
		var $h = List.repeat(0.U64, size)
		var $v = List.repeat(0.U32, size)
		var $i = 0.U64
		while $i < vals.len() {
			v = vals.get($i) ?? 0
			if v != 0 {
				r = Engine.raw_insert($h, $v, new_bits, hs.get($i) ?? 0, v - 1)
				$h = r.hs
				$v = r.vals
			}
			$i = $i + 1
		}
		{ hs: $h, vals: $v, count, bits: new_bits }
	}

	index_insert : KeyIndex, List(Str), Str, U32 -> KeyIndex
	index_insert = |index, keys, key, slot| {
		h = Engine.hash_str(key)
		match Engine.index_find(index, keys, key, h) {
			Ok(_) => crash "duplicate key in each"
			Err(Missing) => {}
		}
		grown = if (index.count + 1) * 2 > 1.U64.shl_wrap(index.bits) Engine.grow(index) else index
		{ hs, vals, count, bits } = grown
		r = Engine.raw_insert(hs, vals, bits, h, slot)
		{ hs: r.hs, vals: r.vals, count: count + 1, bits }
	}

	index_remove : KeyIndex, U32, Str -> KeyIndex
	index_remove = |{ hs, vals, count, bits }, slot, key| {
		if count == 0 {
			crash "remove of missing key"
		}
		mask = (1.U64.shl_wrap(bits)) - 1
		h = Engine.hash_str(key)
		var $b = Engine.bucket(h, bits)
		while (vals.get($b) ?? 0) != slot + 1 {
			if (vals.get($b) ?? 0) == 0 {
				crash "remove of missing key"
			}
			$b = ($b + 1).bitwise_and(mask)
		}
		var $h = hs
		var $v = vals
		var $hole = $b
		var $j = ($b + 1).bitwise_and(mask)
		while ($v.get($j) ?? 0) != 0 {
			jh = $h.get($j) ?? 0
			home = Engine.bucket(jh, bits)
			dist_home = ($j + mask + 1 - home).bitwise_and(mask)
			dist_hole = ($j + mask + 1 - $hole).bitwise_and(mask)
			if dist_home >= dist_hole {
				$h = $h.set($hole, jh) ?? crash "index"
				$v = $v.set($hole, $v.get($j) ?? 0) ?? crash "index"
				$hole = $j
			}
			$j = ($j + 1).bitwise_and(mask)
		}
		$v = $v.set($hole, 0) ?? crash "index"
		{ hs: $h, vals: $v, count: count - 1, bits }
	}

	## ------------------------------------------------------------------
	## Row template compile (monomorphic, from the op list).
	##
	## Template encoding: node := 1 tag:str nattr:u8 (name:str value:str)*
	## nchild:u8 node* | 2 text:str; then nholes:u8, each hole := kind:u8
	## depth:u8 path:u8* [attr: name:str | click: handler:u8].
	## Value holes (text/attr) are numbered in op order (`ri`, the index into
	## the row reads); `hidx` is the hole's index in the template hole table.
	VHole : { kind : U8, mask : U64, smask : U64, col : U64, live : Bool, hidx : U8 }

	put_path : List(U8), U8, List(U8) -> List(U8)
	put_path = |buf, kind, path| buf.append(kind).append(path.len().to_u8_wrap()).concat(path)

	Compiled : { bytes : List(U8), vholes : List(VHole), ncols : U64 }

	compile_ops : List(Op) -> Compiled
	compile_ops = |ops| {
		var $tree = []
		var $htab = []
		var $vh = []
		var $nh = 0.U64
		var $hd = 0.U64
		var $ncols = 0.U64
		var $paths = []
		var $kidi = List.with_capacity(8)
		var $i = 0.U64
		n = ops.len()
		while $i < n {
			op = ops.get($i) ?? crash "op"
			$i = $i + 1
			# path of a new node under the current element
			node_path = match $kidi.last() {
				Ok(k) => ($paths.last() ?? []).append(k.to_u8_wrap())
				Err(_) => []
			}
			is_node = match op {
				Open(_, _) => True
				TextS(_) => True
				TextH(_, _) => True
				SiteOp => True
				_ => False
			}
			if is_node {
				$kidi = match $kidi.last() {
					Ok(k) => $kidi.drop_last(1).append(k + 1)
					Err(_) => {
						if !$paths.is_empty() or !$tree.is_empty() {
							crash "an each row template must be a single element"
						}
						$kidi
					}
				}
			}
			match op {
				Open(tag, nk) => {
					var $ns = 0.U64
					var $j = $i
					var $scan = True
					while $scan and $j < n {
						match ops.get($j) ?? Close {
							AttrS(_, _) => {
								$ns = $ns + 1
							}
							AttrH(_, _, _) => {}
							OnA => {}
							_ => {
								$scan = False
							}
						}
						$j = $j + 1
					}
					$tree = Engine.put_str($tree.append(1), tag).append($ns.to_u8_wrap())
					# attrs are written when their ops are reached; the child count
					# follows them, so remember it for the first non-attr op.
					$paths = $paths.append(node_path)
					$kidi = $kidi.append(0.U64)
					# write attributes now (they directly follow Open)
					var $k = $i
					var $more = True
					while $more and $k < n {
						match ops.get($k) ?? Close {
							AttrS(name, value) => {
								$tree = Engine.put_str(Engine.put_str($tree, name), value)
								$k = $k + 1
							}
							AttrH(name, m, sm) => {
								live = m.bitwise_or(sm) != 0
								$vh = $vh.append({ kind: 2, mask: m, smask: sm, col: if live $ncols else 0, live, hidx: $nh.to_u8_wrap() })
								$ncols = if live $ncols + 1 else $ncols
								$htab = Engine.put_str(Engine.put_path($htab, 2, node_path), name)
								$nh = $nh + 1
								$k = $k + 1
							}
							OnA => {
								$htab = Engine.put_path($htab, 3, node_path).append($hd.to_u8_wrap())
								$hd = $hd + 1
								$nh = $nh + 1
								$k = $k + 1
							}
							_ => {
								$more = False
							}
						}
					}
					$i = $k
					$tree = $tree.append(nk.to_u8_wrap())
				}
				AttrS(_, _) => crash "attribute outside an element"
				AttrH(_, _, _) => crash "attribute outside an element"
				OnA => crash "attribute outside an element"
				TextS(s) => {
					$tree = Engine.put_str($tree.append(2), s)
				}
				TextH(m, sm) => {
					$tree = Engine.put_str($tree.append(2), "")
					live = m.bitwise_or(sm) != 0
					$vh = $vh.append({ kind: 1, mask: m, smask: sm, col: if live $ncols else 0, live, hidx: $nh.to_u8_wrap() })
					$ncols = if live $ncols + 1 else $ncols
					$htab = Engine.put_path($htab, 1, node_path)
					$nh = $nh + 1
				}
				SiteOp => crash "nested sites inside each rows are not supported by the p3 spike engine"
				Close => {
					$paths = $paths.drop_last(1)
					$kidi = $kidi.drop_last(1)
				}
			}
		}
		{ bytes: $tree.append($nh.to_u8_wrap()).concat($htab), vholes: $vh, ncols: $ncols }
	}

	## ------------------------------------------------------------------
	## The each core: one untyped record per site. Reconcile works on keys
	## only; the typed layer compares items and evaluates holes into a Sink.
	EachCore : {
		site : U32,
		parent : U32,
		anchor : U32,
		sole : Bool,
		depth : U64,
		vholes : List(VHole),
		vhit : List(U64),
		outer_mask : U64,
		selm : U64,
		keys : List(Str),
		order : List(U32),
		free : List(U32),
		index : KeyIndex,
		pend : List(U64),
		dirty : List(U32),
		lasts : List(List(Str)),
		sels : List(Str),
		known : Bool,
		fresh : List(U32),
		fresh_lo : U64,
		fresh_hi : U64,
		skeys : List(Str),
	}

	row_node : U32, U32 -> U32
	row_node = |site, slot| site.shl_wrap(20) + slot + 1

	put_at : List(a), U64, a -> List(a)
	put_at = |list, i, v| if i == list.len() list.append(v) else (list.set(i, v) ?? crash "column")

	## Set index i, growing with "" first (rows are created from the end).
	put_grow : List(Str), U64, Str -> List(Str)
	put_grow = |list, i, v| {
		var $l = list
		while $l.len() < i {
			$l = $l.append("")
		}
		Engine.put_at($l, i, v)
	}

	each_core_new : List(Op), Args, U64, Tx -> (EachCore, Tx)
	each_core_new = |ops, args, depth, tx| {
		{ bytes, vholes, ncols } = Engine.compile_ops(ops)
		(site, tx1) = Engine.alloc_site(tx, args.path)
		tx2 = Engine.cmd_raw(tx1, Engine.put_u32(Engine.put_u32([7], site), bytes.len().to_u32_wrap()).concat(bytes))
		(anchor, tx3) = if args.sole {
			(0, tx2)
		} else {
			(a, t) = Engine.alloc_id(tx2)
			(a, Engine.cmd_node(t, 10, a, args.parent, args.before, ""))
		}
		row_bit = Engine.bit(depth)
		var $om = 0.U64
		var $sm = 0.U64
		var $vhit = List.with_capacity(vholes.len())
		for h in vholes {
			$om = $om.bitwise_or(h.mask)
			$sm = $sm.bitwise_or(h.smask)
			$vhit = $vhit.append(if h.live h.mask.bitwise_or(h.smask) else 0)
		}
		core = {
			site,
			parent: args.parent,
			anchor,
			sole: args.sole,
			depth,
			vholes,
			vhit: $vhit,
			outer_mask: $om.bitwise_and(row_bit - 1),
			selm: $sm,
			keys: [],
			order: [],
			free: [],
			index: Engine.index_empty,
			pend: [],
			dirty: [],
			lasts: List.repeat([], ncols),
			sels: List.repeat("", vholes.len()),
			known: False,
			fresh: [],
			fresh_lo: 0,
			fresh_hi: 0,
			skeys: [],
		}
		(core, tx3)
	}

	end_ref : EachCore -> U32
	end_ref = |core| if core.sole 0 else core.anchor

	ref_at : EachCore, U64 -> U32
	ref_at = |core, pos| match core.order.get(pos) {
		Ok(s) => Engine.row_node(core.site, s)
		Err(_) => Engine.end_ref(core)
	}

	key_of_slot : EachCore, U32 -> Str
	key_of_slot = |core, slot| core.keys.get(slot.to_u64()) ?? crash "key"

	mark : EachCore, U32, U64 -> EachCore
	mark = |core, slot, m| {
		{ pend, dirty, .. } = core
		(p2, d2) = Engine.mark_cols(pend, dirty, slot, m)
		{ ..core, pend: p2, dirty: d2 }
	}

	mark_cols : List(U64), List(U32), U32, U64 -> (List(U64), List(U32))
	mark_cols = |pend, dirty, slot, m| {
		si = slot.to_u64()
		p = pend.get(si) ?? 0
		dirty2 = if p == 0 dirty.append(slot) else dirty
		(pend.set(si, p.bitwise_or(m)) ?? pend, dirty2)
	}

	mark_all : EachCore, U64 -> EachCore
	mark_all = |core, m| {
		{ order, pend, dirty, .. } = core
		var $p = pend
		var $d = dirty
		for s in order {
			(p2, d2) = Engine.mark_cols($p, $d, s, m)
			$p = p2
			$d = d2
		}
		{ ..core, pend: $p, dirty: $d }
	}

	each_full : EachCore, U64 -> EachCore
	each_full = |core, mask| {
		full = mask.bitwise_and(core.outer_mask).bitwise_and(Engine.bit(core.depth) - 1)
		if full != 0 Engine.mark_all(core, full) else core
	}

	## Release one row's slot (its item stays in the typed column until reuse).
	drop_slot : EachCore, U32, Bool, Tx -> (EachCore, Tx)
	drop_slot = |core, slot, remove, tx| {
		{ keys, index, free, pend, site, .. } = core
		si = slot.to_u64()
		key = keys.get(si) ?? crash "key"
		index2 = Engine.index_remove(index, slot, key)
		t1 = if remove Engine.cmd_ids(tx, 5, Engine.row_node(site, slot), 0) else tx
		({ ..core, index: index2, free: free.append(slot), pend: pend.set(si, 0) ?? pend }, t1)
	}

	## A new row at position `pos` with key `key`: take a slot (free first),
	## record key and index entry (a duplicate key is a contract error), and
	## note the position as fresh (the typed layer creates it).
	new_slot : EachCore, Str, U64, Bool -> (EachCore, U32)
	new_slot = |core, key, pos, track| {
		{ keys, index, free, pend, fresh, .. } = core
		(slot, free2) = match free.last() {
			Ok(s) => (s, free.drop_last(1))
			Err(_) => (keys.len().to_u32_wrap(), free)
		}
		si = slot.to_u64()
		keys2 = Engine.put_at(keys, si, key)
		index2 = Engine.index_insert(index, keys2, key, slot)
		({ ..core, keys: keys2, index: index2, free: free2, pend: Engine.put_at(pend, si, 0), fresh: if track fresh.append(pos.to_u32_wrap()) else fresh }, slot)
	}

	## Remove every row (CLEAR when the site is its parent's only child).
	clear_core : EachCore, Bool, Tx -> (EachCore, Tx)
	clear_core = |core, dom, tx| {
		var $tx = tx
		if !dom {
			{}
		} else if core.sole {
			$tx = Engine.cmd_ids($tx, 6, core.parent, core.site)
		} else {
			for slot in core.order {
				$tx = Engine.cmd_ids($tx, 5, Engine.row_node(core.site, slot), 0)
			}
		}
		ncols = core.lasts.len()
		({ ..core, keys: [], order: [], free: [], index: Engine.index_empty, lasts: List.repeat([], ncols), pend: [], dirty: [], fresh: [] }, $tx)
	}

	## Keyed reconciliation on keys alone. Emits REMOVE and MOVE commands,
	## assigns slots to new keys and leaves their positions (ascending) in
	## `fresh`; the typed layer then creates those rows (INST, from the end,
	## each before its successor) and compares kept items. Kept rows are
	## moved relative to the next kept row, so moves never reference a row
	## that does not exist yet. Fast paths: common prefix and suffix, swapped
	## ends, pure insertion and removal; otherwise an LIS keyed move.
	reconcile_keys : EachCore, List(Str), U64, Tx -> (EachCore, Tx, List(Str))
	reconcile_keys = |core0, nk, n_new, tx| {
		core = { ..core0, fresh: core0.fresh.clear(), fresh_lo: 0, fresh_hi: 0 }
		n_old = core.order.len()
		if n_new == 0 {
			if n_old == 0 (core, tx, nk) else {
				(c, t) = Engine.clear_core(core, True, tx)
				(c, t, nk)
			}
		} else if n_old == 0 {
			# From empty: the key list becomes the key column (slot = position).
			var $index = Engine.index_empty
			var $order = List.with_capacity(n_new)
			var $p = 0.U64
			while $p < n_new {
				$index = Engine.index_insert($index, nk, nk.get($p) ?? crash "key", $p.to_u32_wrap())
				$order = $order.append($p.to_u32_wrap())
				$p = $p + 1
			}
			keys = if nk.len() == n_new nk else nk.take_first(n_new)
			({ ..core, keys, index: $index, order: $order, free: [], pend: List.repeat(0, n_new), fresh_lo: 0, fresh_hi: n_new }, tx, [])
		} else {
			var $c = core
			var $tx = tx
			var $i = 0.U64
			var $oe = n_old
			var $ne = n_new
			var $go = True
			while $go {
				while $i < $oe and $i < $ne and Engine.key_of_slot($c, $c.order.get($i) ?? 0) == (nk.get($i) ?? "") {
					$i = $i + 1
				}
				while $i < $oe and $i < $ne and Engine.key_of_slot($c, $c.order.get($oe - 1) ?? 0) == (nk.get($ne - 1) ?? "") {
					$oe = $oe - 1
					$ne = $ne - 1
				}
				$go = False
				if $oe - $i >= 2 and $ne - $i >= 2 and $i < $oe and $i < $ne {
					a = $c.order.get($i) ?? 0
					b = $c.order.get($oe - 1) ?? 0
					if Engine.key_of_slot($c, b) == (nk.get($i) ?? "") and Engine.key_of_slot($c, a) == (nk.get($ne - 1) ?? "") {
						na = Engine.row_node($c.site, a)
						nb = Engine.row_node($c.site, b)
						after = Engine.ref_at($c, $oe)
						$tx = Engine.cmd_ids(Engine.cmd_ids($tx, 4, nb, na), 4, na, after)
						{ order, .. } = $c
						$c = { ..$c, order: order.swap($i, $oe - 1) ?? crash "order" }
						$i = $i + 1
						$oe = $oe - 1
						$ne = $ne - 1
						$go = True
					}
				}
			}
			i = $i
			oe = $oe
			ne = $ne
			if i == oe and i == ne {
				($c, $tx, nk)
			} else if i == oe {
				var $mid = List.with_capacity(ne - i)
				var $k = i
				while $k < ne {
					(c2, slot) = Engine.new_slot($c, nk.get($k) ?? crash "key", $k, False)
					$c = c2
					$mid = $mid.append(slot)
					$k = $k + 1
				}
				({ ..Engine.splice_order($c, i, oe, $mid), fresh_lo: i, fresh_hi: ne }, $tx, nk)
			} else if i == ne {
				var $k = i
				while $k < oe {
					(c2, t2) = Engine.drop_slot($c, $c.order.get($k) ?? crash "order", True, $tx)
					$c = c2
					$tx = t2
					$k = $k + 1
				}
				{ order, .. } = $c
				kept = if oe - i == 1 order.drop_at(i) else order.sublist({ start: 0, len: i }).concat(order.sublist({ start: oe, len: order.len() - oe }))
				({ ..$c, order: kept }, $tx, nk)
			} else {
				(c3, t3) = Engine.reconcile_general($c, nk, i, oe, ne, $tx)
				(c3, t3, nk)
			}
		}
	}

	splice_order : EachCore, U64, U64, List(U32) -> EachCore
	splice_order = |core, i, oe, mid| {
		{ order, .. } = core
		{ ..core, order: order.sublist({ start: 0, len: i }).concat(mid).concat(order.sublist({ start: oe, len: order.len() - oe })) }
	}

	reconcile_general : EachCore, List(Str), U64, U64, U64, Tx -> (EachCore, Tx)
	reconcile_general = |core, nk, i, oe, ne, tx| {
		nslots = core.keys.len()
		var $oldpos = List.repeat(0.U64, nslots)
		var $k = i
		while $k < oe {
			s = core.order.get($k) ?? crash "order"
			$oldpos = $oldpos.set(s.to_u64(), $k + 1) ?? crash "pos"
			$k = $k + 1
		}
		var $found = List.with_capacity(ne - i)
		var $seen = List.repeat(False, nslots)
		$k = i
		while $k < ne {
			key = nk.get($k) ?? crash "key"
			r = match Engine.index_find(core.index, core.keys, key, Engine.hash_str(key)) {
				Ok(s) => {
					if ($oldpos.get(s.to_u64()) ?? 0) == 0 {
						crash "duplicate key in each"
					}
					if $seen.get(s.to_u64()) ?? False {
						crash "duplicate key in each"
					}
					$seen = $seen.set(s.to_u64(), True) ?? $seen
					s.to_u64() + 1
				}
				Err(Missing) => 0
			}
			$found = $found.append(r)
			$k = $k + 1
		}
		var $c = core
		var $tx = tx
		$k = i
		while $k < oe {
			s = core.order.get($k) ?? crash "order"
			if !($seen.get(s.to_u64()) ?? False) {
				(c2, t2) = Engine.drop_slot($c, s, True, $tx)
				$c = c2
				$tx = t2
			}
			$k = $k + 1
		}
		var $seq = List.with_capacity($found.len())
		for f in $found {
			$seq = $seq.append(if f == 0 0 else $oldpos.get(f - 1) ?? 0)
		}
		stable = Engine.lis_mark($seq)
		# kept rows from the end, each before the next kept row
		var $ref = Engine.ref_at(core, oe)
		var $p = ne
		while $p > i {
			$p = $p - 1
			f = $found.get($p - i) ?? 0
			if f != 0 {
				node = Engine.row_node(core.site, (f - 1).to_u32_wrap())
				if !(stable.get($p - i) ?? False) {
					$tx = Engine.cmd_ids($tx, 4, node, $ref)
				}
				$ref = node
			}
		}
		# new rows take slots in position order
		var $mid = List.with_capacity(ne - i)
		$p = i
		while $p < ne {
			f = $found.get($p - i) ?? 0
			if f == 0 {
				(c2, slot) = Engine.new_slot($c, nk.get($p) ?? crash "key", $p, True)
				$c = c2
				$mid = $mid.append(slot)
			} else {
				$mid = $mid.append((f - 1).to_u32_wrap())
			}
			$p = $p + 1
		}
		(Engine.splice_order($c, i, oe, $mid), $tx)
	}

	lis_mark : List(U64) -> List(Bool)
	lis_mark = |seq| {
		n = seq.len()
		var $tails = []
		var $prev = List.repeat(0.U64, n)
		var $i = 0.U64
		while $i < n {
			v = seq.get($i) ?? 0
			if v != 0 {
				var $lo = 0.U64
				var $hi = $tails.len()
				while $lo < $hi {
					mid = ($lo + $hi) // 2
					tv = seq.get($tails.get(mid) ?? 0) ?? 0
					if tv < v {
						$lo = mid + 1
					} else {
						$hi = mid
					}
				}
				p = if $lo > 0 ($tails.get($lo - 1) ?? 0) + 1 else 0
				$prev = $prev.set($i, p) ?? $prev
				$tails = if $lo == $tails.len() $tails.append($i) else ($tails.set($lo, $i) ?? $tails)
			}
			$i = $i + 1
		}
		var $out = List.repeat(False, n)
		var $cur = match $tails.last() {
			Ok(t) => t + 1
			Err(_) => 0
		}
		while $cur != 0 {
			$out = $out.set($cur - 1, True) ?? $out
			$cur = $prev.get($cur - 1) ?? 0
		}
		$out
	}

	put_skeys : EachCore, List(Str) -> EachCore
	put_skeys = |{ site, parent, anchor, sole, depth, vholes, vhit, outer_mask, selm, keys, order, free, index, pend, dirty, lasts, sels, known, fresh, fresh_lo, fresh_hi, skeys: _ }, skeys| {
		{ site, parent, anchor, sole, depth, vholes, vhit, outer_mask, selm, keys, order, free, index, pend, dirty, lasts, sels, known, fresh, fresh_lo, fresh_hi, skeys }
	}

	take_skeys : EachCore -> (EachCore, List(Str))
	## The retained key scratch: never shrunk (a cleared list is a slice that
	## reallocates on append), the typed pass overwrites its prefix.
	take_skeys = |{ site, parent, anchor, sole, depth, vholes, vhit, outer_mask, selm, keys, order, free, index, pend, dirty, lasts, sels, known, fresh, fresh_lo, fresh_hi, skeys }| {
		({ site, parent, anchor, sole, depth, vholes, vhit, outer_mask, selm, keys, order, free, index, pend, dirty, lasts, sels, known, fresh, fresh_lo, fresh_hi, skeys: [] }, skeys)
	}

	## ------------------------------------------------------------------
	## Sink: what the typed row passes write through, moved out of the core
	## and the Tx for the duration of one pass (small to pass around).
	Sink : {
		cmds : List(U8),
		evals : U64,
		lasts : List(List(Str)),
		sels : List(Str),
		known : Bool,
		vholes : List(VHole),
		pend : List(U64),
		dirty : List(U32),
		depth : U64,
	}

	## A read-only view of the row tables for one typed pass.
	View : { site : U32, parent : U32, end : U32, order : List(U32), keys : List(Str), fresh : List(U32), lo : U64, hi : U64, vhit : List(U64), selm : U64 }

	sink_take : EachCore, Tx -> (EachCore, Tx, Sink, View)
	sink_take = |core, { cmds, evals, ids }| {
		{ lasts, sels, known, vholes, pend, dirty, depth, site, parent, order, keys, fresh, fresh_lo, fresh_hi, vhit, selm, .. } = core
		view = { site, parent, end: Engine.end_ref(core), order, keys, fresh, lo: fresh_lo, hi: fresh_hi, vhit, selm }
		sink = { cmds, evals, lasts, sels, known, vholes, pend, dirty, depth }
		({ ..core, lasts: [], sels: [], pend: [], dirty: [] }, { cmds: [], evals: 0, ids }, sink, view)
	}

	sink_put : EachCore, Tx, Sink -> (EachCore, Tx)
	sink_put = |core, { cmds: _, evals: _, ids }, sink| {
		{ cmds, evals, lasts, sels, known, vholes: _, pend, dirty, depth: _ } = sink
		({ ..core, lasts, sels, known, pend, dirty }, { cmds, evals, ids })
	}

	sink_inst : Sink, U32, U32, U32, U32 -> Sink
	sink_inst = |sink, node, parent, before, site| {
		{ cmds, .. } = sink
		{ ..sink, cmds: Engine.put_u32(Engine.put_u32(Engine.put_u32(Engine.put_u32(cmds.append(1), node), parent), before), site) }
	}

	## One value hole of a new row; `sk` is the selector key when this is the
	## first row created while the selection is unknown.
	sink_val : Sink, U32, U64, Str -> Sink
	sink_val = |sink, slot, ri, v| {
		{ cmds, evals, lasts, vholes, .. } = sink
		hole = vholes.get(ri) ?? crash "vhole"
		c = Engine.put_str(cmds, v)
		if hole.live {
			{ list, prev } = lasts.replace(hole.col, []) ?? crash "lasts"
			{ ..sink, cmds: c, evals: evals + 1, lasts: list.set(hole.col, Engine.put_grow(prev, slot.to_u64(), v)) ?? crash "lasts" }
		} else {
			{ ..sink, cmds: c, evals: evals + 1 }
		}
	}

	needs_skey : Sink, U64 -> Bool
	needs_skey = |sink, ri| !sink.known and (sink.vholes.get(ri).map_ok(|h| h.smask) ?? 0) != 0

	sink_sel : Sink, U64, Str -> Sink
	sink_sel = |sink, ri, k| {
		{ sels, .. } = sink
		{ ..sink, sels: sels.set(ri, k) ?? sels }
	}

	sink_known : Sink, U64 -> Sink
	sink_known = |sink, selm| if selm != 0 { ..sink, known: True } else sink

	sink_mark : Sink, U32 -> Sink
	sink_mark = |sink, slot| {
		{ pend, dirty, depth, .. } = sink
		(p2, d2) = Engine.mark_cols(pend, dirty, slot, Engine.bit(depth))
		{ ..sink, pend: p2, dirty: d2 }
	}

	## Take a dirty row's pending mask.
	sink_pend : Sink, U32 -> (Sink, U64)
	sink_pend = |sink, slot| {
		{ pend, .. } = sink
		si = slot.to_u64()
		m = pend.get(si) ?? 0
		({ ..sink, pend: pend.set(si, 0) ?? pend }, m)
	}

	take_dirty : Sink -> (Sink, List(U32))
	take_dirty = |sink| {
		{ dirty, .. } = sink
		({ ..sink, dirty: [] }, dirty)
	}

	give_dirty : Sink, List(U32) -> Sink
	give_dirty = |sink, dirty| { ..sink, dirty: dirty.clear() }

	## A re-evaluated hole of a kept row: prune if equal, else emit and remember.
	sink_update : Sink, U32, U32, U64, Str -> Sink
	sink_update = |sink, site, slot, ri, v| {
		{ cmds, evals, lasts, vholes, .. } = sink
		hole = vholes.get(ri) ?? crash "vhole"
		si = slot.to_u64()
		{ list, prev } = lasts.replace(hole.col, []) ?? crash "lasts"
		old = prev.get(si) ?? ""
		if v == old {
			{ ..sink, evals: evals + 1, lasts: list.set(hole.col, prev) ?? crash "lasts" }
		} else {
			op = if hole.kind == 1 2 else 3
			c = Engine.put_str(Engine.put_u32(cmds.append(op), Engine.row_node(site, slot)).append(hole.hidx), v)
			{ ..sink, cmds: c, evals: evals + 1, lasts: list.set(hole.col, prev.set(si, v) ?? crash "lasts") ?? crash "lasts" }
		}
	}

	## Selection: does hole ri watch the changed selector layer?
	sel_hit : EachCore, U64, U64 -> Bool
	sel_hit = |core, ri, mask| (core.vholes.get(ri).map_ok(|h| h.smask) ?? 0).bitwise_and(mask) != 0

	set_unknown : EachCore -> EachCore
	set_unknown = |core| { ..core, known: False }

	sel_apply : EachCore, U64, Str -> EachCore
	sel_apply = |core, ri, nk| {
		smask = core.vholes.get(ri).map_ok(|h| h.smask) ?? 0
		ok = core.sels.get(ri) ?? ""
		if core.known and nk == ok {
			core
		} else {
			var $c = core
			if $c.known {
				match Engine.index_find($c.index, $c.keys, ok, Engine.hash_str(ok)) {
					Ok(s) => {
						$c = Engine.mark($c, s, smask)
					}
					Err(_) => {}
				}
			} else {
				$c = Engine.mark_all($c, smask)
			}
			match Engine.index_find($c.index, $c.keys, nk, Engine.hash_str(nk)) {
				Ok(s) => {
					$c = Engine.mark($c, s, smask)
				}
				Err(_) => {}
			}
			{ sels, .. } = $c
			{ ..$c, sels: sels.set(ri, nk) ?? sels, known: True }
		}
	}

	is_live : EachCore, U64 -> Bool
	is_live = |core, si| {
		match core.keys.get(si) {
			Ok(key) => {
				match Engine.index_find(core.index, core.keys, key, Engine.hash_str(key)) {
					Ok(s) => s.to_u64() == si
					Err(_) => False
				}
			}
			Err(_) => False
		}
	}

	each_dispose : EachCore, Bool, Tx -> Tx
	each_dispose = |core, remove, tx| {
		t1 = if remove Engine.clear_core(core, True, tx).1 else tx
		t2 = if !core.sole { if remove Engine.free_id(Engine.cmd_ids(t1, 5, core.anchor, 0), core.anchor) else Engine.free_id(t1, core.anchor) } else t1
		Engine.free_site(t2, core.site)
	}

	## ------------------------------------------------------------------
	## Typed each layer: specialised per (context, item). Loops over typed
	## items and closures; everything structural is one call into the core.
	EachT(ctx, item) : { rows : Val(ctx, List(item)), key : (item -> Str), reads : List(Read(Row(ctx, item))), handlers : List(Handler(Row(ctx, item))) }

	## After `reconcile_keys`: put new items, compare kept ones (equal items
	## are pruned here), then create the fresh rows from the end.
	each_apply : EachT(ctx, item), EachCore, List(item), ctx, List(item), Tx -> (EachCore, List(item), Tx)
		where [item.is_eq : item, item -> Bool]
	each_apply = |t, core, items, env, list, tx| {
		(c1, t1, s0, view) = Engine.sink_take(core, tx)
		{ site, parent, end, order, keys, fresh, lo, hi, selm, vhit: _ } = view
		var $items = items
		var $sink = s0
		var $f = 0.U64
		var $p = 0.U64
		n = list.len()
		while $p < n {
			slot = order.get($p) ?? crash "order"
			item = list.get($p) ?? crash "row"
			si = slot.to_u64()
			if ($p >= lo and $p < hi) or (fresh.get($f) ?? 4294967295).to_u64() == $p {
				$items = Engine.put_at($items, si, item)
				$f = if $p >= lo and $p < hi $f else $f + 1
			} else {
				match $items.get(si) {
					Ok(old) => {
						if old != item {
							$items = $items.set(si, item) ?? crash "item"
							$sink = Engine.sink_mark($sink, slot)
						}
					}
					Err(_) => crash "item"
				}
			}
			$p = $p + 1
		}
		ranged = hi > lo
		var $k = if ranged hi - lo else fresh.len()
		while $k > 0 {
			$k = $k - 1
			p = if ranged lo + $k else (fresh.get($k) ?? 0).to_u64()
			slot = order.get(p) ?? crash "order"
			before = match order.get(p + 1) {
				Ok(s) => Engine.row_node(site, s)
				Err(_) => end
			}
			$sink = Engine.sink_inst($sink, Engine.row_node(site, slot), parent, before, site)
			row_env = Row.{ outer: env, key: keys.get(slot.to_u64()) ?? crash "key", item: $items.get(slot.to_u64()) ?? crash "item" }
			var $ri = 0.U64
			for r in t.reads {
				$sink = Engine.sink_val($sink, slot, $ri, (r.read)(row_env))
				if Engine.needs_skey($sink, $ri) {
					$sink = Engine.sink_sel($sink, $ri, (r.skey)(row_env))
				}
				$ri = $ri + 1
			}
			$sink = Engine.sink_known($sink, selm)
		}
		(c2, t2) = Engine.sink_put(c1, t1, $sink)
		(c2, $items, t2)
	}

	settle : EachT(ctx, item), EachCore, List(item), ctx, Tx -> (EachCore, Tx)
	settle = |t, core, items, env, tx| {
		if core.dirty.is_empty() {
			(core, tx)
		} else {
			(c1, t1, s0, view) = Engine.sink_take(core, tx)
			{ site, keys, vhit, .. } = view
			(s1, dirty) = Engine.take_dirty(s0)
			var $sink = s1
			nv = vhit.len()
			for slot in dirty {
				(s2, m) = Engine.sink_pend($sink, slot)
				$sink = s2
				row_env = Row.{ outer: env, key: keys.get(slot.to_u64()) ?? crash "key", item: items.get(slot.to_u64()) ?? crash "item" }
				var $ri = 0.U64
				while $ri < nv {
					if (vhit.get($ri) ?? 0).bitwise_and(m) != 0 {
						v = match t.reads.get($ri) {
							Ok(r) => (r.read)(row_env)
							Err(_) => crash "read"
						}
						$sink = Engine.sink_update($sink, site, slot, $ri, v)
					}
					$ri = $ri + 1
				}
			}
			Engine.sink_put(c1, t1, Engine.give_dirty($sink, dirty))
		}
	}

	select_changed : EachT(ctx, item), EachCore, List(item), ctx, U64 -> EachCore
	select_changed = |t, core, items, env, mask| {
		match core.order.first() {
			Err(_) => Engine.set_unknown(core)
			Ok(s0) => {
				probe = Row.{ outer: env, key: Engine.key_of_slot(core, s0), item: items.get(s0.to_u64()) ?? crash "item" }
				var $c = core
				var $ri = 0.U64
				for r in t.reads {
					if Engine.sel_hit($c, $ri, mask) {
						$c = Engine.sel_apply($c, $ri, (r.skey)(probe))
					}
					$ri = $ri + 1
				}
				$c
			}
		}
	}

	## Keys of the new list into the core's retained scratch, then reconcile.
	each_rows : EachT(ctx, item), EachCore, List(item), ctx, List(item), Tx -> (EachCore, List(item), Tx)
		where [item.is_eq : item, item -> Bool]
	each_rows = |t, core, items, env, list, tx| {
		(c0, scratch) = Engine.take_skeys(core)
		var $k = scratch
		var $i = 0.U64
		for item in list {
			key = (t.key)(item)
			$k = if $i < $k.len() $k.set($i, key) ?? crash "scratch" else $k.append(key)
			$i = $i + 1
		}
		(c1a, t1, back) = Engine.reconcile_keys(c0, $k, list.len(), tx)
		c1 = Engine.put_skeys(c1a, back)
		Engine.each_apply(t, c1, if list.is_empty() [] else items, env, list, t1)
	}

	each_changed : EachT(ctx, item), EachCore, List(item), ctx, U64, Tx -> (EachCore, List(item), Tx)
		where [item.is_eq : item, item -> Bool]
	each_changed = |t, core, items, env, mask, tx| {
		selm = core.selm
		c1 = Engine.each_full(core, mask)
		c2 = if selm.bitwise_and(mask) != 0 Engine.select_changed(t, c1, items, env, mask) else c1
		(c3, it3, t1) = if Engine.eff_mask(t.rows).bitwise_and(mask) != 0 {
			Engine.each_rows(t, c2, items, env, (t.rows.read)(env), Engine.count_evals(tx, 1))
		} else {
			(c2, items, tx)
		}
		(c4, t4) = Engine.settle(t, c3, it3, env, t1)
		(c4, it3, t4)
	}

	each_fire : EachT(ctx, item), EachCore, List(item), ctx, List(U32), U64, U32 -> Out(ctx)
	each_fire = |t, core, items, env, path, pos, h| {
		slot = path.get(pos) ?? crash "row path"
		si = slot.to_u64()
		if !Engine.is_live(core, si) or pos + 1 < path.len() {
			Pending(env, 0)
		} else {
			match t.handlers.get(h.to_u64()) {
				Ok(handler) => {
					row_env = Row.{ outer: env, key: Engine.key_of_slot(core, slot), item: items.get(si) ?? crash "item" }
					{ outer, key: _, item: _ } = (handler.run)(row_env)
					Pending(outer, handler.mask)
				}
				Err(_) => Pending(env, 0)
			}
		}
	}

	each_inst : EachT(ctx, item), EachCore, List(item) -> Inst(ctx)
		where [item.is_eq : item, item -> Bool]
	each_inst = |t, core, items| Inst(|env, msg, tx| {
		match msg {
			Changed(mask) => {
				(c4, it4, t4) = Engine.each_changed(t, core, items, env, mask, tx)
				(Engine.each_inst(t, c4, it4), Done, t4)
			}
			Fire(path, pos, h) => {
				out = Engine.each_fire(t, core, items, env, path, pos, h)
				(Engine.each_inst(t, core, items), out, tx)
			}
			Dispose(remove) => (Engine.noop({}), Done, Engine.each_dispose(core, remove, tx))
		}
	})

	## ------------------------------------------------------------------
	## Application-facing constructors.
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Engine.site(Mount(|env, args, tx| {
		depth = args.depth + 1
		handle = {
			mask: Engine.bit(depth),
			get: |e| e.value,
			modify: |e, f| {
				{ outer, value } = e
				In.{ outer, value: f(value) }
			},
		}
		elem = body(handle)
		(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, tx)
		reads = block.core.reads
		(Engine.state_inst(init, block, depth), reads, tx1)
	}))

	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Engine.site(Mount(|env, args, tx| {
		depth = args.depth + 1
		{ ops, reads, handlers, mounts } = template(RowRef.{ depth })
		if !mounts.is_empty() {
			crash "nested sites inside each rows are not supported by the p3 spike engine"
		}
		(core, tx1) = Engine.each_core_new(ops, args, depth, tx)
		t = { rows, key, reads, handlers }
		(core2, items, tx2) = Engine.each_rows(t, core, [], env, (rows.read)(env), Engine.count_evals(tx1, 1))
		r = Engine.eff_mask(rows).bitwise_or(core2.outer_mask).bitwise_or(core2.selm)
		(Engine.each_inst(t, core2, items), r, tx2)
	}))

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Engine.site(Mount(|env, args, tx| {
		(anchor, tx1) = Engine.alloc_id(tx)
		tx2 = Engine.cmd_node(tx1, 10, anchor, args.parent, args.before, "")
		c = (cond.read)(env)
		elem = if c yes() else no()
		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, Engine.count_evals(tx2, 1))
		reads = Engine.upto(args.depth)
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path }
		(Engine.when_inst(w, c, block), reads, tx3)
	}))

	site : Mount(ctx) -> Elem(ctx)
	site = |m| { ops: [SiteOp], reads: [], handlers: [], mounts: [m] }

	component : (() -> Elem(ctx)) -> Elem(ctx)
	component = |body| body()

	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value, sel: NoSel }

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| {
		var $ops = [Open(tag, kids.len())]
		var $reads = []
		var $hs = []
		var $ms = []
		for a in attrs {
			match a {
				AStatic(n, v) => {
					$ops = $ops.append(AttrS(n, v))
				}
				ADyn(n, v) => {
					(r, m, sm) = Engine.read_of(v)
					$ops = $ops.append(AttrH(n, m, sm))
					$reads = $reads.append(r)
				}
				AOn(h) => {
					$ops = $ops.append(OnA)
					$hs = $hs.append(h)
				}
			}
		}
		for k in kids {
			{ ops, reads, handlers, mounts } = k
			$ops = $ops.concat(ops)
			$reads = $reads.concat(reads)
			$hs = $hs.concat(handlers)
			$ms = $ms.concat(mounts)
		}
		{ ops: $ops.append(Close), reads: $reads, handlers: $hs, mounts: $ms }
	}

	text : Str -> Elem(ctx)
	text = |s| { ops: [TextS(s)], reads: [], handlers: [], mounts: [] }

	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| {
		(r, m, sm) = Engine.read_of(v)
		{ ops: [TextH(m, sm)], reads: [r], handlers: [], mounts: [] }
	}

	attr : Str, Str -> Attr(ctx)
	attr = |name, value| AStatic(name, value)

	attr_v : Str, Val(ctx, Str) -> Attr(ctx)
	attr_v = |name, v| ADyn(name, v)

	class : Str -> Attr(ctx)
	class = |c| AStatic("class", c)

	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| ADyn("class", v)

	test_id_v : Val(ctx, Str) -> Attr(ctx)
	test_id_v = |v| ADyn("data-testid", v)

	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| AOn(h)

	button : Str, Handler(ctx) -> Elem(ctx)
	button = |label, h| Engine.element("button", [AOn(h)], [Engine.text(label)])

	checkbox : Str, Val(ctx, Bool), Handler(ctx) -> Elem(ctx)
	checkbox = |label, checked, h| Engine.element("input", [AStatic("type", "checkbox"), AStatic("aria-label", label), ADyn("data-checked", checked.map(|b| if b "true" else "false")), AOn(h)], [])

	## ------------------------------------------------------------------
	## The engine state the host holds in one Box.
	App := { root : Inst(Root), tx : Tx }

	new_tx : List(U8) -> Tx
	new_tx = |cmds| { cmds, evals: 0, ids: [{ next: 1, free: [], routes: [], paths: [[]], site_free: [] }] }

	mount : Elem(Root) -> App
	mount = |elem| {
		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, Engine.new_tx([]))
		{ root: Engine.block_inst(block), tx }
	}

	event : App, U32, U32 -> App
	event = |{ root, tx }, node, handler| {
		sid = node.shr_zf_wrap(20)
		d = tx.ids.get(0) ?? Engine.ids_empty
		target = if sid == 0 {
			match d.routes.get(node.to_u64()) ?? NoRoute {
				NoRoute => Err(Stale)
				Route(path, h) => Ok((path, h))
			}
		} else {
			match d.paths.get(sid.to_u64()) {
				Ok(path) => if path.is_empty() Err(Stale) else Ok((path.append(node.bitwise_and(1048575) - 1), handler))
				Err(_) => Err(Stale)
			}
		}
		match target {
			Err(Stale) => { root, tx }
			Ok((path, h)) => {
				(root2, _, tx2) = Engine.call(root, Root, Fire(path, 0, h), tx)
				{ root: root2, tx: tx2 }
			}
		}
	}

	take_cmds : App, List(U8) -> (App, List(U8))
	take_cmds = |{ root, tx }, buf| {
		{ cmds, evals, ids } = tx
		({ root, tx: { cmds: buf.clear(), evals, ids } }, cmds)
	}

	evals : App -> U64
	evals = |a| a.tx.evals

	Program(state) : {
		init : () -> (state, List(U8)),
		event : state, List(U8), U32, U32 -> (state, List(U8)),
	}

	program : (() -> Elem(Root)) -> Program(App)
	program = |view| {
		init: || Engine.take_cmds(Engine.mount(view()), []),
		event: |inst, buf, node, handler| {
			{ root, tx } = inst
			{ cmds: _, evals: ev, ids } = tx
			fresh = { root, tx: { cmds: buf.clear(), evals: ev, ids } }
			Engine.take_cmds(Engine.event(fresh, node, handler), [])
		},
	}
}
