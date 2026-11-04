## Phase 4 app engine (p4apps): the p3copy unified D+each engine plus the
## owned child-call loops (roc-lang/roc#12847), event payloads (input values),
## named events, a fixed-environment component boundary with any prop type and
## an outward action list, and a memoised shared derivation (`derive`).
##
## Every dynamic site (state, conditional, each, root) is one closure that
## captures its own typed storage and takes a message. Only that closure
## references the storage, so consuming the closure and rebuilding it updates
## storage in place (Phase 1b; two closures sharing a capture copy,
## roc-lang/roc#12841).
##
## Contexts are environments. `In(outer, s)` is "inside a state of type s",
## `Row(outer, item)` is "inside one row of an each site". A `Val(ctx, a)` reads
## from its environment and records the absolute layers it reads (`mask`), plus
## an optional keyed selector (`sel`) so a row template can depend on "is this
## row the selected one" with work proportional to two rows.
##
## An each site compiles its row template once per site into a DOM template
## (TEMPLATE command) and a hole table. Each row then costs one INST command
## and column appends: items, keys, the last value of every dynamic hole, and
## a slot in the key index. Nested sites inside a row (state, when, each) make
## the row "dynamic": each row then also owns a small list of child instances.
##
## Handlers are environment transformers (`ctx -> ctx`). The handler's result
## flows back up the dispatch path; each state site takes its own layer and
## the highest changed layer refreshes the subtree below it. State-level
## equality pruning is not done (it would keep the old value alive and force
## a copy of any list in the state); every hole prunes by equality instead.
##
## Command stream (little endian, u32 ids, strings are u32 length + bytes):
##   1 INST     node parent before tpl  then per template hole: text/attr: str,
##              click: nothing, bind: u32 node id for the hole's placeholder
##   2 TEXT     node hole:u8 str        (row text hole)
##   3 HATTR    node hole:u8 str        (row attribute hole)
##   4 MOVE     node before             (0 = append to its parent)
##   5 REMOVE   node
##   6 CLEAR    parent site             (remove all children; drop site rows)
##   7 TEMPLATE tpl len bytes
##   8 ELEM     node parent before tag  (before != 0: insert before it)
##   9 ATTR     node name value         (static or dynamic attribute)
##  10 TEXTNODE node parent before text
##  11 LISTEN   node handler event:str
##  12 SETTEXT  node text
## Node ids: rows are (site << 20) | (slot + 1); other nodes use site 0.
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

		## Use this value inside a state body nested in its context.
		lift : Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}

		## Use this value inside a row template nested in its context.
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

	## Mask a plain block must watch for a value: its layers and its selector's.
	eff_mask : Val(ctx, a) -> U64
	eff_mask = |v| v.mask.bitwise_or(Engine.sel_mask(v.sel))

	## A handler transforms the environment; it also receives the event's
	## payload (an input's value, "true"/"false" for a checkbox, "" for a click).
	Handler(ctx) := { mask : U64, run : (ctx, Str -> ctx) }.{
		lift : Handler(ctx) -> Handler(In(ctx, s))
		lift = |{ mask, run }| {
			mask,
			run: |e, p| {
				{ outer, value } = e
				In.{ outer: run(outer, p), value }
			},
		}

		lift_row : Handler(ctx) -> Handler(Row(ctx, item))
		lift_row = |{ mask, run }| {
			mask,
			run: |e, p| {
				{ outer, key, item } = e
				Row.{ outer: run(outer, p), key, item }
			},
		}
	}

	## A state handle usable in context `ctx`: a lens from the context to the
	## state's value. `modify` consumes the context, so the state is uniquely
	## owned while the reducer runs.
	State(ctx, s) := { mask : U64, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }.{
		val : State(ctx, s) -> Val(ctx, s)
		val = |{ mask, get, modify: _ }| { mask, read: get, sel: NoSel }

		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ mask, get: _, modify }, f| { mask, run: |e, _| modify(e, f) }

		## A reducer that also receives a context value read when the event
		## fires (typically the row key).
		update_by : State(ctx, s), Val(ctx, b), (s, b -> s) -> Handler(ctx)
		update_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, _| {
					b = read(e)
					modify(e, |s| f(s, b))
				},
			}
		}

		## A reducer that receives the event payload (an input's value).
		set_value : State(ctx, s), (s, Str -> s) -> Handler(ctx)
		set_value = |{ mask, get: _, modify }, f| { mask, run: |e, p| modify(e, |s| f(s, p)) }

		## Payload plus a context value read when the event fires.
		set_value_by : State(ctx, s), Val(ctx, b), (s, b, Str -> s) -> Handler(ctx)
		set_value_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, p| {
					b = read(e)
					modify(e, |s| f(s, b, p))
				},
			}
		}

		## Append an action to a component's outward action list.
		push : State(ctx, List(a)), a -> Handler(ctx)
		push = |{ mask, get: _, modify }, a| { mask, run: |e, _| modify(e, |l| l.append(a)) }

		## Append an action built from a context value (typically the row key).
		push_by : State(ctx, List(a)), Val(ctx, b), (b -> a) -> Handler(ctx)
		push_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, _| {
					b = read(e)
					modify(e, |l| l.append(f(b)))
				},
			}
		}

		## Append an action built from the payload and a context value.
		push_value_by : State(ctx, List(a)), Val(ctx, b), (b, Str -> a) -> Handler(ctx)
		push_value_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, p| {
					b = read(e)
					modify(e, |l| l.append(f(b, p)))
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

	## Exact-key selection: `RowRef.select` makes only the old and the new
	## selected rows re-evaluate when the selection changes.
	Keyed(ctx, v) : { mask : U64, selected : (ctx -> Str), yes : v, no : v }

	keyed : Val(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sv, yes, no| {
		{ mask, read, sel } = sv
		{ mask: mask.bitwise_or(Engine.sel_mask(sel)), selected: read, yes, no }
	}

	## A row accessor for an each site's template. The template runs once per
	## site; `depth` is the site's row layer.
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

	Attr(ctx) := [Static(Str, Str), Dyn(Str, Val(ctx, Str)), On(Str, Handler(ctx))]

	Elem(ctx) := [
		Element(Str, List(Attr(ctx)), List(Elem(ctx))),
		Text(Str),
		TextV(Val(ctx, Str)),
		## A dynamic site and its conservative read mask, given the depth the
		## site is mounted at (computed without mounting it).
		Site(Mount(ctx), (U64 -> U64)),
	]

	## `sole`: the site is the only child of `parent` and sits at its end.
	## `cap` != 0: a known superset of what the site can read; the site may
	## report it instead of computing its reads (set inside each rows).
	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64 }

	Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

	Msg := [Fire(List(U32), U64, U32, Str), Changed(U64), Dispose(Bool)]

	## Fire always hands the (possibly transformed) environment back up with
	## the mask of the layer it changed (0 = nothing changed).
	Out(ctx) := [Done, Pending(ctx, U64)]

	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

	Route := [NoRoute, Route(List(U32), U32)]

	## Storage captured by a site closure. Wrapping a site's captures in a
	## single-tag nominal and unwrapping them inside the closure body keeps
	## --opt=speed/size from treating them as borrowed and copying every list
	## they hold on each update (roc-lang/roc#12846).
	Held(a) := [Held(a)]

	Tx : {
		cmds : List(U8),
		next : U32,
		free : List(U32),
		routes : List(Route),
		evals : U64,
		paths : List(List(U32)),
		site_free : List(U32),
	}

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
	emit = |{ cmds, next, free, routes, evals, paths, site_free }, write| { cmds: write(cmds), next, free, routes, evals, paths, site_free }

	count_evals : Tx, U64 -> Tx
	count_evals = |{ cmds, next, free, routes, evals, paths, site_free }, n| { cmds, next, free, routes, evals: evals + n, paths, site_free }

	## Allocate a static node id, reusing a freed one first.
	alloc_id : Tx -> (U32, Tx)
	alloc_id = |{ cmds, next, free, routes, evals, paths, site_free }| {
		match free.last() {
			Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, evals, paths, site_free })
			Err(_) => {
				if next >= 1048575 {
					crash "static node ids exhausted"
				}
				(next, { cmds, next: next + 1, free, routes, evals, paths, site_free })
			}
		}
	}

	## Release a static node id and its route.
	free_id : Tx, U32 -> Tx
	free_id = |{ cmds, next, free, routes, evals, paths, site_free }, id| {
		routes2 = if id.to_u64() < routes.len() routes.set(id.to_u64(), NoRoute) ?? routes else routes
		{ cmds, next, free: free.append(id), routes: routes2, evals, paths, site_free }
	}

	set_route : Tx, U32, List(U32), U32 -> Tx
	set_route = |{ cmds, next, free, routes, evals, paths, site_free }, id, path, handler| {
		var $r = routes
		while $r.len() <= id.to_u64() {
			$r = $r.append(NoRoute)
		}
		{ cmds, next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, evals, paths, site_free }
	}

	## Allocate an each-site id (template id and row node prefix).
	alloc_site : Tx, List(U32) -> (U32, Tx)
	alloc_site = |{ cmds, next, free, routes, evals, paths, site_free }, path| {
		match site_free.last() {
			Ok(s) => (s, { cmds, next, free, routes, evals, paths: paths.set(s.to_u64(), path) ?? crash "site", site_free: site_free.drop_last(1) })
			Err(_) => {
				s = paths.len().to_u32_wrap()
				if s >= 4095 {
					crash "each sites exhausted"
				}
				(s, { cmds, next, free, routes, evals, paths: paths.append(path), site_free })
			}
		}
	}

	free_site : Tx, U32 -> Tx
	free_site = |{ cmds, next, free, routes, evals, paths, site_free }, s| {
		{ cmds, next, free, routes, evals, paths: paths.set(s.to_u64(), []) ?? paths, site_free: site_free.append(s) }
	}

	bit : U64 -> U64
	bit = |depth| 1.U64.shl_wrap(depth.to_u8_wrap())

	## All layers at or above `depth`.
	upto : U64 -> U64
	upto = |depth| Engine.bit(depth).shl_wrap(1) - 1

	## ------------------------------------------------------------------
	## Blocks: the static content of one non-each site, flattened at mount.
	empty_block : {} -> Block(ctx)
	empty_block = |_| { holes: [], handlers: [], children: [], child_reads: [], child_top: [], nodes: [], tops: [], reads: 0 }

	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, U64, Tx -> (Block(ctx), Tx)
	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, cap, tx| {
		at = if top before else 0
		match elem {
			Element(tag, attrs, kids) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(8), id), parent), at), tag))
				var $b = Engine.add_node(block, id, top)
				var $t = tx2
				for attr in attrs {
					(b2, t2) = Engine.mount_attr($b, env, attr, id, path, $t)
					$b = b2
					$t = t2
				}
				kid_sole = kids.len() == 1
				for kid in kids {
					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, cap, $t)
					$b = b3
					$t = t3
				}
				($b, $t)
			}
			Text(s) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(10), id), parent), at), s))
				(Engine.add_node(block, id, top), tx2)
			}
			TextV(v) => {
				(id, tx1) = Engine.alloc_id(tx)
				read = v.read
				s = read(env)
				tx2 = Engine.emit(Engine.count_evals(tx1, 1), |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(10), id), parent), at), s))
				b1 = Engine.add_node(block, id, top)
				(Engine.add_hole(b1, { node: id, mask: Engine.eff_mask(v), attr: "", read, last: s }), tx2)
			}
			Site(Mount(mount), _) => {
				k = block.children.len().to_u32_wrap()
				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap }, tx)
				(Engine.add_child(block, inst, reads, top), tx1)
			}
		}
	}

	mount_attr : Block(ctx), ctx, Attr(ctx), U32, List(U32), Tx -> (Block(ctx), Tx)
	mount_attr = |block, env, attr, id, path, tx| {
		match attr {
			Static(name, value) => (block, Engine.emit(tx, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c.append(9), id), name), value)))
			Dyn(name, v) => {
				read = v.read
				value = read(env)
				tx1 = Engine.emit(Engine.count_evals(tx, 1), |c| Engine.put_str(Engine.put_str(Engine.put_u32(c.append(9), id), name), value))
				(Engine.add_hole(block, { node: id, mask: Engine.eff_mask(v), attr: name, read, last: value }), tx1)
			}
			On(ev, handler) => {
				h = block.handlers.len().to_u32_wrap()
				tx1 = Engine.emit(tx, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(c.append(11), id), h), ev))
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

	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, U64, Tx -> (Block(ctx), Tx)
	mount_block = |env, elem, depth, path, parent, before, cap, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, cap, tx)

	noop : {} -> Inst(ctx)
	noop = |_| Inst(|env, msg, tx| {
		match msg {
			Fire(_, _, _, _) => (Engine.noop({}), Pending(env, 0), tx)
			_ => (Engine.noop({}), Done, tx)
		}
	})

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
				t1 = Engine.count_evals($tx, 1)
				if v == last {
					$holes = list.set($i, { node, mask: m, attr, read, last }) ?? crash "hole"
					$tx = t1
				} else {
					$tx = if attr.is_empty() {
						Engine.emit(t1, |c| Engine.put_str(Engine.put_u32(c.append(12), node), v))
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

	## Route an event down the site path; the owning block runs the handler.
	## The environment always comes back up (Pending with mask 0 if untouched).
	##
	## The three cases are separate functions and every site closure returns
	## from each case directly: a block that is passed through unchanged on one
	## path and rebuilt on another must never meet in one value, or
	## --opt=speed/size treats the captured block as borrowed and copies the
	## lists of every site below it (roc-lang/roc#12846).
	fire_target : Block(ctx), List(U32), U64 -> [Leaf, Kid, Miss]
	fire_target = |block, path, pos| {
		if pos >= path.len() {
			Leaf
		} else if (path.get(pos) ?? 0).to_u64() < block.children.len() {
			Kid
		} else {
			Miss
		}
	}

	## Run handler `h` of this block (the event's target is this block).
	fire_leaf : Block(ctx), ctx, U32, Str -> Out(ctx)
	fire_leaf = |block, env, h, payload| {
		match block.handlers.get(h.to_u64()) {
			Ok(handler) => Pending((handler.run)(env, payload), handler.mask)
			Err(_) => Pending(env, 0)
		}
	}

	## Forward the event to child `path[pos]`, which must exist.
	fire_kid : Block(ctx), ctx, List(U32), U64, U32, Str, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_kid = |block, env, path, pos, h, payload, tx| {
		k = (path.get(pos) ?? 0).to_u64()
		{ holes, handlers, children, child_reads, child_top, nodes, tops, reads } = block
		{ list, prev } = children.replace(k, Engine.noop({})) ?? crash "child"
		(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h, payload), tx)
		({ holes, handlers, children: list.set(k, next) ?? crash "child", child_reads, child_top, nodes, tops, reads }, out, tx1)
	}

	dispose_block : Block(ctx), ctx, Bool, Tx -> Tx
	dispose_block = |{ holes: _, handlers: _, children, child_reads: _, child_top, nodes, tops, reads: _ }, env, remove, tx| {
		var $tx = tx
		var $j = 0.U64
		var $ks = children
		while $j < $ks.len() {
			kid_top = child_top.get($j) ?? False
			{ list, prev } = $ks.replace($j, Engine.noop({})) ?? crash "child"
			(_, _, t1) = Engine.call(prev, env, Dispose(remove and kid_top), $tx)
			$ks = list
			$tx = t1
			$j = $j + 1
		}
		if remove {
			for id in tops {
				$tx = Engine.emit($tx, |c| Engine.put_u32(c.append(5), id))
			}
		}
		for id in nodes {
			$tx = Engine.free_id($tx, id)
		}
		$tx
	}

	## ------------------------------------------------------------------
	## Site kinds.

	## After an event below a state site: take this layer's value back from
	## the environment and refresh the block if this layer changed.
	state_settle : Block(In(ctx, s)), U64, Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)
	state_settle = |block, depth, out, tx| {
		match out {
			Done => crash "fire must hand the environment back"
			Pending(next_inner, mask) => {
				{ outer: next_outer, value: s2 } = next_inner
				own = Engine.bit(depth)
				above = mask.bitwise_and(own - 1)
				if above != 0 or mask.bitwise_and(own) == 0 {
					# An outer layer changed (it will refresh us), or the change
					# was handled below.
					(Engine.state_inst(s2, block, depth), Pending(next_outer, mask), tx)
				} else {
					(b3, t3) = Engine.refresh(block, In.{ outer: next_outer, value: s2 }, own, tx)
					(Engine.state_inst(s2, b3, depth), Pending(next_outer, 0), t3)
				}
			}
		}
	}

	## A state site: `s` is this layer's value at absolute depth `depth`.
	state_inst : s, Block(In(ctx, s)), U64 -> Inst(ctx)
	state_inst = |s0, block0, depth0| {
		held = Held({ s: s0, block: block0, depth: depth0 })
		Inst(|env, msg, tx| {
			Held({ s, block, depth }) = held
			match msg {
				Changed(mask) => {
					(b2, t2) = Engine.refresh(block, In.{ outer: env, value: s }, mask, tx)
					(Engine.state_inst(s, b2, depth), Done, t2)
				}
				Fire(path, pos, h, payload) => {
					# `s` moves into the environment here and is never used again on
					# this path, so a reducer below sees it uniquely owned.
					match Engine.fire_target(block, path, pos) {
						Leaf => Engine.state_settle(block, depth, Engine.fire_leaf(block, In.{ outer: env, value: s }, h, payload), tx)
						Kid => {
							(b2, out, t2) = Engine.fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
							Engine.state_settle(b2, depth, out, t2)
						}
						Miss => Engine.state_settle(block, depth, Pending(In.{ outer: env, value: s }, 0), tx)
					}
				}
				Dispose(remove) => {
					t2 = Engine.dispose_block(block, In.{ outer: env, value: s }, remove, tx)
					(Engine.noop({}), Done, t2)
				}
			}
		})
	}

	## A conditional site. The branch is rebuilt when the condition changes.
	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64 }

	when_inst : When(ctx), Bool, Block(ctx) -> Inst(ctx)
	when_inst = |w0, cur0, block0| {
		held = Held({ w: w0, cur: cur0, block: block0 })
		Inst(|env, msg, tx| {
			Held({ w, cur, block }) = held
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
							(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, w.cap, t2)
							(Engine.when_inst(w, c, b3), Done, t3)
						}
					} else {
						(b2, t2) = Engine.refresh(block, env, mask, tx)
						(Engine.when_inst(w, cur, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match Engine.fire_target(block, path, pos) {
						Leaf => {
							out = Engine.fire_leaf(block, env, h, payload)
							(Engine.when_inst(w, cur, block), out, tx)
						}
						Kid => {
							(b2, out, t2) = Engine.fire_kid(block, env, path, pos, h, payload, tx)
							(Engine.when_inst(w, cur, b2), out, t2)
						}
						Miss => (Engine.when_inst(w, cur, block), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					t1 = Engine.dispose_block(block, env, remove, tx)
					t2 = if remove Engine.emit(t1, |c| Engine.put_u32(c.append(5), w.anchor)) else t1
					(Engine.noop({}), Done, Engine.free_id(t2, w.anchor))
				}
			}
		})
	}

	## A plain block site (the root).
	block_inst : Block(ctx) -> Inst(ctx)
	block_inst = |block0| {
		held = Held({ block: block0 })
		Inst(|env, msg, tx| {
			Held({ block }) = held
			match msg {
				Changed(mask) => {
					(b2, t2) = Engine.refresh(block, env, mask, tx)
					(Engine.block_inst(b2), Done, t2)
				}
				Fire(path, pos, h, payload) => {
					match Engine.fire_target(block, path, pos) {
						Leaf => {
							out = Engine.fire_leaf(block, env, h, payload)
							(Engine.block_inst(block), out, tx)
						}
						Kid => {
							(b2, out, t2) = Engine.fire_kid(block, env, path, pos, h, payload, tx)
							(Engine.block_inst(b2), out, t2)
						}
						Miss => (Engine.block_inst(block), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => (Engine.noop({}), Done, Engine.dispose_block(block, env, remove, tx))
			}
		})
	}

	## ------------------------------------------------------------------
	## Key index: open addressing Str key -> slot (linear probing, backward
	## shift delete). `hs` holds the key hash, `vals` slot + 1 (0 = empty);
	## keys are compared against the site's key column. Load factor <= 1/2.
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

	## Insert a fresh key (the key column must already hold it at `slot`).
	## A duplicate key is a contract error, never an alias.
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
	## Row templates, compiled once per each site.
	##
	## Template encoding: node := 1 tag:str nattr:u8 (name:str value:str)*
	## nchild:u8 node* | 2 text:str; then nholes:u8, each hole := kind:u8
	## depth:u8 path:u8* [attr: name:str | click: handler:u8].
	## Hole kinds: 1 text, 2 attr, 3 click, 4 bind (placeholder for a nested
	## site). `col` is the value column for text/attr holes whose value can
	## change (none for row-constant holes), the handler index for clicks and
	## the mount index for binds.
	RHole(ctx) : { kind : U8, mask : U64, smask : U64, skey : (ctx -> Str), read : (ctx -> Str), col : U64, live : Bool }

	Plan(ctx) : {
		tree : List(U8),
		htab : List(U8),
		holes : List(RHole(ctx)),
		handlers : List(Handler(ctx)),
		mounts : List(Mount(ctx)),
		ncols : U64,
		kreads : U64,
	}

	plan_empty : {} -> Plan(ctx)
	plan_empty = |_| { tree: [], htab: [], holes: [], handlers: [], mounts: [], ncols: 0, kreads: 0 }

	put_path : List(U8), U8, List(U8) -> List(U8)
	put_path = |buf, kind, path| buf.append(kind).append(path.len().to_u8_wrap()).concat(path)

	val_hole : Plan(ctx), U8, Val(ctx, Str), List(U8) -> Plan(ctx)
	val_hole = |{ tree, htab, holes, handlers, mounts, ncols, kreads }, kind, v, extra| {
		{ mask, read, sel } = v
		(smask, skey) = match sel {
			NoSel => (0, |_| "")
			Sel(m, k) => (m, k)
		}
		live = mask.bitwise_or(smask) != 0
		hole = { kind, mask, smask, skey, read, col: if live ncols else 0, live }
		{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if live ncols + 1 else ncols, kreads }
	}

	compile_elem : Plan(ctx), Elem(ctx), List(U8), U64 -> Plan(ctx)
	compile_elem = |plan, elem, path, depth| {
		match elem {
			Element(tag, attrs, kids) => {
				var $nstatic = 0.U64
				for a0 in attrs {
					match a0 {
						Static(_, _) => {
							$nstatic = $nstatic + 1
						}
						_ => {}
					}
				}
				nstatic = $nstatic
				var $p = plan
				{ tree, htab, holes, handlers, mounts, ncols, kreads } = $p
				var $tree = Engine.put_str(tree.append(1), tag).append(nstatic.to_u8_wrap())
				var $htab = htab
				var $holes = holes
				var $handlers = handlers
				var $ncols = ncols
				for a in attrs {
					match a {
						Static(name, value) => {
							$tree = Engine.put_str(Engine.put_str($tree, name), value)
						}
						Dyn(name, v) => {
							r = Engine.val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, 2, v, Engine.put_str(Engine.put_path([], 2, path), name))
							$htab = $htab.concat(r.htab)
							$holes = r.holes
							$ncols = r.ncols
						}
						On(ev, handler) => {
							$htab = Engine.put_str(Engine.put_path($htab, 3, path).append($handlers.len().to_u8_wrap()), ev)
							$holes = $holes.append({ kind: 3, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: $handlers.len(), live: False })
							$handlers = $handlers.append(handler)
						}
					}
				}
				$tree = $tree.append(kids.len().to_u8_wrap())
				$p = { tree: $tree, htab: $htab, holes: $holes, handlers: $handlers, mounts, ncols: $ncols, kreads }
				var $i = 0.U8
				for kid in kids {
					$p = Engine.compile_elem($p, kid, path.append($i), depth)
					$i = $i + 1
				}
				$p
			}
			Text(s) => {
				{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
				{ tree: Engine.put_str(tree.append(2), s), htab, holes, handlers, mounts, ncols, kreads }
			}
			TextV(v) => {
				{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
				t2 = Engine.put_str(tree.append(2), "")
				Engine.val_hole({ tree: t2, htab, holes, handlers, mounts, ncols, kreads }, 1, v, Engine.put_path([], 1, path))
			}
			Site(m, rf) => {
				{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
				hole = { kind: 4, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: mounts.len(), live: False }
				{ tree: Engine.put_str(tree.append(2), ""), htab: Engine.put_path(htab, 4, path), holes: holes.append(hole), handlers, mounts: mounts.append(m), ncols, kreads: kreads.bitwise_or(rf(depth)) }
			}
		}
	}

	compile : Elem(ctx), U64 -> Plan(ctx)
	compile = |elem, depth| {
		match elem {
			Element(_, _, _) => Engine.compile_elem(Engine.plan_empty({}), elem, [], depth)
			_ => crash "an each row template must be a single element"
		}
	}

	template_bytes : Plan(ctx) -> List(U8)
	template_bytes = |plan| plan.tree.append(plan.holes.len().to_u8_wrap()).concat(plan.htab)

	## ------------------------------------------------------------------
	## The each site.

	## Fixed per site.
	EachCfg(r, item) : {
		site : U32,
		parent : U32,
		anchor : U32,
		sole : Bool,
		depth : U64,
		path : List(U32),
		key : (item -> Str),
		plan : Plan(r),
		dynamic : Bool,
		outer_mask : U64,
		sel_mask : U64,
	}

	## Typed row columns, indexed by slot (except `order`, by position, and
	## `sels`, by hole).
	Cols(r, item) : {
		items : List(item),
		keys : List(Str),
		order : List(U32),
		free : List(U32),
		index : KeyIndex,
		lasts : List(List(Str)),
		kids : List(List(Inst(r))),
		binds : List(List(U32)),
		pend : List(U64),
		dirty : List(U32),
		sels : List(Str),
		known : Bool,
		kid_mask : U64,
	}

	cols_empty : U64, U64 -> Cols(r, item)
	cols_empty = |ncols, nholes| {
		items: [],
		keys: [],
		order: [],
		free: [],
		index: Engine.index_empty,
		lasts: List.repeat([], ncols),
		kids: [],
		binds: [],
		pend: [],
		dirty: [],
		sels: List.repeat("", nholes),
		known: False,
		kid_mask: 0,
	}

	row_node : U32, U32 -> U32
	row_node = |site, slot| site.shl_wrap(20) + slot + 1

	put_at : List(a), U64, a -> List(a)
	put_at = |list, i, v| if i == list.len() list.append(v) else (list.set(i, v) ?? crash "column")

	## Create one row at slot (fresh or reused), emit INST before `before`,
	## mount its nested sites. Returns the slot.
	create_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), item, U32, Tx -> (Cols(r, item), U32, Tx)
		where [item.is_eq : item, item -> Bool]
	create_row = |cfg, cols, env, item, before, tx| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
		key = (cfg.key)(item)
		(slot, free2) = match free.last() {
			Ok(s) => (s, free.drop_last(1))
			Err(_) => (items.len().to_u32_wrap(), free)
		}
		si = slot.to_u64()
		keys2 = Engine.put_at(keys, si, key)
		index2 = Engine.index_insert(index, keys2, key, slot)
		items2 = Engine.put_at(items, si, item)
		pend2 = Engine.put_at(pend, si, 0)
		node = Engine.row_node(cfg.site, slot)
		row_env = env(key, item)
		{ cmds, next, free: idfree, routes, evals, paths, site_free } = tx
		var $c = Engine.put_u32(Engine.put_u32(Engine.put_u32(Engine.put_u32(cmds.append(1), node), cfg.parent), before), cfg.site)
		var $lasts = lasts
		var $sels = sels
		var $ev = 0.U64
		var $t = { cmds: [], next, free: idfree, routes, evals, paths, site_free }
		var $bound = []
		var $hi = 0.U64
		for hole in cfg.plan.holes {
			if hole.kind == 1 or hole.kind == 2 {
				v = (hole.read)(row_env)
				$ev = $ev + 1
				$c = Engine.put_str($c, v)
				if hole.live {
					{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
					$lasts = list.set(hole.col, Engine.put_at(prev, si, v)) ?? crash "lasts"
				}
				if hole.smask != 0 and !known {
					$sels = $sels.set($hi, (hole.skey)(row_env)) ?? $sels
				}
			} else if hole.kind == 4 {
				(bid, t2) = Engine.alloc_id($t)
				$t = t2
				$c = Engine.put_u32($c, bid)
				$bound = $bound.append(bid)
			}
			$hi = $hi + 1
		}
		known2 = known or cfg.sel_mask != 0
		{ cmds: _, next: n3, free: f3, routes: r3, evals: e3, paths: p3, site_free: sf3 } = $t
		var $tx = { cmds: $c, next: n3, free: f3, routes: r3, evals: e3 + $ev, paths: p3, site_free: sf3 }
		if cfg.dynamic {
			var $insts = []
			var $km = kid_mask
			var $j = 0.U64
			for m in cfg.plan.mounts {
				mount = match m {
					Mount(f) => f
				}
				bid = $bound.get($j) ?? crash "bind"
				(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False, cap: cfg.plan.kreads.bitwise_or(Engine.upto(cfg.depth).bitwise_not()) }, $tx)
				$insts = $insts.append(inst)
				$km = $km.bitwise_or(reads)
				$tx = t4
				$j = $j + 1
			}
			cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids: Engine.put_at(kids, si, $insts), binds: Engine.put_at(binds, si, $bound), pend: pend2, dirty, sels: $sels, known: known2, kid_mask: $km }
			(cols2, slot, $tx)
		} else {
			cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids, binds, pend: pend2, dirty, sels: $sels, known: known2, kid_mask }
			(cols2, slot, $tx)
		}
	}

	## Release one row's storage and nested sites. `remove` emits REMOVE.
	drop_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), U32, Bool, Tx -> (Cols(r, item), Tx)
	drop_row = |cfg, cols, env, slot, remove, tx| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
		si = slot.to_u64()
		key = keys.get(si) ?? crash "key"
		index2 = Engine.index_remove(index, slot, key)
		pend2 = pend.set(si, 0) ?? pend
		t1 = if remove Engine.emit(tx, |c| Engine.put_u32(c.append(5), Engine.row_node(cfg.site, slot))) else tx
		if cfg.dynamic {
			{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
			{ list: bl, prev: row_binds } = binds.replace(si, []) ?? crash "binds"
			item = items.get(si) ?? crash "item"
			row_env = env(key, item)
			var $t = t1
			var $rk = row_kids
			var $j = 0.U64
			while $j < $rk.len() {
				{ list: rl, prev: kid } = $rk.replace($j, Engine.noop({})) ?? crash "kid"
				(_, _, t2) = Engine.call(kid, row_env, Dispose(False), $t)
				$rk = rl
				$t = t2
				$j = $j + 1
			}
			for b in row_binds {
				$t = Engine.free_id($t, b)
			}
			({ items, keys, order, free: free.append(slot), index: index2, lasts, kids: kl, binds: bl, pend: pend2, dirty, sels, known, kid_mask }, $t)
		} else {
			({ items, keys, order, free: free.append(slot), index: index2, lasts, kids, binds, pend: pend2, dirty, sels, known, kid_mask }, t1)
		}
	}

	mark_all : Cols(r, item), U64 -> Cols(r, item)
	mark_all = |cols, m| {
		(c0, order) = Engine.take_order(cols)
		var $c = c0
		for s in order {
			$c = Engine.mark($c, s, m)
		}
		Engine.set_order($c, order)
	}

	mark : Cols(r, item), U32, U64 -> Cols(r, item)
	mark = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }, slot, m| {
		si = slot.to_u64()
		p = pend.get(si) ?? 0
		dirty2 = if p == 0 dirty.append(slot) else dirty
		{ items, keys, order, free, index, lasts, kids, binds, pend: pend.set(si, p.bitwise_or(m)) ?? pend, dirty: dirty2, sels, known, kid_mask }
	}

	## A kept row whose new item may differ: equal items are pruned here.
	keep_row : Cols(r, item), U32, item, U64 -> Cols(r, item)
		where [item.is_eq : item, item -> Bool]
	keep_row = |cols, slot, item, row_bit| {
		si = slot.to_u64()
		same = match cols.items.get(si) {
			Ok(old) => old == item
			Err(_) => crash "item"
		}
		if same {
			cols
		} else {
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
			Engine.mark({ items: items.set(si, item) ?? crash "item", keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }, slot, row_bit)
		}
	}

	set_order : Cols(r, item), List(U32) -> Cols(r, item)
	set_order = |{ items, keys, order: _, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }, order| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }
	}

	take_order : Cols(r, item) -> (Cols(r, item), List(U32))
	take_order = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }| {
		({ items, keys, order: [], free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask }, order)
	}

	end_ref : EachCfg(r, item) -> U32
	end_ref = |cfg| if cfg.sole 0 else cfg.anchor

	## The node a row inserted at position `pos` (of `order`) goes before.
	ref_at : EachCfg(r, item), List(U32), U64 -> U32
	ref_at = |cfg, order, pos| match order.get(pos) {
		Ok(s) => Engine.row_node(cfg.site, s)
		Err(_) => Engine.end_ref(cfg)
	}

	key_of_slot : Cols(r, item), U32 -> Str
	key_of_slot = |cols, slot| cols.keys.get(slot.to_u64()) ?? crash "key"

	same_row : EachCfg(r, item), Cols(r, item), U32, item -> Bool
		where [item.is_eq : item, item -> Bool]
	same_row = |cfg, cols, slot, item| {
		match cols.items.get(slot.to_u64()) {
			Ok(old) => if old == item True else Engine.key_of_slot(cols, slot) == (cfg.key)(item)
			Err(_) => crash "item"
		}
	}

	## Remove every row.
	clear_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), Bool, Tx -> (Cols(r, item), Tx)
	clear_rows = |cfg, cols, env, dom, tx| {
		var $tx = tx
		if !dom {
			{}
		} else if cfg.sole {
			$tx = Engine.emit($tx, |c| Engine.put_u32(Engine.put_u32(c.append(6), cfg.parent), cfg.site))
		} else {
			for slot in cols.order {
				$tx = Engine.emit($tx, |c| Engine.put_u32(c.append(5), Engine.row_node(cfg.site, slot)))
			}
		}
		if cfg.dynamic {
			var $i = 0.U64
			while $i < cols.kids.len() {
				live = match cols.items.get($i) {
					Ok(item) => {
						key = cols.keys.get($i) ?? ""
						match Engine.index_find(cols.index, cols.keys, key, Engine.hash_str(key)) {
							Ok(s) => if s.to_u64() == $i Ok(item) else Err(Dead)
							Err(_) => Err(Dead)
						}
					}
					Err(_) => Err(Dead)
				}
				match live {
					Ok(item) => {
						key = cols.keys.get($i) ?? ""
						row_env = env(key, item)
						var $rk = cols.kids.get($i) ?? []
						var $j = 0.U64
						while $j < $rk.len() {
							{ list: rl, prev: kid } = $rk.replace($j, Engine.noop({})) ?? crash "kid"
							(_, _, t2) = Engine.call(kid, row_env, Dispose(False), $tx)
							$rk = rl
							$tx = t2
							$j = $j + 1
						}
						for b in cols.binds.get($i) ?? [] {
							$tx = Engine.free_id($tx, b)
						}
					}
					Err(Dead) => {}
				}
				$i = $i + 1
			}
		}
		{ sels, known, kid_mask, lasts, items: _, keys: _, order: _, free: _, index: _, kids: _, binds: _, pend: _, dirty: _ } = cols
		ncols = lasts.len()
		({ items: [], keys: [], order: [], free: [], index: Engine.index_empty, lasts: List.repeat([], ncols), kids: [], binds: [], pend: [], dirty: [], sels, known, kid_mask }, $tx)
	}

	## Append rows new_list[from..] at the end of the site.
	append_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), U64, Tx -> (Cols(r, item), Tx)
		where [item.is_eq : item, item -> Bool]
	append_rows = |cfg, cols, env, list, from, tx| {
		var $cols = cols
		var $tx = tx
		var $i = from
		before = Engine.end_ref(cfg)
		while $i < list.len() {
			item = list.get($i) ?? crash "row"
			(c2, slot, t2) = Engine.create_row(cfg, $cols, env, item, before, $tx)
			(c3, order) = Engine.take_order(c2)
			$cols = Engine.set_order(c3, order.append(slot))
			$tx = t2
			$i = $i + 1
		}
		($cols, $tx)
	}

	## Keyed reconciliation of the site's rows against `list`. Fast paths:
	## common prefix and suffix, swapped ends, pure insertion and pure
	## removal; anything else falls back to a keyed move with an LIS.
	reconcile : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
		where [item.is_eq : item, item -> Bool]
	reconcile = |cfg, cols, env, list, tx| {
		n_old = cols.order.len()
		n_new = list.len()
		row_bit = Engine.bit(cfg.depth)
		if n_new == 0 {
			if n_old == 0 (cols, tx) else Engine.clear_rows(cfg, cols, env, True, tx)
		} else if n_old == 0 {
			Engine.append_rows(cfg, cols, env, list, 0, tx)
		} else {
			var $cols = cols
			var $tx = tx
			var $i = 0.U64
			var $oe = n_old
			var $ne = n_new
			var $go = True
			while $go {
				# common prefix
				var $p = True
				while $p and $i < $oe and $i < $ne {
					slot = $cols.order.get($i) ?? crash "order"
					item = list.get($i) ?? crash "row"
					if Engine.same_row(cfg, $cols, slot, item) {
						$cols = Engine.keep_row($cols, slot, item, row_bit)
						$i = $i + 1
					} else {
						$p = False
					}
				}
				# common suffix
				var $q = True
				while $q and $i < $oe and $i < $ne {
					slot = $cols.order.get($oe - 1) ?? crash "order"
					item = list.get($ne - 1) ?? crash "row"
					if Engine.same_row(cfg, $cols, slot, item) {
						$cols = Engine.keep_row($cols, slot, item, row_bit)
						$oe = $oe - 1
						$ne = $ne - 1
					} else {
						$q = False
					}
				}
				# swapped ends
				$go = False
				if $oe - $i >= 2 and $ne - $i >= 2 and $i < $oe and $i < $ne {
					a = $cols.order.get($i) ?? crash "order"
					b = $cols.order.get($oe - 1) ?? crash "order"
					first = list.get($i) ?? crash "row"
					last = list.get($ne - 1) ?? crash "row"
					if Engine.same_row(cfg, $cols, b, first) and Engine.same_row(cfg, $cols, a, last) {
						na = Engine.row_node(cfg.site, a)
						nb = Engine.row_node(cfg.site, b)
						after = Engine.ref_at(cfg, $cols.order, $oe)
						$tx = Engine.emit($tx, |c| Engine.put_u32(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(4), nb), na).append(4), na), after))
						$cols = Engine.keep_row(Engine.keep_row($cols, b, first, row_bit), a, last, row_bit)
						(c2, order) = Engine.take_order($cols)
						$cols = Engine.set_order(c2, order.swap($i, $oe - 1) ?? crash "order")
						$i = $i + 1
						$oe = $oe - 1
						$ne = $ne - 1
						$go = True
					}
				}
			}
			if $i == $oe and $i == $ne {
				($cols, $tx)
			} else if $i == $oe {
				# pure insertion of list[i..ne) before position oe
				if $oe == $cols.order.len() {
					Engine.append_rows(cfg, $cols, env, list, $i, $tx)
				} else {
					before = Engine.ref_at(cfg, $cols.order, $oe)
					var $new_slots = []
					var $k = $i
					while $k < $ne {
						item = list.get($k) ?? crash "row"
						(c2, slot, t2) = Engine.create_row(cfg, $cols, env, item, before, $tx)
						$cols = c2
						$tx = t2
						$new_slots = $new_slots.append(slot)
						$k = $k + 1
					}
					(c3, order) = Engine.take_order($cols)
					merged = order.sublist({ start: 0, len: $i }).concat($new_slots).concat(order.sublist({ start: $oe, len: order.len() - $oe }))
					(Engine.set_order(c3, merged), $tx)
				}
			} else if $i == $ne {
				# pure removal of order[i..oe)
				var $k = $i
				while $k < $oe {
					slot = $cols.order.get($k) ?? crash "order"
					(c2, t2) = Engine.drop_row(cfg, $cols, env, slot, True, $tx)
					$cols = c2
					$tx = t2
					$k = $k + 1
				}
				(c3, order) = Engine.take_order($cols)
				kept = if $oe - $i == 1 order.drop_at($i) else order.sublist({ start: 0, len: $i }).concat(order.sublist({ start: $oe, len: order.len() - $oe }))
				(Engine.set_order(c3, kept), $tx)
			} else {
				Engine.reconcile_general(cfg, $cols, env, list, $i, $oe, $ne, $tx)
			}
		}
	}

	## General keyed reconciliation of the middle ranges old order[i..oe) and
	## new list[i..ne). Allocates scratch proportional to the site.
	reconcile_general : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), U64, U64, U64, Tx -> (Cols(r, item), Tx)
		where [item.is_eq : item, item -> Bool]
	reconcile_general = |cfg, cols, env, list, i, oe, ne, tx| {
		row_bit = Engine.bit(cfg.depth)
		nslots = cols.items.len()
		# old position of every slot in the old middle (+1; 0 = not in middle)
		var $oldpos = List.repeat(0.U64, nslots)
		var $k = i
		while $k < oe {
			s = cols.order.get($k) ?? crash "order"
			$oldpos = $oldpos.set(s.to_u64(), $k + 1) ?? crash "pos"
			$k = $k + 1
		}
		# match new middle keys to existing slots
		var $found = []
		var $seen = List.repeat(False, nslots)
		$k = i
		while $k < ne {
			item = list.get($k) ?? crash "row"
			key = (cfg.key)(item)
			r = match Engine.index_find(cols.index, cols.keys, key, Engine.hash_str(key)) {
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
		# drop old middle rows that are gone
		var $cols = cols
		var $tx = tx
		$k = i
		while $k < oe {
			s = cols.order.get($k) ?? crash "order"
			if !($seen.get(s.to_u64()) ?? False) {
				(c2, t2) = Engine.drop_row(cfg, $cols, env, s, True, $tx)
				$cols = c2
				$tx = t2
			}
			$k = $k + 1
		}
		# longest increasing subsequence of old positions among kept rows
		var $seq = []
		for f in $found {
			$seq = $seq.append(if f == 0 0 else $oldpos.get(f - 1) ?? 0)
		}
		stable = Engine.lis_mark($seq)
		# place from the end
		var $slots = List.repeat(0.U32, ne - i)
		var $ref = Engine.ref_at(cfg, $cols.order, oe)
		var $p = ne
		while $p > i {
			$p = $p - 1
			idx = $p - i
			item = list.get($p) ?? crash "row"
			f = $found.get(idx) ?? 0
			if f == 0 {
				(c2, slot, t2) = Engine.create_row(cfg, $cols, env, item, $ref, $tx)
				$cols = c2
				$tx = t2
				$slots = $slots.set(idx, slot) ?? $slots
				$ref = Engine.row_node(cfg.site, slot)
			} else {
				slot = (f - 1).to_u32_wrap()
				node = Engine.row_node(cfg.site, slot)
				if !(stable.get(idx) ?? False) {
					r = $ref
					$tx = Engine.emit($tx, |c| Engine.put_u32(Engine.put_u32(c.append(4), node), r))
				}
				$cols = Engine.keep_row($cols, slot, item, row_bit)
				$slots = $slots.set(idx, slot) ?? $slots
				$ref = node
			}
		}
		(c3, order) = Engine.take_order($cols)
		merged = order.sublist({ start: 0, len: i }).concat($slots).concat(order.sublist({ start: oe, len: order.len() - oe }))
		(Engine.set_order(c3, merged), $tx)
	}

	## Mark the members of one longest strictly increasing subsequence of the
	## nonzero entries of `seq` (zeros are new rows and never stable).
	lis_mark : List(U64) -> List(Bool)
	lis_mark = |seq| {
		n = seq.len()
		var $tails = []
		var $prev = List.repeat(0.U64, n)
		var $i = 0.U64
		while $i < n {
			v = seq.get($i) ?? 0
			if v != 0 {
				# binary search the first tail whose value >= v
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

	## Evaluate the marked holes of the dirty rows and forward changes to
	## their nested sites.
	settle : EachCfg(r, item), Cols(r, item), (Str, item -> r), Tx -> (Cols(r, item), Tx)
	settle = |cfg, cols, env, tx| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
		var $lasts = lasts
		var $pend = pend
		var $kids = kids
		var $tx = tx
		for slot in dirty {
			si = slot.to_u64()
			m = $pend.get(si) ?? 0
			$pend = $pend.set(si, 0) ?? $pend
			key = keys.get(si) ?? crash "key"
			item = items.get(si) ?? crash "item"
			row_env = env(key, item)
			node = Engine.row_node(cfg.site, slot)
			var $hi = 0.U64
			for hole in cfg.plan.holes {
				if hole.live and hole.mask.bitwise_or(hole.smask).bitwise_and(m) != 0 {
					v = (hole.read)(row_env)
					{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
					old = prev.get(si) ?? ""
					$tx = Engine.count_evals($tx, 1)
					if v == old {
						$lasts = list.set(hole.col, prev) ?? crash "lasts"
					} else {
						op = if hole.kind == 1 2 else 3
						hidx = $hi.to_u8_wrap()
						$tx = Engine.emit($tx, |c| Engine.put_str(Engine.put_u32(c.append(op), node).append(hidx), v))
						$lasts = list.set(hole.col, prev.set(si, v) ?? crash "lasts") ?? crash "lasts"
					}
				}
				$hi = $hi + 1
			}
			if cfg.dynamic and kid_mask.bitwise_and(m) != 0 {
				{ list: kl, prev: row_kids } = $kids.replace(si, []) ?? crash "kids"
				var $rk = row_kids
				var $j = 0.U64
				while $j < $rk.len() {
					{ list: rl, prev: kid } = $rk.replace($j, Engine.noop({})) ?? crash "kid"
					(k2, _, t2) = Engine.call(kid, row_env, Changed(m), $tx)
					$rk = rl.set($j, k2) ?? crash "kid"
					$tx = t2
					$j = $j + 1
				}
				$kids = kl.set(si, $rk) ?? crash "kids"
			}
		}
		({ items, keys, order, free, index, lasts: $lasts, kids: $kids, binds, pend: $pend, dirty: dirty.clear(), sels, known, kid_mask }, $tx)
	}

	## Selection changed: mark only the previously and newly selected rows.
	select_changed : EachCfg(r, item), Cols(r, item), (Str, item -> r), U64 -> Cols(r, item)
	select_changed = |cfg, cols, env, mask| {
		first = cols.order.first()
		match first {
			Err(_) => {
				{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask } = cols
				{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: False, kid_mask }
			}
			Ok(s0) => {
				key0 = cols.keys.get(s0.to_u64()) ?? crash "key"
				item0 = cols.items.get(s0.to_u64()) ?? crash "item"
				probe = env(key0, item0)
				var $cols = cols
				var $hi = 0.U64
				for hole in cfg.plan.holes {
					if hole.smask.bitwise_and(mask) != 0 {
						nk = (hole.skey)(probe)
						ok = $cols.sels.get($hi) ?? ""
						if !$cols.known or nk != ok {
							if $cols.known {
								match Engine.index_find($cols.index, $cols.keys, ok, Engine.hash_str(ok)) {
									Ok(s) => {
										$cols = Engine.mark($cols, s, hole.smask)
									}
									Err(_) => {}
								}
							} else {
								# Unknown previous selection: every row may be stale.
								$cols = Engine.mark_all($cols, hole.smask)
							}
							match Engine.index_find($cols.index, $cols.keys, nk, Engine.hash_str(nk)) {
								Ok(s) => {
									$cols = Engine.mark($cols, s, hole.smask)
								}
								Err(_) => {}
							}
							{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask } = $cols
							$cols = { items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels: sels.set($hi, nk) ?? sels, known: True, kid_mask }
						}
					}
					$hi = $hi + 1
				}
				$cols
			}
		}
	}

	is_live : Cols(r, item), U64 -> Bool
	is_live = |cols, si| {
		match cols.keys.get(si) {
			Ok(key) => {
				match Engine.index_find(cols.index, cols.keys, key, Engine.hash_str(key)) {
					Ok(s) => s.to_u64() == si
					Err(_) => False
				}
			}
			Err(_) => False
		}
	}

	## Route an event into nested site `path[pos + 1]` of row slot `si`.
	## Takes the columns owned and hands back only the outer environment, so
	## nothing that references the columns or the row item is alive when the
	## site is rebuilt (roc-lang/roc#12846 class).
	each_fire_kid : Cols(Row(ctx, item), item), Row(ctx, item), U64, List(U32), U64, U32, Str, Tx -> (Cols(Row(ctx, item), item), ctx, U64, Tx)
	each_fire_kid = |cols, row_env, si, path, pos, h, payload, tx| {
		j = (path.get(pos + 1) ?? 0).to_u64()
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
		{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
		if j < row_kids.len() {
			{ list: rl, prev: kid } = row_kids.replace(j, Engine.noop({})) ?? crash "kid"
			(k2, out, t2) = Engine.call(kid, row_env, Fire(path, pos + 2, h, payload), tx)
			kids2 = kl.set(si, rl.set(j, k2) ?? crash "kid") ?? crash "kids"
			(outer, m) = Engine.row_out(out)
			({ items, keys, order, free, index, lasts, kids: kids2, binds, pend, dirty, sels, known, kid_mask }, outer, m, t2)
		} else {
			{ outer, key: _, item: _ } = row_env
			({ items, keys, order, free, index, lasts, kids: kl.set(si, row_kids) ?? crash "kids", binds, pend, dirty, sels, known, kid_mask }, outer, 0, tx)
		}
	}

	row_out : Out(Row(ctx, item)) -> (ctx, U64)
	row_out = |out| match out {
		Pending(e2, m) => {
			{ outer, key: _, item: _ } = e2
			(outer, m)
		}
		Done => crash "fire must hand the environment back"
	}

	each_inst : EachCfg(Row(ctx, item), item), Val(ctx, List(item)), Cols(Row(ctx, item), item) -> Inst(ctx)
		where [item.is_eq : item, item -> Bool]
	each_inst = |cfg0, rows0, cols0| {
		held = Held({ cfg: cfg0, rows: rows0, cols: cols0 })
		Inst(|env, msg, tx| {
			Held({ cfg, rows, cols }) = held
			mk = |k, it| Row.{ outer: env, key: k, item: it }
			match msg {
				Changed(mask) => {
					# Mark existing rows first (outer layers, then the keyed selector),
					# then reconcile: rows created now are evaluated once, at creation;
					# rows removed now drop their marks.
					full = mask.bitwise_and(cfg.outer_mask.bitwise_or(cols.kid_mask)).bitwise_and(Engine.bit(cfg.depth) - 1)
					c1 = if full != 0 Engine.mark_all(cols, full) else cols
					c2 = if cfg.sel_mask.bitwise_and(mask) != 0 Engine.select_changed(cfg, c1, mk, mask) else c1
					rows_mask = Engine.eff_mask(rows)
					(c3, t1) = if rows_mask.bitwise_and(mask) != 0 {
						list = (rows.read)(env)
						Engine.reconcile(cfg, c2, mk, list, Engine.count_evals(tx, 1))
					} else {
						(c2, tx)
					}
					(c4, t4) = Engine.settle(cfg, c3, mk, t1)
					(Engine.each_inst(cfg, rows, c4), Done, t4)
				}
				Fire(path, pos, h, payload) => {
					slot = path.get(pos) ?? crash "row path"
					si = slot.to_u64()
					if !Engine.is_live(cols, si) {
						(Engine.each_inst(cfg, rows, cols), Pending(env, 0), tx)
					} else {
						key = cols.keys.get(si) ?? crash "key"
						item = cols.items.get(si) ?? crash "item"
						row_env = Row.{ outer: env, key, item }
						if pos + 1 >= path.len() {
							match cfg.plan.handlers.get(h.to_u64()) {
								Ok(handler) => {
									# Rebuild the site before running the row handler: with the
									# handler call first, --opt=speed/size treated the captured
									# columns as borrowed and every later write copied them
									# (roc-lang/roc#12846).
									next = Engine.each_inst(cfg, rows, cols)
									{ outer, key: _, item: _ } = (handler.run)(row_env, payload)
									(next, Pending(outer, handler.mask), tx)
								}
								Err(_) => {
									{ outer, key: _, item: _ } = row_env
									(Engine.each_inst(cfg, rows, cols), Pending(outer, 0), tx)
								}
							}
						} else {
							(cols2, outer, m, t2) = Engine.each_fire_kid(cols, row_env, si, path, pos, h, payload, tx)
							(Engine.each_inst(cfg, rows, cols2), Pending(outer, m), t2)
						}
					}
				}
				Dispose(remove) => {
					t1 = if remove or cfg.dynamic {
						(_, t) = Engine.clear_rows(cfg, cols, mk, remove, tx)
						t
					} else {
						tx
					}
					t2 = if !cfg.sole { if remove Engine.free_id(Engine.emit(t1, |c| Engine.put_u32(c.append(5), cfg.anchor)), cfg.anchor) else Engine.free_id(t1, cfg.anchor) } else t1
					(Engine.noop({}), Done, Engine.free_site(t2, cfg.site))
				}
			}
		})
	}

	## ------------------------------------------------------------------
	## Static read masks: the layers an element tree can read when mounted at
	## `depth`, computed without mounting it (nested sites report their own).
	elem_reads : Elem(ctx), U64 -> U64
	elem_reads = |elem, depth| match elem {
		Element(_, attrs, kids) => {
			var $m = 0.U64
			for a in attrs {
				match a {
					Dyn(_, v) => {
						$m = $m.bitwise_or(Engine.eff_mask(v))
					}
					_ => {}
				}
			}
			for k in kids {
				$m = $m.bitwise_or(Engine.elem_reads(k, depth))
			}
			$m
		}
		Text(_) => 0
		TextV(v) => Engine.eff_mask(v)
		Site(_, rf) => rf(depth)
	}

	state_handle : U64 -> State(In(ctx, s), s)
	state_handle = |depth| {
		mask: Engine.bit(depth),
		get: |e| e.value,
		modify: |e, f| {
			{ outer, value } = e
			In.{ outer, value: f(value) }
		},
	}

	## ------------------------------------------------------------------
	## Application-facing constructors.

	## A state per instance of the current context (per row inside a row).
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Site(
		Mount(|env, args, tx| {
			depth = args.depth + 1
			elem = body(Engine.state_handle(depth))
			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, args.cap, tx)
			reads = block.reads
			(Engine.state_inst(init, block, depth), reads, tx1)
		}),
		|d| Engine.elem_reads(body(Engine.state_handle(d + 1)), d + 1).bitwise_and(Engine.bit(d + 1) - 1),
	)

	## A keyed list. The template runs once per site; rows are typed columns.
	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Site(Mount(|env, args, tx| {
		depth = args.depth + 1
		row_bit = Engine.bit(depth)
		plan = Engine.compile(template(RowRef.{ depth }), depth)
		(site, tx1) = Engine.alloc_site(tx, args.path)
		tpl = Engine.template_bytes(plan)
		tx2 = Engine.emit(tx1, |c| Engine.put_u32(Engine.put_u32(c.append(7), site), tpl.len().to_u32_wrap()).concat(tpl))
		(anchor, tx3) = if args.sole {
			(0, tx2)
		} else {
			(a, t) = Engine.alloc_id(tx2)
			before = args.before
			(a, Engine.emit(t, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(10), a), args.parent), before), "")))
		}
		var $om = 0.U64
		var $sm = 0.U64
		for h in plan.holes {
			$om = $om.bitwise_or(h.mask)
			$sm = $sm.bitwise_or(h.smask)
		}
		outer_mask = $om.bitwise_and(row_bit - 1)
		smask_all = $sm
		dynamic = !plan.mounts.is_empty()
		cfg = { site, parent: args.parent, anchor, sole: args.sole, depth, path: args.path, key, plan, dynamic, outer_mask, sel_mask: smask_all }
		ncols = plan.ncols
		nholes = plan.holes.len()
		list = (rows.read)(env)
		(cols, tx4) = Engine.append_rows(cfg, Engine.cols_empty(ncols, nholes), |k, it| Row.{ outer: env, key: k, item: it }, list, 0, Engine.count_evals(tx3, 1))
		# Nested sites in the template report their static reads (kreads),
		# which also covers rows mounted later.
		reads = Engine.eff_mask(rows).bitwise_or(outer_mask).bitwise_or(smask_all).bitwise_or(plan.kreads.bitwise_and(row_bit - 1))
		(Engine.each_inst(cfg, rows, cols), reads, tx4)
	}), |d| Engine.eff_mask(rows).bitwise_or(Engine.elem_reads(template(RowRef.{ depth: d + 1 }), d + 1).bitwise_and(Engine.bit(d + 1) - 1)))

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Site(Mount(|env, args, tx| {
		(anchor, tx1) = Engine.alloc_id(tx)
		before = args.before
		tx2 = Engine.emit(tx1, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c.append(10), anchor), args.parent), before), ""))
		c = (cond.read)(env)
		elem = if c yes() else no()
		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, args.cap, Engine.count_evals(tx2, 1))
		# Listen to the condition, this branch, and what the other branch
		# would read once mounted (or the cap, when the parent knows it).
		reads = if args.cap != 0 {
			args.cap
		} else {
			other = if c no() else yes()
			Engine.eff_mask(cond).bitwise_or(block.reads).bitwise_or(Engine.elem_reads(other, args.depth))
		}
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap }
		(Engine.when_inst(w, c, block), reads, tx3)
	}), |d| Engine.eff_mask(cond).bitwise_or(Engine.elem_reads(yes(), d)).bitwise_or(Engine.elem_reads(no(), d)))

	## ------------------------------------------------------------------
	## Memoised shared derivation. `derive(input, body)` evaluates `input`
	## once per change of the layers it reads and exposes the result as a new
	## layer: readers inside `body` see it with this layer's own bit, and an
	## equal recomputation stops propagation (readers that read only the
	## derived value do no work). Outer values used inside `body` need `.lift()`.
	derive : Val(ctx, a), (Val(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Site(Mount(|env, args, tx| {
		depth = args.depth + 1
		v = (input.read)(env)
		elem = body({ mask: Engine.bit(depth), read: |e| e.value, sel: NoSel })
		(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, args.cap, Engine.count_evals(tx, 1))
		reads = block.reads.bitwise_and(Engine.bit(depth) - 1).bitwise_or(Engine.eff_mask(input))
		(Engine.derive_inst(input, v, block, depth), reads, tx1)
	}), |d| Engine.eff_mask(input).bitwise_or(Engine.elem_reads(body({ mask: Engine.bit(d + 1), read: |e| e.value, sel: NoSel }), d + 1).bitwise_and(Engine.bit(d + 1) - 1)))

	derive_inst : Val(ctx, a), a, Block(In(ctx, a)), U64 -> Inst(ctx)
		where [a.is_eq : a, a -> Bool]
	derive_inst = |input0, v0, block0, depth0| {
		held = Held({ input: input0, v: v0, block: block0, depth: depth0 })
		Inst(|env, msg, tx| {
			Held({ input, v, block, depth }) = held
			match msg {
				Changed(mask) => {
					if Engine.eff_mask(input).bitwise_and(mask) != 0 {
						v2 = (input.read)(env)
						t1 = Engine.count_evals(tx, 1)
						if v2 == v {
							(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, t1)
							(Engine.derive_inst(input, v, b2, depth), Done, t2)
						} else {
							(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v2 }, mask.bitwise_or(Engine.bit(depth)), t1)
							(Engine.derive_inst(input, v2, b2, depth), Done, t2)
						}
					} else {
						(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, tx)
						(Engine.derive_inst(input, v, b2, depth), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match Engine.fire_target(block, path, pos) {
						Leaf => Engine.derive_settle(input, block, depth, Engine.fire_leaf(block, In.{ outer: env, value: v }, h, payload), tx)
						Kid => {
							(b2, out, t2) = Engine.fire_kid(block, In.{ outer: env, value: v }, path, pos, h, payload, tx)
							Engine.derive_settle(input, b2, depth, out, t2)
						}
						Miss => (Engine.derive_inst(input, v, block, depth), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					t2 = Engine.dispose_block(block, In.{ outer: env, value: v }, remove, tx)
					(Engine.noop({}), Done, t2)
				}
			}
		})
	}

	## A derived layer has no write handle, so an event below it can only have
	## changed an outer layer (which will refresh this site) or nothing.
	derive_settle : Val(ctx, a), Block(In(ctx, a)), U64, Out(In(ctx, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
		where [a.is_eq : a, a -> Bool]
	derive_settle = |input, block, depth, out, tx| {
		match out {
			Done => crash "fire must hand the environment back"
			Pending(next_inner, mask) => {
				{ outer, value } = next_inner
				(Engine.derive_inst(input, value, block, depth), Pending(outer, mask), tx)
			}
		}
	}

	## ------------------------------------------------------------------
	## Component boundary with a fixed environment (after p2size/r2dnb),
	## generalised: any prop type `p` and an outward action type `a`.
	##
	## The body is typed over `Comp(p, a)` only, never over the caller's
	## context, so it is specialised once per (p, a), not per call site.
	## Inside, the prop is layer 0. The body also gets a write handle on the
	## component's outward action list (`out.push(...)`, mask 0: writing it
	## refreshes nothing inside). When an event inside the component settles,
	## the boundary hands each pushed action to the caller's `Sink`, which
	## turns it into an update of an outer state.
	##
	## The boundary does not retain the prop: it re-reads it from the caller's
	## environment when an outer layer it reads changes, and when an event
	## enters. Retaining it (for equality pruning at the boundary) would hold a
	## second reference to whatever the prop projects out of an outer state
	## (typically a list), and every reducer on that state would then copy it.
	## Pruning happens at the holes and rows inside instead.
	Comp(p, a) := { prop : p, out : List(a) }

	## Where a component's actions go: the reducer also reports the layer it
	## changed.
	Sink(ctx, a) : { run : (ctx, a -> (ctx, U64)) }

	sink : State(ctx, s), (s, a -> s) -> Sink(ctx, a)
	sink = |st, f| {
		{ mask, get: _, modify } = st
		{ run: |e, a| (modify(e, |s| f(s, a)), mask) }
	}

	## Route each action to one of two sinks.
	split : Sink(ctx, a), Sink(ctx, b), (c -> [L(a), R(b)]) -> Sink(ctx, c)
	split = |l, r, route| {
		lr = l.run
		rr = r.run
		{
			run: |e, c| match route(c) {
				L(a) => lr(e, a)
				R(b) => rr(e, b)
			},
		}
	}

	component : Val(ctx, p), Sink(ctx, a), (Val(Comp(p, a), p), State(Comp(p, a), List(a)) -> Elem(Comp(p, a))) -> Elem(ctx)
	component = |prop, snk, body| Site(Mount(|env, args, tx| {
		v = (prop.read)(env)
		out_handle = {
			mask: 0,
			get: |e| e.out,
			modify: |e, f| {
				{ prop: pv, out } = e
				Comp.{ prop: pv, out: f(out) }
			},
		}
		elem = body({ mask: 1, read: |e| e.prop, sel: NoSel }, out_handle)
		(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, 0, Engine.count_evals(tx, 1))
		(Engine.comp_inst(prop, snk, block), Engine.eff_mask(prop), tx1)
	}), |_| Engine.eff_mask(prop))

	comp_inst : Val(ctx, p), Sink(ctx, a), Block(Comp(p, a)) -> Inst(ctx)
	comp_inst = |prop0, snk0, block0| {
		held = Held({ prop: prop0, snk: snk0, block: block0 })
		Inst(|env, msg, tx| {
			Held({ prop, snk, block }) = held
			match msg {
				Changed(mask) => {
					if Engine.eff_mask(prop).bitwise_and(mask) == 0 {
						(Engine.comp_inst(prop, snk, block), Done, tx)
					} else {
						v = (prop.read)(env)
						(b2, t2) = Engine.refresh(block, Comp.{ prop: v, out: [] }, 1, Engine.count_evals(tx, 1))
						(Engine.comp_inst(prop, snk, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match Engine.fire_target(block, path, pos) {
						Leaf => {
							inner = Comp.{ prop: (prop.read)(env), out: [] }
							Engine.comp_settle(prop, snk, block, env, Engine.fire_leaf(block, inner, h, payload), Engine.count_evals(tx, 1))
						}
						Kid => {
							inner = Comp.{ prop: (prop.read)(env), out: [] }
							(b2, out, t2) = Engine.fire_kid(block, inner, path, pos, h, payload, Engine.count_evals(tx, 1))
							Engine.comp_settle(prop, snk, b2, env, out, t2)
						}
						Miss => (Engine.comp_inst(prop, snk, block), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					t2 = Engine.dispose_block(block, Comp.{ prop: (prop.read)(env), out: [] }, remove, tx)
					(Engine.noop({}), Done, t2)
				}
			}
		})
	}

	## Take the pushed actions out of a settled component environment. A
	## function of its own so the inner environment (and the prop it holds, a
	## reference into an outer state) is dropped before any sink reducer runs.
	comp_actions : Out(Comp(p, a)) -> List(a)
	comp_actions = |out| match out {
		Done => crash "fire must hand the environment back"
		Pending(inner, _) => {
			{ prop: _, out: actions } = inner
			actions
		}
	}

	comp_settle : Val(ctx, p), Sink(ctx, a), Block(Comp(p, a)), ctx, Out(Comp(p, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
	comp_settle = |prop, snk, block, env, out, tx| {
		actions = Engine.comp_actions(out)
		match actions {
			_ => {
				if actions.is_empty() {
					(Engine.comp_inst(prop, snk, block), Pending(env, 0), tx)
				} else {
					run = snk.run
					var $e = env
					var $m = 0.U64
					for a in actions {
						(e2, m2) = run($e, a)
						$e = e2
						$m = $m.bitwise_or(m2)
					}
					(Engine.comp_inst(prop, snk, block), Pending($e, $m), tx)
				}
			}
		}
	}

	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value, sel: NoSel }

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Element(tag, attrs, kids)

	text : Str -> Elem(ctx)
	text = |s| Text(s)

	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| TextV(v)

	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Static(name, value)

	attr_v : Str, Val(ctx, Str) -> Attr(ctx)
	attr_v = |name, v| Dyn(name, v)

	class : Str -> Attr(ctx)
	class = |c| Static("class", c)

	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| Dyn("class", v)

	test_id : Str -> Attr(ctx)
	test_id = |v| Static("data-testid", v)

	test_id_v : Val(ctx, Str) -> Attr(ctx)
	test_id_v = |v| Dyn("data-testid", v)

	on : Str, Handler(ctx) -> Attr(ctx)
	on = |ev, h| On(ev, h)

	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| On("click", h)

	## ------------------------------------------------------------------
	## The engine state the host holds in one Box.
	App := { root : Inst(Root), tx : Tx }

	new_tx : List(U8) -> Tx
	new_tx = |cmds| { cmds, next: 1, free: [], routes: [], evals: 0, paths: [[]], site_free: [] }

	## Mount the application under host node 0.
	mount : Elem(Root) -> App
	mount = |elem| {
		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, 0, Engine.new_tx([]))
		{ root: Engine.block_inst(block), tx }
	}

	## Deliver an event on host node `node`: a static node (routes table) or a
	## row node (site path + slot, handler number from the template hole).
	## `payload` is the event's value ("" for clicks).
	event : App, U32, U32, Str -> App
	event = |{ root, tx }, node, handler, payload| {
		site = node.shr_zf_wrap(20)
		target = if site == 0 {
			match tx.routes.get(node.to_u64()) ?? NoRoute {
				NoRoute => Err(Stale)
				Route(path, h) => Ok((path, h))
			}
		} else {
			match tx.paths.get(site.to_u64()) {
				Ok(path) => if path.is_empty() Err(Stale) else Ok((path.append(node.bitwise_and(1048575) - 1), handler))
				Err(_) => Err(Stale)
			}
		}
		match target {
			Err(Stale) => { root, tx }
			Ok((path, h)) => {
				(root2, _, tx2) = Engine.call(root, Root, Fire(path, 0, h, payload), tx)
				{ root: root2, tx: tx2 }
			}
		}
	}

	## Hand the accumulated commands to the host and take a buffer back.
	take_cmds : App, List(U8) -> (App, List(U8))
	take_cmds = |{ root, tx }, buf| {
		{ cmds, next, free, routes, evals, paths, site_free } = tx
		({ root, tx: { cmds: buf.clear(), next, free, routes, evals, paths, site_free } }, cmds)
	}

	evals : App -> U64
	evals = |a| a.tx.evals

	## The host-facing program: mount once, then one transaction per event.
	Program(state) : {
		init : () -> (state, List(U8)),
		event : state, List(U8), U32, U32, List(U8) -> (state, List(U8)),
	}

	program : (() -> Elem(Root)) -> Program(App)
	program = |view| {
		init: || Engine.take_cmds(Engine.mount(view()), []),
		event: |inst, buf, node, handler, payload| {
			{ root, tx } = inst
			{ cmds: _, next, free, routes, evals: ev, paths, site_free } = tx
			fresh = { root, tx: { cmds: buf.clear(), next, free, routes, evals: ev, paths, site_free } }
			Engine.take_cmds(Engine.event(fresh, node, handler, Str.from_utf8(payload) ?? ""), [])
		},
	}
}
