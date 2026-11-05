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
## Node ids: one dense u32 space for every element (rows included), recycled
## through a free list; the routes table maps each to a block path or to a
## row's (site, slot). Each sites are dense u32 ids (template ids), recycled.
## Limits are memory, not bit widths (2^32 - 2 live nodes; fx_node reserved).
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

		## An effect site's reaction: a reducer over this state given the value
		## the request was issued for and its result.
		on_result : State(ctx, s), (s, a, Res -> s) -> Reaction(ctx, a)
		on_result = |{ mask, get: _, modify }, f| { mask, run: |e, a, r| modify(e, |s| f(s, a, r)) }

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
			{ mask: 0, read: |e| if (selected(e.outer) == e.key) yes else no, sel: Sel(mask, |e| selected(e.outer)) }
		}
	}

	## `Ref(name)`: a scoped focus reference (effects Focus/Blur/SelectText
	## name it; engine ids are never exposed to the app).
	Attr(ctx) := [Static(Str, Str), Dyn(Str, Val(ctx, Str)), On(Str, Handler(ctx)), Ref(Str)]

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
	## `local`: the site is inside an each row or a component, where the
	## root's Changed pass cannot reach its layers by mask.
	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64, local : Bool }

	Scope : { cap : U64, local : Bool }

	Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

	## An event's payload: a DOM event's value, or an effect result.
	Payload : [Ev(Str), Fx(Res)]

	ev_str : Payload -> Str
	ev_str = |p| match p {
		Ev(s) => s
		Fx(_) => ""
	}

	Msg := [Fire(List(U32), U64, U32, Payload), Changed(U64), Dispose(Bool)]

	## Fire always hands the (possibly transformed) environment back up with
	## the mask of the layer it changed (0 = nothing changed).
	Out(ctx) := [Done, Pending(ctx, U64), Orphaned(List(Orphan(ctx)))]

	## An admitted request whose issuing site was disposed (design.md,
	## "Requests, effects, and cancellation"): it survives and reparents to the
	## nearest surviving ancestor site. `run` applies its reaction in that
	## ancestor's current environment: writes to states that were retired
	## with the disposed scope land in a snapshot that is discarded (the third
	## component counts them), writes to surviving states commit, and the
	## mask reports only surviving layers.
	Orphan(ctx) : { id : U32, run : (ctx, Res -> (ctx, U64, U64)) }

	orphans_of : Out(ctx) -> List(Orphan(ctx))
	orphans_of = |out| match out {
		Orphaned(l) => l
		_ => []
	}

	Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

	## A node's route: a static node's block path, or a row element's site
	## and slot (resolved through the site's current path).
	Route := [NoRoute, Route(List(U32), U32), RowOf(U32, U32)]

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
		work : Work,
		paths : List(List(U32)),
		site_free : List(U32),
		fx : Fx,
	}

	## Work counters (design.md, "Work assertions"): one `Work` record in the
	## transaction accumulator, cumulative over the instance. Indices 1-18
	## count the commands emitted, by opcode (`INST` is a row created, `MOVE`
	## a row moved); the named indices below count engine work.
	w_set_value : U64
	w_set_value = 19

	w_set_checked : U64
	w_set_checked = 20

	w_evals : U64
	w_evals = 21

	w_rows_removed : U64
	w_rows_removed = 22

	w_rows_reused : U64
	w_rows_reused = 23

	w_rows_updated : U64
	w_rows_updated = 24

	w_scopes_created : U64
	w_scopes_created = 25

	w_scopes_disposed : U64
	w_scopes_disposed = 26

	w_dirty_roots : U64
	w_dirty_roots = 27

	w_key_hashes : U64
	w_key_hashes = 28

	w_key_compares : U64
	w_key_compares = 29

	w_turns : U64
	w_turns = 30

	w_cleanups : U64
	w_cleanups = 31

	## The number of work counters (index 0 is unused).
	w_count : U64
	w_count = 32

	## The work counters as plain fields (`c01` is counter 1): bumping one
	## updates a value in the accumulator and never allocates, so counting
	## cannot cost an allocation or a copy on any path.
	Work : { c01 : U64, c02 : U64, c03 : U64, c04 : U64, c05 : U64, c06 : U64, c07 : U64, c08 : U64, c09 : U64, c10 : U64, c11 : U64, c12 : U64, c13 : U64, c14 : U64, c15 : U64, c16 : U64, c17 : U64, c18 : U64, c19 : U64, c20 : U64, c21 : U64, c22 : U64, c23 : U64, c24 : U64, c25 : U64, c26 : U64, c27 : U64, c28 : U64, c29 : U64, c30 : U64, c31 : U64 }

	work_zero : Work
	work_zero = { c01: 0, c02: 0, c03: 0, c04: 0, c05: 0, c06: 0, c07: 0, c08: 0, c09: 0, c10: 0, c11: 0, c12: 0, c13: 0, c14: 0, c15: 0, c16: 0, c17: 0, c18: 0, c19: 0, c20: 0, c21: 0, c22: 0, c23: 0, c24: 0, c25: 0, c26: 0, c27: 0, c28: 0, c29: 0, c30: 0, c31: 0 }

	## Add `n` to counter `i`; counter 0 (and any index past the last) is the
	## unused sink.
	add_work : Work, U64, U64 -> Work
	add_work = |w, i, n| match i {
		1 => { ..w, c01: w.c01 + n }
		2 => { ..w, c02: w.c02 + n }
		3 => { ..w, c03: w.c03 + n }
		4 => { ..w, c04: w.c04 + n }
		5 => { ..w, c05: w.c05 + n }
		6 => { ..w, c06: w.c06 + n }
		7 => { ..w, c07: w.c07 + n }
		8 => { ..w, c08: w.c08 + n }
		9 => { ..w, c09: w.c09 + n }
		10 => { ..w, c10: w.c10 + n }
		11 => { ..w, c11: w.c11 + n }
		12 => { ..w, c12: w.c12 + n }
		13 => { ..w, c13: w.c13 + n }
		14 => { ..w, c14: w.c14 + n }
		15 => { ..w, c15: w.c15 + n }
		16 => { ..w, c16: w.c16 + n }
		17 => { ..w, c17: w.c17 + n }
		18 => { ..w, c18: w.c18 + n }
		19 => { ..w, c19: w.c19 + n }
		20 => { ..w, c20: w.c20 + n }
		21 => { ..w, c21: w.c21 + n }
		22 => { ..w, c22: w.c22 + n }
		23 => { ..w, c23: w.c23 + n }
		24 => { ..w, c24: w.c24 + n }
		25 => { ..w, c25: w.c25 + n }
		26 => { ..w, c26: w.c26 + n }
		27 => { ..w, c27: w.c27 + n }
		28 => { ..w, c28: w.c28 + n }
		29 => { ..w, c29: w.c29 + n }
		30 => { ..w, c30: w.c30 + n }
		31 => { ..w, c31: w.c31 + n }
		_ => w
	}

	## Counter `i` (0 for the unused index 0).
	work_get : Work, U64 -> U64
	work_get = |w, i| match i {
		1 => w.c01
		2 => w.c02
		3 => w.c03
		4 => w.c04
		5 => w.c05
		6 => w.c06
		7 => w.c07
		8 => w.c08
		9 => w.c09
		10 => w.c10
		11 => w.c11
		12 => w.c12
		13 => w.c13
		14 => w.c14
		15 => w.c15
		16 => w.c16
		17 => w.c17
		18 => w.c18
		19 => w.c19
		20 => w.c20
		21 => w.c21
		22 => w.c22
		23 => w.c23
		24 => w.c24
		25 => w.c25
		26 => w.c26
		27 => w.c27
		28 => w.c28
		29 => w.c29
		30 => w.c30
		31 => w.c31
		_ => 0
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

	## Append one command: its opcode, then the operands `write` adds. The
	## opcode is counted in the work counters (design.md, "Work assertions").
	emit_op : Tx, U8, (List(U8) -> List(U8)) -> Tx
	emit_op = |{ cmds, next, free, routes, work, paths, site_free, fx }, op, write| { cmds: write(cmds.append(op)), next, free, routes, work: Engine.add_work(work, op.to_u64(), 1), paths, site_free, fx }

	## Add `n` to work counter `i`.
	bump : Tx, U64, U64 -> Tx
	bump = |{ cmds, next, free, routes, work, paths, site_free, fx }, i, n| { cmds, next, free, routes, work: Engine.add_work(work, i, n), paths, site_free, fx }

	## One evaluation of an app closure (a hole, a condition, a list read, a
	## `derive` input, a prop read, an effect site's watched value).
	count_evals : Tx, U64 -> Tx
	count_evals = |tx, n| Engine.bump(tx, Engine.w_evals, n)

	## An attribute command (`ATTR` or `HATTR`) that sets a control's live
	## state is also counted by name.
	count_attr : Tx, Str -> Tx
	count_attr = |tx, name| Engine.bump(tx, Engine.ctl_of(name), 1)

	## The work counter an attribute name counts in besides its opcode: 0
	## (the unused counter, so the accumulator is always rebuilt the same
	## way, roc-lang/roc#12846) when it names no control state.
	ctl_of : Str -> U64
	ctl_of = |name| if (name == "value") Engine.w_set_value else if (name == "checked") Engine.w_set_checked else 0

	## Allocate a static node id, reusing a freed one first.
	alloc_id : Tx -> (U32, Tx)
	alloc_id = |{ cmds, next, free, routes, work, paths, site_free, fx }| {
		match free.last() {
			Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, work, paths, site_free, fx })
			Err(_) => {
				if next >= 4294967294 {
					crash "resource_limit: node ids exhausted (4294967294 live nodes)"
				}
				(next, { cmds, next: next + 1, free, routes, work, paths, site_free, fx })
			}
		}
	}

	## Release a static node id and its route.
	free_id : Tx, U32 -> Tx
	free_id = |{ cmds, next, free, routes, work, paths, site_free, fx }, id| {
		routes2 = if (id.to_u64() < routes.len()) routes.set(id.to_u64(), NoRoute) ?? routes else routes
		fx2 = if ((fx.ref_pos.get(id.to_u64()) ?? 0) == 0) fx else Engine.drop_ref(fx, id)
		{ cmds, next, free: free.append(id), routes: routes2, work, paths, site_free, fx: fx2 }
	}

	## Name `node` as focus reference `name`; a reference of the same name
	## on another live node moves here (the later mount wins).
	add_ref : Fx, Str, U32 -> Fx
	add_ref = |fx, name, node| Engine.with_refs(
		fx,
		|refs, ref_pos| {
			var $at = ref_pos
			while $at.len() <= node.to_u64() {
				$at = $at.append(0)
			}
			match refs.find_first_index(|(n, _)| n == name) {
				Ok(i) => {
					(_, old) = refs.get(i) ?? crash "internal: ref"
					at2 = $at.set(old.to_u64(), 0) ?? crash "internal: ref"
					(refs.set(i, (name, node)) ?? crash "internal: ref", at2.set(node.to_u64(), (i + 1).to_u32_wrap()) ?? crash "internal: ref")
				}
				Err(_) => {
					n = refs.len() + 1
					(refs.append((name, node)), $at.set(node.to_u64(), n.to_u32_wrap()) ?? crash "internal: ref")
				}
			}
		},
	)

	## Forget the reference `node` carries: swap-remove it from `refs` and
	## re-point the entry that moved.
	drop_ref : Fx, U32 -> Fx
	drop_ref = |fx, node| Engine.with_refs(
		fx,
		|refs, ref_pos| {
			pos = (ref_pos.get(node.to_u64()) ?? 0).to_u64()
			last = refs.len()
			at1 = ref_pos.set(node.to_u64(), 0) ?? crash "internal: ref"
			if pos == last {
				(refs.drop_last(1), at1)
			} else {
				(lname, lnode) = refs.get(last - 1) ?? crash "internal: ref"
				refs2 = (refs.set(pos - 1, (lname, lnode)) ?? crash "internal: ref").drop_last(1)
				(refs2, at1.set(lnode.to_u64(), pos.to_u32_wrap()) ?? crash "internal: ref")
			}
		},
	)

	## Update the reference table with both lists moved out of `fx`, so
	## they stay uniquely owned and update in place.
	with_refs : Fx, (List((Str, U32)), List(U32) -> (List((Str, U32)), List(U32))) -> Fx
	with_refs = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }, f| {
		(refs2, at2) = f(refs, ref_pos)
		{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs: refs2, focus, ref_pos: at2, cleanups }
	}

	set_route : Tx, U32, List(U32), U32 -> Tx
	set_route = |{ cmds, next, free, routes, work, paths, site_free, fx }, id, path, handler| {
		var $r = routes
		while $r.len() <= id.to_u64() {
			$r = $r.append(NoRoute)
		}
		{ cmds, next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, work, paths, site_free, fx }
	}

	set_row_route : Tx, U32, U32, U32 -> Tx
	set_row_route = |{ cmds, next, free, routes, work, paths, site_free, fx }, id, site, slot| {
		var $r = routes
		while $r.len() <= id.to_u64() {
			$r = $r.append(NoRoute)
		}
		{ cmds, next, free, routes: $r.set(id.to_u64(), RowOf(site, slot)) ?? $r, work, paths, site_free, fx }
	}

	## Allocate an each-site id (template id).
	alloc_site : Tx, List(U32) -> (U32, Tx)
	alloc_site = |{ cmds, next, free, routes, work, paths, site_free, fx }, path| {
		match site_free.last() {
			Ok(s) => (s, { cmds, next, free, routes, work, paths: paths.set(s.to_u64(), path) ?? crash "site", site_free: site_free.drop_last(1), fx })
			Err(_) => {
				s = paths.len().to_u32_wrap()
				(s, { cmds, next, free, routes, work, paths: paths.append(path), site_free, fx })
			}
		}
	}

	free_site : Tx, U32 -> Tx
	free_site = |{ cmds, next, free, routes, work, paths, site_free, fx }, s| {
		{ cmds, next, free, routes, work, paths: paths.set(s.to_u64(), []) ?? paths, site_free: site_free.append(s), fx }
	}

	## The deepest layer a mask can name: a component body nests at most 63
	## layers below its prop (design.md, "Contexts and layers").
	max_depth : U64
	max_depth = 63

	## A layer's bit in a read mask. Every layer is created through `layer`,
	## which refuses a depth beyond `max_depth`, so this never wraps.
	bit : U64 -> U64
	bit = |depth| (1.U64).shl_wrap(depth.to_u8_wrap())

	## The depth of a new layer below `depth`, at construction site `path`.
	## Nesting deeper than `max_depth` is a resource limit, never a wrap.
	layer : U64, List(U32) -> U64
	layer = |depth, path| {
		if depth >= Engine.max_depth {
			crash "resource_limit: more than ${Engine.max_depth.to_str()} nested state, derive or each layers in one component at site ${Engine.show_path(path)}"
		}
		depth + 1
	}

	## The read-mask depth of a layer below `depth` (static reads, computed
	## before mounting; the mount reports the same limit with its path).
	layer_reads : U64 -> U64
	layer_reads = |depth| {
		if depth >= Engine.max_depth {
			crash "resource_limit: more than ${Engine.max_depth.to_str()} nested state, derive or each layers in one component"
		}
		depth + 1
	}

	## All layers at or above `depth`.
	upto : U64 -> U64
	upto = |depth| if (depth >= 63) 0xFFFF_FFFF_FFFF_FFFF else Engine.bit(depth).shl_wrap(1) - 1

	## ------------------------------------------------------------------
	## Blocks: the static content of one non-each site, flattened at mount.
	empty_block : {} -> Block(ctx)
	empty_block = |_| { holes: [], handlers: [], children: [], child_reads: [], child_top: [], nodes: [], tops: [], reads: 0 }

	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, Scope, Tx -> (Block(ctx), Tx)
	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, scope, tx| {
		at = if (top) before else 0
		match elem {
			Element(tag, attrs, kids) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit_op(tx1, 8, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, id), parent), at), tag))
				var $b = Engine.add_node(block, id, top)
				var $t = tx2
				for attr in attrs {
					(b2, t2) = Engine.mount_attr($b, env, attr, id, path, $t)
					$b = b2
					$t = t2
				}
				kid_sole = kids.len() == 1
				for kid in kids {
					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, scope, $t)
					$b = b3
					$t = t3
				}
				($b, $t)
			}
			Text(s) => {
				(id, tx1) = Engine.alloc_id(tx)
				tx2 = Engine.emit_op(tx1, 10, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, id), parent), at), s))
				(Engine.add_node(block, id, top), tx2)
			}
			TextV(v) => {
				(id, tx1) = Engine.alloc_id(tx)
				read = v.read
				s = read(env)
				tx2 = Engine.emit_op(Engine.count_evals(tx1, 1), 10, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, id), parent), at), s))
				b1 = Engine.add_node(block, id, top)
				(Engine.add_hole(b1, { node: id, mask: Engine.eff_mask(v), attr: "", read, last: s }), tx2)
			}
			Site(Mount(mount), _) => {
				k = block.children.len().to_u32_wrap()
				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap: scope.cap, local: scope.local }, tx)
				(Engine.add_child(block, inst, reads, top), tx1)
			}
		}
	}

	mount_attr : Block(ctx), ctx, Attr(ctx), U32, List(U32), Tx -> (Block(ctx), Tx)
	mount_attr = |block, env, attr, id, path, tx| {
		match attr {
			Static(name, value) => (block, Engine.emit_op(Engine.count_attr(tx, name), 9, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c, id), name), value)))
			Dyn(name, v) => {
				read = v.read
				value = read(env)
				tx1 = Engine.emit_op(Engine.count_attr(Engine.count_evals(tx, 1), name), 9, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c, id), name), value))
				(Engine.add_hole(block, { node: id, mask: Engine.eff_mask(v), attr: name, read, last: value }), tx1)
			}
			On(ev, handler) => {
				h = block.handlers.len().to_u32_wrap()
				tx1 = Engine.emit_op(tx, 11, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(c, id), h), ev))
				(Engine.add_handler(block, handler), Engine.set_route(tx1, id, path, h))
			}
			Ref(name) => (block, Engine.with_fx(tx, |fx| Engine.add_ref(fx, name, id)))
		}
	}

	add_node : Block(ctx), U32, Bool -> Block(ctx)
	add_node = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, id, top| {
		{ holes, handlers, children, child_reads, child_top, nodes: nodes.append(id), tops: if (top) tops.append(id) else tops, reads }
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

	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Scope, Tx -> (Block(ctx), Tx)
	mount_block = |env, elem, depth, path, parent, before, scope, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, scope, tx)

	noop : {} -> Inst(ctx)
	noop = |_| Inst(
		|env, msg, tx| {
			match msg {
				Fire(_, _, _, _) => (Engine.noop({}), Pending(env, 0), tx)
				_ => (Engine.noop({}), Done, tx)
			}
		},
	)

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
						Engine.emit_op(t1, 12, |c| Engine.put_str(Engine.put_u32(c, node), v))
					} else {
						Engine.emit_op(Engine.count_attr(t1, attr), 9, |c| Engine.put_str(Engine.put_str(Engine.put_u32(c, node), attr), v))
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
	fire_leaf : Block(ctx), ctx, U32, Payload -> Out(ctx)
	fire_leaf = |block, env, h, payload| {
		match block.handlers.get(h.to_u64()) {
			Ok(handler) => Pending((handler.run)(env, Engine.ev_str(payload)), handler.mask)
			Err(_) => Pending(env, 0)
		}
	}

	## Forward the event to child `path[pos]`, which must exist.
	fire_kid : Block(ctx), ctx, List(U32), U64, U32, Payload, Tx -> (Block(ctx), Out(ctx), Tx)
	fire_kid = |block, env, path, pos, h, payload, tx| {
		k = (path.get(pos) ?? 0).to_u64()
		{ holes, handlers, children, child_reads, child_top, nodes, tops, reads } = block
		{ list, prev } = children.replace(k, Engine.noop({})) ?? crash "child"
		(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h, payload), tx)
		({ holes, handlers, children: list.set(k, next) ?? crash "child", child_reads, child_top, nodes, tops, reads }, out, tx1)
	}

	## Dispose a block's children (and its nodes); returns the orphans its
	## nested sites left, typed by this block's environment.
	dispose_block : Block(ctx), ctx, Bool, Tx -> (List(Orphan(ctx)), Tx)
	dispose_block = |{ holes: _, handlers: _, children, child_reads: _, child_top, nodes, tops, reads: _ }, env, remove, tx| {
		var $tx = tx
		var $j = 0.U64
		var $ks = children
		var $orph = []
		while $j < $ks.len() {
			kid_top = child_top.get($j) ?? False
			{ list, prev } = $ks.replace($j, Engine.noop({})) ?? crash "child"
			(_, out, t1) = Engine.call(prev, env, Dispose(remove and kid_top), $tx)
			$orph = $orph.concat(Engine.orphans_of(out))
			$ks = list
			$tx = t1
			$j = $j + 1
		}
		if remove {
			for id in tops {
				$tx = Engine.emit_op($tx, 5, |c| Engine.put_u32(c, id))
			}
		}
		for id in nodes {
			$tx = Engine.free_id($tx, id)
		}
		($orph, $tx)
	}

	## ------------------------------------------------------------------
	## Site kinds.

	## After an event below a state site: take this layer's value back from
	## the environment and refresh the block if this layer changed.
	state_settle : Block(In(ctx, s)), U64, Bool, Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)
	state_settle = |block, depth, local, out, tx| {
		match out {
			Done => crash "internal: fire must hand the environment back"
			Orphaned(_) => crash "internal: fire must hand the environment back"
			Pending(next_inner, mask) => {
				{ outer: next_outer, value: s2 } = next_inner
				own = Engine.bit(depth)
				above = mask.bitwise_and(own - 1)
				if !local or above != 0 or mask.bitwise_and(own) == 0 {
					# Hand the change up: the root (or the outer layer that
					# changed) runs the Changed pass once the event has unwound.
					(Engine.state_inst(s2, block, depth, local), Pending(next_outer, mask), tx)
				} else {
					(b3, t3) = Engine.refresh(block, In.{ outer: next_outer, value: s2 }, own, Engine.bump(tx, Engine.w_dirty_roots, 1))
					(Engine.state_inst(s2, b3, depth, local), Pending(next_outer, 0), t3)
				}
			}
		}
	}

	## A state site: `s` is this layer's value at absolute depth `depth`.
	state_inst : s, Block(In(ctx, s)), U64, Bool -> Inst(ctx)
	state_inst = |s0, block0, depth0, local0| {
		held = Held({ s: s0, block: block0, depth: depth0, local: local0 })
		Inst(
			|env, msg, tx| {
				Held({ s, block, depth, local }) = held
				match msg {
					Changed(mask) => {
						(b2, t2) = Engine.refresh(block, In.{ outer: env, value: s }, mask, tx)
						(Engine.state_inst(s, b2, depth, local), Done, t2)
					}
					Fire(path, pos, h, payload) => {
						# `s` moves into the environment here and is never used again on
						# this path, so a reducer below sees it uniquely owned.
						match Engine.fire_target(block, path, pos) {
							Leaf => Engine.state_settle(block, depth, local, Engine.fire_leaf(block, In.{ outer: env, value: s }, h, payload), tx)
							Kid => {
								(b2, out, t2) = Engine.fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
								Engine.state_settle(b2, depth, local, out, t2)
							}
							Miss => Engine.state_settle(block, depth, local, Pending(In.{ outer: env, value: s }, 0), tx)
						}
					}
					Dispose(remove) => {
						(orph, t2) = Engine.dispose_block(block, In.{ outer: env, value: s }, remove, tx)
						(Engine.noop({}), Orphaned(Engine.lower_in(orph, s, depth)), t2)
					}
				}
			},
		)
	}

	## A conditional site. The branch is rebuilt when the condition changes.
	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64, local : Bool }

	## `adopted`: orphans reparented to this site when a branch it disposed
	## left admitted requests behind.
	when_inst : When(ctx), Bool, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
	when_inst = |w0, cur0, adopted0, block0| {
		held = Held({ w: w0, cur: cur0, adopted: adopted0, block: block0 })
		Inst(
			|env, msg, tx| {
				Held({ w, cur, adopted, block }) = held
				match msg {
					Changed(mask) => {
						cm = Engine.eff_mask(w.cond)
						if cm.bitwise_and(mask) != 0 {
							c = (w.cond.read)(env)
							t1 = Engine.count_evals(tx, 1)
							if c == cur {
								(b2, t2) = Engine.refresh(block, env, mask, t1)
								(Engine.when_inst(w, cur, adopted, b2), Done, t2)
							} else {
								(orph, t2) = Engine.dispose_block(block, env, True, Engine.bump(Engine.bump(t1, Engine.w_scopes_disposed, 1), Engine.w_scopes_created, 1))
								elem = if (c) (w.yes)() else (w.no)()
								(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, { cap: w.cap, local: w.local }, Engine.fx_adopt(t2, w.path, orph))
								(Engine.when_inst(w, c, adopted.concat(orph), b3), Done, t3)
							}
						} else {
							(b2, t2) = Engine.refresh(block, env, mask, tx)
							(Engine.when_inst(w, cur, adopted, b2), Done, t2)
						}
					}
					Fire(path, pos, h, payload) => {
						match Engine.leaf_fx(path, pos, payload) {
							Ok(res) => {
								(ad2, out, t2) = Engine.adopt_deliver(adopted, env, h, res, tx)
								(Engine.when_inst(w, cur, ad2, block), out, t2)
							}
							Err(_) => {
								match Engine.fire_target(block, path, pos) {
									Leaf => {
										out = Engine.fire_leaf(block, env, h, payload)
										(Engine.when_inst(w, cur, adopted, block), out, tx)
									}
									Kid => {
										(b2, out, t2) = Engine.fire_kid(block, env, path, pos, h, payload, tx)
										(Engine.when_inst(w, cur, adopted, b2), out, t2)
									}
									Miss => (Engine.when_inst(w, cur, adopted, block), Pending(env, 0), tx)
								}
							}
						}
					}
					Dispose(remove) => {
						(orph, t1) = Engine.dispose_block(block, env, remove, Engine.bump(tx, Engine.w_scopes_disposed, 1))
						t2 = if (remove) Engine.emit_op(t1, 5, |c| Engine.put_u32(c, w.anchor)) else t1
						(Engine.noop({}), Orphaned(adopted.concat(orph)), Engine.free_id(t2, w.anchor))
					}
				}
			},
		)
	}

	## A plain block site (the root).
	block_inst : Block(ctx) -> Inst(ctx)
	block_inst = |block0| {
		held = Held({ block: block0 })
		Inst(
			|env, msg, tx| {
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
					Dispose(remove) => {
						(orph, t2) = Engine.dispose_block(block, env, remove, tx)
						(Engine.noop({}), Orphaned(orph), t2)
					}
				}
			},
		)
	}

	## ------------------------------------------------------------------
	## Key index: open addressing Str key -> slot (linear probing, backward
	## shift delete). `hs` holds the key hash, `vals` slot + 1 (0 = empty);
	## keys are compared against the site's key column. Load factor <= 1/2.
	## `by_slot[slot]` is the hash of the key the slot holds, so removing a
	## row never hashes its key again.
	KeyIndex : { hs : List(U64), vals : List(U32), count : U64, bits : U8, by_slot : List(U64) }

	index_empty : KeyIndex
	index_empty = { hs: [], vals: [], count: 0, bits: 0, by_slot: [] }

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
	index_find = |index, keys, key, h| Engine.index_probe(index, keys, key, h).found

	## A lookup that also reports how many stored keys it compared with the
	## probe in full (only entries whose hash matches are compared).
	index_probe : KeyIndex, List(Str), Str, U64 -> { found : Try(U32, [Missing]), compares : U64 }
	index_probe = |index, keys, key, h| {
		if index.count == 0 {
			return { found: Err(Missing), compares: 0 }
		}
		mask = ((1.U64).shl_wrap(index.bits)) - 1
		var $b = Engine.bucket(h, index.bits)
		var $n = 0.U64
		while True {
			v = index.vals.get($b) ?? 0
			if v == 0 {
				return { found: Err(Missing), compares: $n }
			}
			if (index.hs.get($b) ?? 0) == h {
				$n = $n + 1
				if (keys.get((v - 1).to_u64()) ?? "") == key {
					return { found: Ok(v - 1), compares: $n }
				}
			}
			$b = ($b + 1).bitwise_and(mask)
		}
	}

	raw_insert : List(U64), List(U32), U8, U64, U32 -> { hs : List(U64), vals : List(U32) }
	raw_insert = |hs, vals, bits, h, slot| {
		mask = ((1.U64).shl_wrap(bits)) - 1
		var $b = Engine.bucket(h, bits)
		while (vals.get($b) ?? 0) != 0 {
			$b = ($b + 1).bitwise_and(mask)
		}
		{ hs: hs.set($b, h) ?? crash "index bucket", vals: vals.set($b, slot + 1) ?? crash "index bucket" }
	}

	## The table at the next size (`by_slot` is not part of it: it stays out
	## of this branch so it is never treated as borrowed, roc-lang/roc#12846).
	Table : { hs : List(U64), vals : List(U32), count : U64, bits : U8 }

	grow : Table -> Table
	grow = |{ hs, vals, count, bits }| {
		new_bits = if (bits == 0) 4 else bits + 1
		size = (1.U64).shl_wrap(new_bits)
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

	## Insert a fresh key (the key column must already hold it at `slot`)
	## whose hash is `h`. A duplicate key is a contract error, never an
	## alias. Also returns the full-key comparisons the duplicate check made.
	index_insert : KeyIndex, List(Str), Str, U64, U32, List(U32) -> (KeyIndex, U64)
	index_insert = |index, keys, key, h, slot, path| {
		probe = Engine.index_probe(index, keys, key, h)
		match probe.found {
			Ok(_) => crash Engine.dup_key(path, key)
			Err(Missing) => {}
		}
		{ hs: hs0, vals: vals0, count: count0, bits: bits0, by_slot } = index
		table = { hs: hs0, vals: vals0, count: count0, bits: bits0 }
		grown = if ((count0 + 1) * 2 > (1.U64).shl_wrap(bits0)) Engine.grow(table) else table
		{ hs, vals, count, bits } = grown
		r = Engine.raw_insert(hs, vals, bits, h, slot)
		({ hs: r.hs, vals: r.vals, count: count + 1, bits, by_slot: Engine.put_at(by_slot, slot.to_u64(), h) }, probe.compares)
	}

	index_remove : KeyIndex, U32 -> KeyIndex
	index_remove = |{ hs, vals, count, bits, by_slot }, slot| {
		if count == 0 {
			crash "internal: remove of missing key"
		}
		mask = ((1.U64).shl_wrap(bits)) - 1
		h = by_slot.get(slot.to_u64()) ?? crash "internal: remove of missing key"
		var $b = Engine.bucket(h, bits)
		while (vals.get($b) ?? 0) != slot + 1 {
			if (vals.get($b) ?? 0) == 0 {
				crash "internal: remove of missing key"
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
		{ hs: $h, vals: $v, count: count - 1, bits, by_slot }
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
	## `ctl`: the work counter an attribute hole's updates also count in
	## (`w_set_value`, `w_set_checked`), or 0.
	RHole(ctx) : { kind : U8, mask : U64, smask : U64, skey : (ctx -> Str), read : (ctx -> Str), col : U64, live : Bool, ctl : U64 }

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
	put_path = |buf, kind, path| buf.append(kind).append(Engine.narrow(path.len(), "nesting depth of a hole")).concat(path)

	## A count the template encoding carries in one byte (design.md, Appendix
	## B). Beyond 255 it is a resource limit, never a wrap.
	narrow : U64, Str -> U8
	narrow = |n, what| if (n > 255) crash "resource_limit: a row template's ${what} is ${n.to_str()}; the template encoding allows at most 255" else n.to_u8_wrap()

	val_hole : Plan(ctx), U8, Str, Val(ctx, Str), List(U8) -> Plan(ctx)
	val_hole = |{ tree, htab, holes, handlers, mounts, ncols, kreads }, kind, name, v, extra| {
		{ mask, read, sel } = v
		(smask, skey) = match sel {
			NoSel => (0, |_| "")
			Sel(m, k) => (m, k)
		}
		live = mask.bitwise_or(smask) != 0
		hole = { kind, mask, smask, skey, read, col: if (live) ncols else 0, live, ctl: Engine.ctl_of(name) }
		{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if (live) ncols + 1 else ncols, kreads }
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
				var $tree = Engine.put_str(tree.append(1), tag).append(Engine.narrow(nstatic, "static attributes on one element"))
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
							r = Engine.val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, 2, name, v, Engine.put_str(Engine.put_path([], 2, path), name))
							$htab = $htab.concat(r.htab)
							$holes = r.holes
							$ncols = r.ncols
						}
						On(ev, handler) => {
							$htab = Engine.put_str(Engine.put_path($htab, 3, path).append(Engine.narrow($handlers.len(), "event handler count")), ev)
							$holes = $holes.append({ kind: 3, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: $handlers.len(), live: False, ctl: 0 })
							$handlers = $handlers.append(handler)
						}
						Ref(_) => crash "contract: focus refs are not supported inside each rows (use one in a nested site)"
					}
				}
				$tree = $tree.append(Engine.narrow(kids.len(), "children of one element"))
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
				Engine.val_hole({ tree: t2, htab, holes, handlers, mounts, ncols, kreads }, 1, "", v, Engine.put_path([], 1, path))
			}
			Site(m, rf) => {
				{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
				hole = { kind: 4, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: mounts.len(), live: False, ctl: 0 }
				{ tree: Engine.put_str(tree.append(2), ""), htab: Engine.put_path(htab, 4, path), holes: holes.append(hole), handlers, mounts: mounts.append(m), ncols, kreads: kreads.bitwise_or(rf(depth)) }
			}
		}
	}

	compile : Elem(ctx), U64 -> Plan(ctx)
	compile = |elem, depth| {
		match elem {
			Element(_, _, _) => Engine.compile_elem(Engine.plan_empty({}), elem, [], depth)
			_ => crash "contract: an each row template must be a single element"
		}
	}

	template_bytes : Plan(ctx) -> List(U8)
	template_bytes = |plan| plan.tree.append(Engine.narrow(plan.holes.len(), "hole count")).concat(plan.htab)

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

		## Rows dropped since the site last took them, with the orphans their
		## nested sites left (admitted requests that outlive the row).
		dropped : List({ key : Str, item : item, orphans : List(Orphan(r)) }),

		## The host node id of each slot's row element (dense node ids,
		## shared with static nodes; routes map them back to site and slot).
		rnodes : List(U32),
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
		dropped: [],
		rnodes: [],
	}

	## Construction-site path for diagnostics: child positions from the root.
	show_path : List(U32) -> Str
	show_path = |path| "/${Str.join_with(path.map(|p| p.to_str()), "/")}"

	## The diagnostic for a duplicate each key (design.md: duplicate keys are
	## errors, not aliases).
	dup_key : List(U32), Str -> Str
	dup_key = |path, key| "contract: duplicate key \"${key}\" in each at site ${Engine.show_path(path)}"

	## The node id of a live row.
	node_of : Cols(r, item), U32 -> U32
	node_of = |cols, slot| cols.rnodes.get(slot.to_u64()) ?? crash "internal: row node"

	put_at : List(a), U64, a -> List(a)
	put_at = |list, i, v| if (i == list.len()) list.append(v) else (list.set(i, v) ?? crash "column")

	## Create one row at slot (fresh or reused), emit INST before `before`,
	## mount its nested sites. Returns the slot.
	create_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), item, U32, Tx -> (Cols(r, item), U32, Tx)
		where [item.is_eq : item, item -> Bool]
	create_row = |cfg, cols, env, item, before, tx| Engine.create_row_h(cfg, cols, env, item, before, Err(Unhashed), tx)

	## `create_row` given the key's hash when a lookup already computed it.
	create_row_h : EachCfg(r, item), Cols(r, item), (Str, item -> r), item, U32, Try(U64, [Unhashed]), Tx -> (Cols(r, item), U32, Tx)
		where [item.is_eq : item, item -> Bool]
	create_row_h = |cfg, cols, env, item, before, known_hash, tx| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		key = (cfg.key)(item)
		(slot, free2) = match free.last() {
			Ok(s) => (s, free.drop_last(1))
			Err(_) => (items.len().to_u32_wrap(), free)
		}
		si = slot.to_u64()
		keys2 = Engine.put_at(keys, si, key)
		(h, hashed) = match known_hash {
			Ok(kh) => (kh, 0)
			Err(Unhashed) => (Engine.hash_str(key), 1)
		}
		(index2, key_compares) = Engine.index_insert(index, keys2, key, h, slot, cfg.path)
		items2 = Engine.put_at(items, si, item)
		pend2 = Engine.put_at(pend, si, 0)
		(node, tx0) = Engine.alloc_id(tx)
		rnodes2 = Engine.put_at(rnodes, si, node)
		row_env = env(key, item)
		{ cmds, next, free: idfree, routes, work, paths, site_free, fx } = Engine.set_row_route(tx0, node, cfg.site, slot)
		var $c = Engine.put_u32(Engine.put_u32(Engine.put_u32(Engine.put_u32(cmds.append(1), node), cfg.parent), before), cfg.site)
		var $lasts = lasts
		var $sels = sels
		var $ev = 0.U64
		# Control state carried by INST (attribute holes named value or
		# checked) counts as set, like an ATTR would.
		var $set_value = 0.U64
		var $set_checked = 0.U64
		var $t = { cmds: [], next, free: idfree, routes, work, paths, site_free, fx }
		var $bound = []
		var $hi = 0.U64
		for hole in cfg.plan.holes {
			if hole.kind == 1 or hole.kind == 2 {
				v = (hole.read)(row_env)
				$ev = $ev + 1
				if hole.ctl == Engine.w_set_value {
					$set_value = $set_value + 1
				} else if hole.ctl == Engine.w_set_checked {
					$set_checked = $set_checked + 1
				}
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
		{ cmds: _, next: n3, free: f3, routes: r3, work: w3, paths: p3, site_free: sf3, fx: fx3 } = $t
		# One INST (a row and its scope created), its hole evaluations and the
		# key hash of the index insert.
		w4 = Engine.add_work(Engine.add_work(Engine.add_work(Engine.add_work(Engine.add_work(Engine.add_work(Engine.add_work(w3, 1, 1), Engine.w_evals, $ev), Engine.w_scopes_created, 1), Engine.w_key_hashes, hashed), Engine.w_key_compares, key_compares), Engine.w_set_value, $set_value), Engine.w_set_checked, $set_checked)
		var $tx = { cmds: $c, next: n3, free: f3, routes: r3, work: w4, paths: p3, site_free: sf3, fx: fx3 }
		if cfg.dynamic {
			var $insts = []
			var $km = kid_mask
			var $j = 0.U64
			for m in cfg.plan.mounts {
				mount = match m {
					Mount(f) => f
				}
				bid = $bound.get($j) ?? crash "bind"
				(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False, cap: cfg.plan.kreads.bitwise_or(Engine.upto(cfg.depth).bitwise_not()), local: True }, $tx)
				$insts = $insts.append(inst)
				$km = $km.bitwise_or(reads)
				$tx = t4
				$j = $j + 1
			}
			cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids: Engine.put_at(kids, si, $insts), binds: Engine.put_at(binds, si, $bound), pend: pend2, dirty, sels: $sels, known: known2, kid_mask: $km, dropped, rnodes: rnodes2 }
			(cols2, slot, $tx)
		} else {
			cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids, binds, pend: pend2, dirty, sels: $sels, known: known2, kid_mask, dropped, rnodes: rnodes2 }
			(cols2, slot, $tx)
		}
	}

	## Release one row's storage and nested sites. `remove` emits REMOVE.
	drop_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), U32, Bool, Tx -> (Cols(r, item), Tx)
	drop_row = |cfg, cols, env, slot, remove, tx| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		si = slot.to_u64()
		key = keys.get(si) ?? crash "key"
		index2 = Engine.index_remove(index, slot)
		pend2 = pend.set(si, 0) ?? pend
		node = rnodes.get(si) ?? crash "internal: row node"
		t0 = if (remove) Engine.emit_op(tx, 5, |c| Engine.put_u32(c, node)) else tx
		# A row removed by reconciliation: its scope is disposed.
		t1 = Engine.bump(Engine.bump(Engine.free_id(t0, node), Engine.w_rows_removed, 1), Engine.w_scopes_disposed, 1)
		if cfg.dynamic {
			{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
			{ list: bl, prev: row_binds } = binds.replace(si, []) ?? crash "binds"
			item = items.get(si) ?? crash "item"
			row_env = env(key, item)
			var $t = t1
			var $rk = row_kids
			var $j = 0.U64
			var $orph = []
			while $j < $rk.len() {
				{ list: rl, prev: kid } = $rk.replace($j, Engine.noop({})) ?? crash "kid"
				(_, out, t2) = Engine.call(kid, row_env, Dispose(False), $t)
				$orph = $orph.concat(Engine.orphans_of(out))
				$rk = rl
				$t = t2
				$j = $j + 1
			}
			for b in row_binds {
				$t = Engine.free_id($t, b)
			}
			dropped2 = if ($orph.is_empty()) dropped else dropped.append({ key, item, orphans: $orph })
			({ items, keys, order, free: free.append(slot), index: index2, lasts, kids: kl, binds: bl, pend: pend2, dirty, sels, known, kid_mask, dropped: dropped2, rnodes }, $t)
		} else {
			({ items, keys, order, free: free.append(slot), index: index2, lasts, kids, binds, pend: pend2, dirty, sels, known, kid_mask, dropped, rnodes }, t1)
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
	mark = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, slot, m| {
		si = slot.to_u64()
		p = pend.get(si) ?? 0
		dirty2 = if (p == 0) dirty.append(slot) else dirty
		{ items, keys, order, free, index, lasts, kids, binds, pend: pend.set(si, p.bitwise_or(m)) ?? pend, dirty: dirty2, sels, known, kid_mask, dropped, rnodes }
	}

	## A kept row whose new item may differ: equal items are pruned here.
	## Returns 1 when the item changed (the row is marked dirty).
	keep_row_n : Cols(r, item), U32, item, U64 -> (Cols(r, item), U64)
		where [item.is_eq : item, item -> Bool]
	keep_row_n = |cols, slot, item, row_bit| {
		si = slot.to_u64()
		same = match cols.items.get(si) {
			Ok(old) => old == item
			Err(_) => crash "item"
		}
		if same {
			(cols, 0)
		} else {
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
			(Engine.mark({ items: items.set(si, item) ?? crash "item", keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, slot, row_bit), 1)
		}
	}

	set_order : Cols(r, item), List(U32) -> Cols(r, item)
	set_order = |{ items, keys, order: _, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, order| {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }
	}

	take_order : Cols(r, item) -> (Cols(r, item), List(U32))
	take_order = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }| {
		({ items, keys, order: [], free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, order)
	}

	end_ref : EachCfg(r, item) -> U32
	end_ref = |cfg| if (cfg.sole) 0 else cfg.anchor

	## The node a row inserted at position `pos` (of `order`) goes before.
	ref_at : EachCfg(r, item), Cols(r, item), U64 -> U32
	ref_at = |cfg, cols, pos| match cols.order.get(pos) {
		Ok(s) => Engine.node_of(cols, s)
		Err(_) => Engine.end_ref(cfg)
	}

	key_of_slot : Cols(r, item), U32 -> Str
	key_of_slot = |cols, slot| cols.keys.get(slot.to_u64()) ?? crash "key"

	same_row : EachCfg(r, item), Cols(r, item), U32, item -> Bool
		where [item.is_eq : item, item -> Bool]
	same_row = |cfg, cols, slot, item| {
		match cols.items.get(slot.to_u64()) {
			Ok(old) => if (old == item) True else Engine.key_of_slot(cols, slot) == (cfg.key)(item)
			Err(_) => crash "item"
		}
	}

	## Release every live row's node id (the DOM goes with its parent).
	free_rows : Cols(r, item), Tx -> Tx
	free_rows = |cols, tx| {
		var $tx = Engine.bump(tx, Engine.w_scopes_disposed, cols.order.len())
		for slot in cols.order {
			$tx = Engine.free_id($tx, Engine.node_of(cols, slot))
		}
		$tx
	}

	## Remove every row.
	clear_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), Bool, Tx -> (Cols(r, item), Tx)
	clear_rows = |cfg, cols, env, dom, tx| {
		var $tx = Engine.bump(tx, Engine.w_scopes_disposed, cols.order.len())
		var $dropped = []
		if !dom {
			{}
		} else if cfg.sole {
			$tx = Engine.emit_op($tx, 6, |c| Engine.put_u32(Engine.put_u32(c, cfg.parent), cfg.site))
		} else {
			for slot in cols.order {
				$tx = Engine.emit_op($tx, 5, |c| Engine.put_u32(c, Engine.node_of(cols, slot)))
			}
		}
		for slot in cols.order {
			$tx = Engine.free_id($tx, Engine.node_of(cols, slot))
		}
		if cfg.dynamic {
			var $i = 0.U64
			while $i < cols.kids.len() {
				live = match cols.items.get($i) {
					Ok(item) => {
						key = cols.keys.get($i) ?? ""
						match Engine.index_find(cols.index, cols.keys, key, Engine.hash_str(key)) {
							Ok(s) => if (s.to_u64() == $i) Ok(item) else Err(Dead)
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
						var $orph = []
						while $j < $rk.len() {
							{ list: rl, prev: kid } = $rk.replace($j, Engine.noop({})) ?? crash "kid"
							(_, out, t2) = Engine.call(kid, row_env, Dispose(False), $tx)
							$orph = $orph.concat(Engine.orphans_of(out))
							$rk = rl
							$tx = t2
							$j = $j + 1
						}
						if !$orph.is_empty() {
							$dropped = $dropped.append({ key, item, orphans: $orph })
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
		{ sels, known, kid_mask, lasts, dropped: dropped0, items: _, keys: _, order: _, free: _, index: _, kids: _, binds: _, pend: _, dirty: _, rnodes: _ } = cols
		dropped = dropped0.concat($dropped)
		ncols = lasts.len()
		({ items: [], keys: [], order: [], free: [], index: Engine.index_empty, lasts: List.repeat([], ncols), kids: [], binds: [], pend: [], dirty: [], sels, known, kid_mask, dropped, rnodes: [] }, $tx)
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
	## Reconcile and count the rows kept (`rows_reused`): the old rows that
	## were not removed. Every reconciliation counts, including one whose new
	## list is equal to the old: the engine keeps no previous list to prune
	## by (design.md, "In-place ownership").
	reconcile : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
		where [item.is_eq : item, item -> Bool]
	reconcile = |cfg, cols, env, list, tx| {
		n_old = cols.order.len()
		w0 = Engine.change_marks(tx)
		(c2, t2) = Engine.reconcile_rows(cfg, cols, env, list, tx)
		w2 = Engine.change_marks(t2)
		# An equal new list (nothing created, moved, removed or changed)
		# reconciled nothing and reuses nothing. The accumulator is rebuilt
		# on both paths (roc-lang/roc#12846).
		reused = if (w2 == w0) 0 else n_old - (w2.removed - w0.removed)
		(c2, Engine.bump(t2, Engine.w_rows_reused, reused))
	}

	## The counters a reconciliation moves when the list changed: rows
	## created, moved, removed, or kept with a changed item.
	change_marks : Tx -> { created : U64, moved : U64, removed : U64, updated : U64 }
	change_marks = |tx| {
		w = tx.work
		{ created: w.c01, moved: w.c04, removed: Engine.work_get(w, Engine.w_rows_removed), updated: Engine.work_get(w, Engine.w_rows_updated) }
	}

	reconcile_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
		where [item.is_eq : item, item -> Bool]
	reconcile_rows = |cfg, cols, env, list, tx| {
		n_old = cols.order.len()
		n_new = list.len()
		row_bit = Engine.bit(cfg.depth)
		if n_new == 0 {
			if (n_old == 0) (cols, tx) else Engine.clear_rows(cfg, cols, env, True, Engine.bump(tx, Engine.w_rows_removed, n_old))
		} else if n_old == 0 {
			Engine.append_rows(cfg, cols, env, list, 0, tx)
		} else {
			var $cols = cols
			var $tx = tx
			# Kept rows whose item changed, counted once after the loops so the
			# accumulator is not threaded through every kept row.
			var $updated = 0.U64
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
						(c2, u) = Engine.keep_row_n($cols, slot, item, row_bit)
						$cols = c2
						$updated = $updated + u
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
						(c2, u) = Engine.keep_row_n($cols, slot, item, row_bit)
						$cols = c2
						$updated = $updated + u
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
						na = Engine.node_of($cols, a)
						nb = Engine.node_of($cols, b)
						after = Engine.ref_at(cfg, $cols, $oe)
						$tx = Engine.emit_op(Engine.emit_op($tx, 4, |c| Engine.put_u32(Engine.put_u32(c, nb), na)), 4, |c| Engine.put_u32(Engine.put_u32(c, na), after))
						(c3, u3) = Engine.keep_row_n($cols, b, first, row_bit)
						(c4, u4) = Engine.keep_row_n(c3, a, last, row_bit)
						$cols = c4
						$updated = $updated + u3 + u4
						(c2, order) = Engine.take_order($cols)
						$cols = Engine.set_order(c2, order.swap($i, $oe - 1) ?? crash "order")
						$i = $i + 1
						$oe = $oe - 1
						$ne = $ne - 1
						$go = True
					}
				}
			}
			$tx = Engine.bump($tx, Engine.w_rows_updated, $updated)
			if $i == $oe and $i == $ne {
				($cols, $tx)
			} else if $i == $oe {
				# pure insertion of list[i..ne) before position oe
				if $oe == $cols.order.len() {
					Engine.append_rows(cfg, $cols, env, list, $i, $tx)
				} else {
					before = Engine.ref_at(cfg, $cols, $oe)
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
				kept = if ($oe - $i == 1) order.drop_at($i) else order.sublist({ start: 0, len: $i }).concat(order.sublist({ start: $oe, len: order.len() - $oe }))
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
		var $compares = 0.U64
		var $hashes = []
		$k = i
		while $k < ne {
			item = list.get($k) ?? crash "row"
			key = (cfg.key)(item)
			h = Engine.hash_str(key)
			$hashes = $hashes.append(h)
			probe = Engine.index_probe(cols.index, cols.keys, key, h)
			$compares = $compares + probe.compares
			r = match probe.found {
				Ok(s) => {
					if ($oldpos.get(s.to_u64()) ?? 0) == 0 {
						crash Engine.dup_key(cfg.path, key)
					}
					if $seen.get(s.to_u64()) ?? False {
						crash Engine.dup_key(cfg.path, key)
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
		var $tx = Engine.bump(Engine.bump(tx, Engine.w_key_hashes, ne - i), Engine.w_key_compares, $compares)
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
			$seq = $seq.append(if (f == 0) 0 else $oldpos.get(f - 1) ?? 0)
		}
		stable = Engine.lis_mark($seq)
		# place from the end
		var $slots = List.repeat(0.U32, ne - i)
		var $updated = 0.U64
		var $ref = Engine.ref_at(cfg, $cols, oe)
		var $p = ne
		while $p > i {
			$p = $p - 1
			idx = $p - i
			item = list.get($p) ?? crash "row"
			f = $found.get(idx) ?? 0
			if f == 0 {
				(c2, slot, t2) = Engine.create_row_h(cfg, $cols, env, item, $ref, Ok($hashes.get(idx) ?? crash "internal: hash"), $tx)
				$cols = c2
				$tx = t2
				$slots = $slots.set(idx, slot) ?? $slots
				$ref = Engine.node_of($cols, slot)
			} else {
				slot = (f - 1).to_u32_wrap()
				node = Engine.node_of($cols, slot)
				if !(stable.get(idx) ?? False) {
					r = $ref
					$tx = Engine.emit_op($tx, 4, |c| Engine.put_u32(Engine.put_u32(c, node), r))
				}
				(c4, u4) = Engine.keep_row_n($cols, slot, item, row_bit)
				$cols = c4
				$updated = $updated + u4
				$slots = $slots.set(idx, slot) ?? $slots
				$ref = node
			}
		}
		(c3, order) = Engine.take_order($cols)
		merged = order.sublist({ start: 0, len: i }).concat($slots).concat(order.sublist({ start: oe, len: order.len() - oe }))
		(Engine.set_order(c3, merged), Engine.bump($tx, Engine.w_rows_updated, $updated))
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
				p = if ($lo > 0) ($tails.get($lo - 1) ?? 0) + 1 else 0
				$prev = $prev.set($i, p) ?? $prev
				$tails = if ($lo == $tails.len()) $tails.append($i) else ($tails.set($lo, $i) ?? $tails)
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
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		var $lasts = lasts
		var $pend = pend
		var $kids = kids
		var $tx = tx
		# Hole evaluations, counted once after the loop.
		var $evals = 0.U64
		for slot in dirty {
			si = slot.to_u64()
			m = $pend.get(si) ?? 0
			$pend = $pend.set(si, 0) ?? $pend
			key = keys.get(si) ?? crash "key"
			item = items.get(si) ?? crash "item"
			row_env = env(key, item)
			node = rnodes.get(si) ?? crash "internal: row node"
			var $hi = 0.U64
			for hole in cfg.plan.holes {
				if hole.live and hole.mask.bitwise_or(hole.smask).bitwise_and(m) != 0 {
					v = (hole.read)(row_env)
					{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
					old = prev.get(si) ?? ""
					$evals = $evals + 1
					if v == old {
						$lasts = list.set(hole.col, prev) ?? crash "lasts"
					} else {
						op = if (hole.kind == 1) 2 else 3
						hidx = $hi.to_u8_wrap()
						$tx = Engine.emit_op(Engine.bump($tx, hole.ctl, 1), op, |c| Engine.put_str(Engine.put_u32(c, node).append(hidx), v))
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
		({ items, keys, order, free, index, lasts: $lasts, kids: $kids, binds, pend: $pend, dirty: dirty.clear(), sels, known, kid_mask, dropped, rnodes }, Engine.count_evals($tx, $evals))
	}

	## Selection changed: mark only the previously and newly selected rows.
	select_changed : EachCfg(r, item), Cols(r, item), (Str, item -> r), U64 -> Cols(r, item)
	select_changed = |cfg, cols, env, mask| {
		first = cols.order.first()
		match first {
			Err(_) => {
				{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, rnodes } = cols
				{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: False, kid_mask, dropped, rnodes }
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
							{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, rnodes } = $cols
							$cols = { items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels: sels.set($hi, nk) ?? sels, known: True, kid_mask, dropped, rnodes }
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
	each_fire_kid : Cols(Row(ctx, item), item), Row(ctx, item), U64, List(U32), U64, U32, Payload, Tx -> (Cols(Row(ctx, item), item), ctx, U64, Tx)
	each_fire_kid = |cols, row_env, si, path, pos, h, payload, tx| {
		j = (path.get(pos + 1) ?? 0).to_u64()
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
		if j < row_kids.len() {
			{ list: rl, prev: kid } = row_kids.replace(j, Engine.noop({})) ?? crash "kid"
			(k2, out, t2) = Engine.call(kid, row_env, Fire(path, pos + 2, h, payload), tx)
			kids2 = kl.set(si, rl.set(j, k2) ?? crash "kid") ?? crash "kids"
			(outer, m) = Engine.row_out(out)
			({ items, keys, order, free, index, lasts, kids: kids2, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, outer, m, t2)
		} else {
			{ outer, key: _, item: _ } = row_env
			({ items, keys, order, free, index, lasts, kids: kl.set(si, row_kids) ?? crash "kids", binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, outer, 0, tx)
		}
	}

	row_out : Out(Row(ctx, item)) -> (ctx, U64)
	row_out = |out| match out {
		Pending(e2, m) => {
			{ outer, key: _, item: _ } = e2
			(outer, m)
		}
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
	}

	## `adopted`: orphans reparented here from removed rows.
	each_inst : EachCfg(Row(ctx, item), item), Val(ctx, List(item)), List(Orphan(ctx)), Cols(Row(ctx, item), item) -> Inst(ctx)
		where [item.is_eq : item, item -> Bool]
	each_inst = |cfg0, rows0, adopted0, cols0| {
		held = Held({ cfg: cfg0, rows: rows0, adopted: adopted0, cols: cols0 })
		Inst(
			|env, msg, tx| {
				Held({ cfg, rows, adopted, cols }) = held
				mk = |k, it| Row.{ outer: env, key: k, item: it }
				match msg {
					Changed(mask) => {
						# Mark existing rows first (outer layers, then the keyed selector),
						# then reconcile: rows created now are evaluated once, at creation;
						# rows removed now drop their marks.
						full = mask.bitwise_and(cfg.outer_mask.bitwise_or(cols.kid_mask)).bitwise_and(Engine.bit(cfg.depth) - 1)
						c1 = if (full != 0) Engine.mark_all(cols, full) else cols
						c2 = if (cfg.sel_mask.bitwise_and(mask) != 0) Engine.select_changed(cfg, c1, mk, mask) else c1
						rows_mask = Engine.eff_mask(rows)
						(c3, t1) = if rows_mask.bitwise_and(mask) != 0 {
							list = (rows.read)(env)
							Engine.reconcile(cfg, c2, mk, list, Engine.count_evals(tx, 1))
						} else {
							(c2, tx)
						}
						(c4, t4) = Engine.settle(cfg, c3, mk, t1)
						(c5, orph) = Engine.take_dropped(c4, cfg.depth)
						(Engine.each_inst(cfg, rows, adopted.concat(orph), c5), Done, Engine.fx_adopt(t4, cfg.path, orph))
					}
					Fire(path, pos, h, payload) => {
						slot = path.get(pos) ?? 0
						si = slot.to_u64()
						fx = Engine.leaf_fx(path, pos, payload)
						if fx.is_ok() {
							res = fx ?? crash "fx"
							(ad2, out, t2) = Engine.adopt_deliver(adopted, env, h, res, tx)
							(Engine.each_inst(cfg, rows, ad2, cols), out, t2)
						} else if !Engine.is_live(cols, si) {
							(Engine.each_inst(cfg, rows, adopted, cols), Pending(env, 0), tx)
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
										next = Engine.each_inst(cfg, rows, adopted, cols)
										{ outer, key: _, item: _ } = (handler.run)(row_env, Engine.ev_str(payload))
										(next, Pending(outer, handler.mask), tx)
									}
									Err(_) => {
										{ outer, key: _, item: _ } = row_env
										(Engine.each_inst(cfg, rows, adopted, cols), Pending(outer, 0), tx)
									}
								}
							} else {
								(cols2, outer, m, t2) = Engine.each_fire_kid(cols, row_env, si, path, pos, h, payload, tx)
								(Engine.each_inst(cfg, rows, adopted, cols2), Pending(outer, m), t2)
							}
						}
					}
					Dispose(remove) => {
						# Row node ids come from the shared pool: release them even when
						# nothing else needs doing for a static row set.
						(c1, t1) = if (remove or cfg.dynamic) Engine.clear_rows(cfg, cols, mk, remove, tx) else (cols, Engine.free_rows(cols, tx))
						(_, orph) = Engine.take_dropped(c1, cfg.depth)
						t2 = if !cfg.sole {
							if (remove) Engine.free_id(Engine.emit_op(t1, 5, |c| Engine.put_u32(c, cfg.anchor)), cfg.anchor) else Engine.free_id(t1, cfg.anchor)
						} else t1
						(Engine.noop({}), Orphaned(adopted.concat(orph)), Engine.free_site(t2, cfg.site))
					}
				}
			},
		)
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
		Mount(
			|env, args, tx| {
				depth = Engine.layer(args.depth, args.path)
				elem = body(Engine.state_handle(depth))
				(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, tx)
				reads = block.reads
				(Engine.state_inst(init, block, depth, args.local), reads, tx1)
			},
		),
		|d| {
			d1 = Engine.layer_reads(d)
			Engine.elem_reads(body(Engine.state_handle(d1)), d1).bitwise_and(Engine.bit(d1) - 1)
		},
	)

	## A keyed list. The template runs once per site; rows are typed columns.
	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Site(
		Mount(
			|env, args, tx| {
				depth = Engine.layer(args.depth, args.path)
				row_bit = Engine.bit(depth)
				plan = Engine.compile(template(RowRef.{ depth }), depth)
				(site, tx1) = Engine.alloc_site(tx, args.path)
				tpl = Engine.template_bytes(plan)
				tx2 = Engine.emit_op(tx1, 7, |c| Engine.put_u32(Engine.put_u32(c, site), tpl.len().to_u32_wrap()).concat(tpl))
				(anchor, tx3) = if args.sole {
					(0, tx2)
				} else {
					(a, t) = Engine.alloc_id(tx2)
					before = args.before
					(a, Engine.emit_op(t, 10, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, a), args.parent), before), "")))
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
				(Engine.each_inst(cfg, rows, [], cols), reads, tx4)
			},
		),
		|d| {
			d1 = Engine.layer_reads(d)
			Engine.eff_mask(rows).bitwise_or(Engine.elem_reads(template(RowRef.{ depth: d1 }), d1).bitwise_and(Engine.bit(d1) - 1))
		},
	)

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Site(
		Mount(
			|env, args, tx| {
				(anchor, tx1) = Engine.alloc_id(tx)
				before = args.before
				tx2 = Engine.emit_op(tx1, 10, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, anchor), args.parent), before), ""))
				c = (cond.read)(env)
				elem = if (c) yes() else no()
				(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, { cap: args.cap, local: args.local }, Engine.bump(Engine.count_evals(tx2, 1), Engine.w_scopes_created, 1))
				# Listen to the condition, this branch, and what the other branch
				# would read once mounted (or the cap, when the parent knows it).
				reads = if args.cap != 0 {
					args.cap
				} else {
					other = if (c) no() else yes()
					Engine.eff_mask(cond).bitwise_or(block.reads).bitwise_or(Engine.elem_reads(other, args.depth))
				}
				w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap, local: args.local }
				(Engine.when_inst(w, c, [], block), reads, tx3)
			},
		),
		|d| Engine.eff_mask(cond).bitwise_or(Engine.elem_reads(yes(), d)).bitwise_or(Engine.elem_reads(no(), d)),
	)

	## ------------------------------------------------------------------
	## A conditional over a value: the content is `body(k)` for the current
	## value `k` of `sel`, rebuilt when it changes. `cases` lists every value
	## `sel` can take; the site's static reads are the union over them (so it
	## listens exactly), and a value outside `cases` is a contract error.
	Switch(ctx, k) : { sel : Val(ctx, k), cases : List(k), body : (k -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64, local : Bool }

	switch_reads : Val(ctx, k), List(k), (k -> Elem(ctx)), U64 -> U64
	switch_reads = |sel, cases, body, d| {
		var $m = Engine.eff_mask(sel)
		for c in cases {
			$m = $m.bitwise_or(Engine.elem_reads(body(c), d))
		}
		$m
	}

	switch : Val(ctx, k), List(k), (k -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	switch = |sel, cases, body| Site(
		Mount(
			|env, args, tx| {
				(anchor, tx1) = Engine.alloc_id(tx)
				before = args.before
				tx2 = Engine.emit_op(tx1, 10, |c| Engine.put_str(Engine.put_u32(Engine.put_u32(Engine.put_u32(c, anchor), args.parent), before), ""))
				k = Engine.switch_value(sel, cases, env, args.path)
				(block, tx3) = Engine.mount_block(env, body(k), args.depth, args.path, 0, anchor, { cap: args.cap, local: args.local }, Engine.bump(Engine.count_evals(tx2, 1), Engine.w_scopes_created, 1))
				reads = if (args.cap != 0) args.cap else Engine.switch_reads(sel, cases, body, args.depth)
				w = { sel, cases, body, anchor, depth: args.depth, path: args.path, cap: args.cap, local: args.local }
				(Engine.switch_inst(w, k, [], block), reads, tx3)
			},
		),
		|d| Engine.switch_reads(sel, cases, body, d),
	)

	switch_value : Val(ctx, k), List(k), ctx, List(U32) -> k
		where [k.is_eq : k, k -> Bool]
	switch_value = |sel, cases, env, path| {
		k = (sel.read)(env)
		if (cases.contains(k)) k else crash "contract: switch value is not one of its cases at site ${Engine.show_path(path)}"
	}

	switch_inst : Switch(ctx, k), k, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
		where [k.is_eq : k, k -> Bool]
	switch_inst = |w0, cur0, adopted0, block0| {
		held = Held({ w: w0, cur: cur0, adopted: adopted0, block: block0 })
		Inst(
			|env, msg, tx| {
				Held({ w, cur, adopted, block }) = held
				match msg {
					Changed(mask) => {
						if Engine.eff_mask(w.sel).bitwise_and(mask) != 0 {
							k = Engine.switch_value(w.sel, w.cases, env, w.path)
							t1 = Engine.count_evals(tx, 1)
							if k == cur {
								(b2, t2) = Engine.refresh(block, env, mask, t1)
								(Engine.switch_inst(w, cur, adopted, b2), Done, t2)
							} else {
								(orph, t2) = Engine.dispose_block(block, env, True, Engine.bump(Engine.bump(t1, Engine.w_scopes_disposed, 1), Engine.w_scopes_created, 1))
								(b3, t3) = Engine.mount_block(env, (w.body)(k), w.depth, w.path, 0, w.anchor, { cap: w.cap, local: w.local }, Engine.fx_adopt(t2, w.path, orph))
								(Engine.switch_inst(w, k, adopted.concat(orph), b3), Done, t3)
							}
						} else {
							(b2, t2) = Engine.refresh(block, env, mask, tx)
							(Engine.switch_inst(w, cur, adopted, b2), Done, t2)
						}
					}
					Fire(path, pos, h, payload) => {
						match Engine.leaf_fx(path, pos, payload) {
							Ok(res) => {
								(ad2, out, t2) = Engine.adopt_deliver(adopted, env, h, res, tx)
								(Engine.switch_inst(w, cur, ad2, block), out, t2)
							}
							Err(_) => {
								match Engine.fire_target(block, path, pos) {
									Leaf => {
										out = Engine.fire_leaf(block, env, h, payload)
										(Engine.switch_inst(w, cur, adopted, block), out, tx)
									}
									Kid => {
										(b2, out, t2) = Engine.fire_kid(block, env, path, pos, h, payload, tx)
										(Engine.switch_inst(w, cur, adopted, b2), out, t2)
									}
									Miss => (Engine.switch_inst(w, cur, adopted, block), Pending(env, 0), tx)
								}
							}
						}
					}
					Dispose(remove) => {
						(orph, t1) = Engine.dispose_block(block, env, remove, Engine.bump(tx, Engine.w_scopes_disposed, 1))
						t2 = if (remove) Engine.emit_op(t1, 5, |c| Engine.put_u32(c, w.anchor)) else t1
						(Engine.noop({}), Orphaned(adopted.concat(orph)), Engine.free_id(t2, w.anchor))
					}
				}
			},
		)
	}

	## ------------------------------------------------------------------
	## Memoised shared derivation. `derive(input, body)` evaluates `input`
	## once per change of the layers it reads and exposes the result as a new
	## layer: readers inside `body` see it with this layer's own bit, and an
	## equal recomputation stops propagation (readers that read only the
	## derived value do no work). Outer values used inside `body` need `.lift()`.
	derive : Val(ctx, a), (Val(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Site(
		Mount(
			|env, args, tx| {
				depth = Engine.layer(args.depth, args.path)
				v = (input.read)(env)
				elem = body({ mask: Engine.bit(depth), read: |e| e.value, sel: NoSel })
				(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, Engine.count_evals(tx, 1))
				reads = block.reads.bitwise_and(Engine.bit(depth) - 1).bitwise_or(Engine.eff_mask(input))
				(Engine.derive_inst(input, v, block, depth), reads, tx1)
			},
		),
		|d| {
			d1 = Engine.layer_reads(d)
			Engine.eff_mask(input).bitwise_or(Engine.elem_reads(body({ mask: Engine.bit(d1), read: |e| e.value, sel: NoSel }), d1).bitwise_and(Engine.bit(d1) - 1))
		},
	)

	derive_inst : Val(ctx, a), a, Block(In(ctx, a)), U64 -> Inst(ctx)
		where [a.is_eq : a, a -> Bool]
	derive_inst = |input0, v0, block0, depth0| {
		held = Held({ input: input0, v: v0, block: block0, depth: depth0 })
		Inst(
			|env, msg, tx| {
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
						(orph, t2) = Engine.dispose_block(block, In.{ outer: env, value: v }, remove, tx)
						(Engine.noop({}), Orphaned(Engine.lower_in(orph, v, depth)), t2)
					}
				}
			},
		)
	}

	## A derived layer has no write handle, so an event below it can only have
	## changed an outer layer (which will refresh this site) or nothing.
	derive_settle : Val(ctx, a), Block(In(ctx, a)), U64, Out(In(ctx, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
		where [a.is_eq : a, a -> Bool]
	derive_settle = |input, block, depth, out, tx| {
		match out {
			Done => crash "internal: fire must hand the environment back"
			Orphaned(_) => crash "internal: fire must hand the environment back"
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
	component = |prop, snk, body| Site(
		Mount(
			|env, args, tx| {
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
				(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, { cap: 0, local: True }, Engine.bump(Engine.count_evals(tx, 1), Engine.w_scopes_created, 1))
				(Engine.comp_inst(prop, snk, block), Engine.eff_mask(prop), tx1)
			},
		),
		|_| Engine.eff_mask(prop),
	)

	comp_inst : Val(ctx, p), Sink(ctx, a), Block(Comp(p, a)) -> Inst(ctx)
	comp_inst = |prop0, snk0, block0| {
		held = Held({ prop: prop0, snk: snk0, block: block0 })
		Inst(
			|env, msg, tx| {
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
						(orph, t2) = Engine.dispose_block(block, Comp.{ prop: (prop.read)(env), out: [] }, remove, Engine.bump(tx, Engine.w_scopes_disposed, 1))
						(Engine.noop({}), Orphaned(Engine.lower_comp(orph, prop, snk)), t2)
					}
				}
			},
		)
	}

	## Take the pushed actions out of a settled component environment. A
	## function of its own so the inner environment (and the prop it holds, a
	## reference into an outer state) is dropped before any sink reducer runs.
	comp_actions : Out(Comp(p, a)) -> List(a)
	comp_actions = |out| match out {
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
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

	## ------------------------------------------------------------------
	## Effects.
	##
	## An effect site watches a value. At mount (`watch`; `on_change` skips
	## mount) and whenever the value changes (equality-pruned), `plan` turns
	## the value into requests.
	##
	## - Commands (Push, Replace, Title, StorageSet, StorageRemove) are
	##   emitted into the command stream and forgotten.
	## - Awaited requests (Http, StorageGet, Timer, Interval, Popstate) get a
	##   fresh instance-wide id (issue order, from 1), are recorded in the
	##   in-flight table with the issuing site's path, and are owned by that
	##   site. Interval and Popstate are subscriptions: they stay in flight,
	##   delivering any number of results, until the site is disposed.
	## - Disposal (design.md, "Requests, effects, and cancellation" and the
	##   lifetime table): subscriptions, intervals and timers are stopped
	##   (CANCEL id) and forgotten. Admitted requests (Http, StorageGet) are
	##   not cancelled: they reparent to the nearest surviving ancestor site
	##   (the `when`/`switch` that switched branch, or the `each` that removed
	##   the row), which delivers the result by running the reaction in its
	##   current environment. The disposed layers are snapshots there: writes
	##   to retired states are skipped and counted (`skipped`), writes to
	##   surviving states commit. Reading of the design: a reaction writes one
	##   state, so "per-write" application is per reaction; the snapshot of a
	##   retired layer is retained until the result arrives (bounded by `max`).
	## - A result enters exactly as a DOM event does: one turn that fires down
	##   the owning site's path, where the site's reaction runs as a handler
	##   with the value the request was issued for, then the Changed pass.
	## - A result whose id is not in flight (cancelled, already delivered,
	##   never issued) is dropped before any state is touched and counted in
	##   `stale`. The site checks its own ownership too, so a path that a
	##   disposed site's successor now occupies never receives its results.
	## - The in-flight table is bounded by `max`. A request beyond it is not
	##   issued (no command): it is refused, counted, and its owner receives a
	##   typed `Refused` result in a follow-up turn.
	## - `Self` asks for a follow-up turn with result `Now`: how an effect site
	##   changes state in response to its value changing, without writing
	##   during the turn that is evaluating. Follow-up ids are a separate
	##   space (high bit set) so host-visible ids stay consecutive.
	## - Follow-up turns run after the current turn, in order, at most
	##   `max_turns` per host call; exceeding it is a contract error (an
	##   effect feedback loop) and traps the instance.
	##
	## Command stream additions:
	##  13 FX      id kind:u8 ... 1 HTTP method:str url:str n:u32 (name:str value:str)* body:str timeout_ms:u32
	##                            2 STORAGE_GET key:str  3 TIMER ms:u32  4 INTERVAL ms:u32  5 POPSTATE
	##  14 CANCEL  id
	##  15 NAV     mode:u8 (1 push, 2 replace) url:str
	##  16 STORE   op:u8 (1 set: key:str value:str, 2 remove: key:str)
	##  17 TITLE   text:str
	##  18 FOCUS   op:u8 (1 focus, 2 blur, 3 select text) node   (end of turn)
	## Results come back as an event on node `fx_node` with handler = id and
	## payload bytes: 1 status:u16 n:u32 (name:str value:str)* body (HTTP
	## response with its headers), 7 (HTTP timeout), 2 message (network
	## failure), 3 value (storage value), 4 (storage missing), 5 (timer
	## fired), 6 url (location).
	Req : [
		## `timeout_ms` 0 = no timeout; capped at `max_timeout_ms`.
		Http({ method : Str, url : Str, headers : List((Str, Str)), body : Str, timeout_ms : U32 }),
		StorageGet(Str),
		Timer(U32),
		Interval(U32),
		Popstate,

		## Subscriptions to the browser's connectivity (`online`/`offline`)
		## and page visibility (`visibilitychange`). Each change delivers
		## `Online(Bool)` or `Visible(Bool)`; the value at mount is in `Boot`.
		OnlineChanges,
		VisibilityChanges,
		Self,
		Push(Str),
		Replace(Str),
		Title(Str),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		StorageSet(Str, Str),
		StorageRemove(Str),
	]

	Res : [Http({ status : U16, headers : List((Str, Str)), body : Str }), Network(Str), Timeout, Value(Str), Missing, Fired, Location(Str), Online(Bool), Visible(Bool), Now, Refused]

	## Why an HTTP request did not produce a successful response, as
	## `http_text` reports it: the browser could not reach the server
	## (`Network`, with the browser's message), the request's `timeout_ms`
	## expired (`Timeout`), the server answered outside 2xx (`Status`), or
	## the in-flight bound refused the request (`Refused`).
	HttpError : [Network(Str), Timeout, Status(U16), Refused]

	## An HTTP result as the body of a 2xx response or a typed failure.
	## Any other result kind is a contract error: only an HTTP request's
	## reaction receives HTTP results.
	http_text : Res -> Try(Str, HttpError)
	http_text = |res| match res {
		Http({ status, body, .. }) => if (status >= 200 and status < 300) Ok(body) else Err(Status(status))
		Network(message) => Err(Network(message))
		Timeout => Err(Timeout)
		Refused => Err(Refused)
		_ => crash "contract: http_text was given a result that is not an HTTP result"
	}

	## Largest per-request HTTP timeout the host will arm (10 minutes).
	max_timeout_ms : U32
	max_timeout_ms = 600000

	Live : { id : U32, path : List(U32), sub : Bool }

	Queued : { id : U32, path : List(U32), res : Res }

	Fx : {
		next : U32,
		inner : U32,
		live : List(Live),
		queue : List(Queued),
		max : U64,
		issued : U64,
		delivered : U64,
		stale : U64,
		refused : U64,
		cancelled : U64,
		reparented : U64,
		skipped : U64,

		## Focus references (name, node) and focus commands awaiting the end
		## of the turn (op 1 focus, 2 blur, 3 select, ref name).
		refs : List((Str, U32)),
		focus : List((U8, Str)),

		## `ref_pos[node]`: the node's position in `refs` plus one (0: the node
		## carries no reference), so freeing a node id is O(1).
		ref_pos : List(U32),

		## `on_cleanup` runs, by name, in first-run order.
		cleanups : List((Str, U64)),
	}

	fx_empty : Fx
	fx_empty = { next: 1, inner: 2147483648, live: [], queue: [], max: 32, issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, refs: [], focus: [], ref_pos: [], cleanups: [] }

	## The host node id that marks an event as an effect result.
	fx_node : U32
	fx_node = 4294967295

	## Follow-up turns allowed per host call.
	max_turns : U64
	max_turns = 64

	## What an effect site does with a result: a reducer over the context,
	## given the value the request was issued for.
	Reaction(ctx, a) : { mask : U64, run : (ctx, a, Res -> ctx) }

	## A reaction that ignores every result (command-only sites).
	ignore : {} -> Reaction(ctx, a)
	ignore = |_| { mask: 0, run: |e, _, _| e }

	## A request the site owns: its id, whether it is a subscription, and the
	## value it was issued for.
	Owned(a) : { id : U32, sub : Bool, keep : Bool, a : a }

	EffectCfg(ctx, a) : { v : Val(ctx, a), plan : (a -> List(Req)), react : Reaction(ctx, a), path : List(U32) }

	with_fx : Tx, (Fx -> Fx) -> Tx
	with_fx = |{ cmds, next, free, routes, work, paths, site_free, fx }, f| { cmds, next, free, routes, work, paths, site_free, fx: f(fx) }

	fx_count : Tx, [Delivered, Stale] -> Tx
	fx_count = |tx, k| Engine.with_fx(
		tx,
		|fx| match k {
			Delivered => { ..fx, delivered: fx.delivered + 1 }
			Stale => { ..fx, stale: fx.stale + 1 }
		},
	)

	is_sub : Req -> Bool
	is_sub = |req| match req {
		Interval(_) => True
		Popstate => True
		OnlineChanges => True
		VisibilityChanges => True
		_ => False
	}

	## Requests that survive their site's disposal (design.md: an admitted
	## effect reparents). Subscriptions, intervals and timers are scoped:
	## disposal stops them.
	is_kept : Req -> Bool
	is_kept = |req| match req {
		Http(_) => True
		StorageGet(_) => True
		_ => False
	}

	min_u32 : U32, U32 -> U32
	min_u32 = |a, b| if (a < b) a else b

	put_req : List(U8), U32, Req -> List(U8)
	put_req = |c, id, req| {
		head = Engine.put_u32(c.append(13), id)
		match req {
			Http({ method, url, headers, body, timeout_ms }) => {
				var $b = Engine.put_u32(Engine.put_str(Engine.put_str(head.append(1), method), url), headers.len().to_u32_wrap())
				for (k, v) in headers {
					$b = Engine.put_str(Engine.put_str($b, k), v)
				}
				Engine.put_u32(Engine.put_str($b, body), Engine.min_u32(timeout_ms, Engine.max_timeout_ms))
			}
			StorageGet(k) => Engine.put_str(head.append(2), k)
			Timer(ms) => Engine.put_u32(head.append(3), ms)
			Interval(ms) => Engine.put_u32(head.append(4), ms)
			Popstate => head.append(5)
			OnlineChanges => head.append(6)
			VisibilityChanges => head.append(7)
			_ => crash "not an awaited request"
		}
	}

	## Admit an awaited request (or refuse it when the table is full).
	fx_admit : Tx, List(U32), Req -> (U32, Tx)
	fx_admit = |{ cmds, next, free, routes, work, paths, site_free, fx }, path, req| {
		{ next: id, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups } = fx
		if live.len() >= max {
			fx2 = { next: id + 1, inner, live, queue: queue.append({ id, path, res: Refused }), max, issued, delivered, stale, refused: refused + 1, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }
			(id, { cmds, next, free, routes, work, paths, site_free, fx: fx2 })
		} else {
			fx2 = { next: id + 1, inner, live: live.append({ id, path, sub: Engine.is_sub(req) }), queue, max, issued: issued + 1, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }
			(id, { cmds: Engine.put_req(cmds, id, req), next, free, routes, work: Engine.add_work(work, 13, 1), paths, site_free, fx: fx2 })
		}
	}

	## Queue a follow-up turn for `path` with result `res`.
	fx_follow : Tx, List(U32), Res -> (U32, Tx)
	fx_follow = |tx, path, res| {
		id = tx.fx.inner
		(id, Engine.with_fx(tx, |fx| { ..fx, inner: id + 1, queue: fx.queue.append({ id, path, res }) }))
	}

	## Issue a site's requests for value `a`.
	issue : Tx, List(U32), List(Req), a, List(Owned(a)) -> (Tx, List(Owned(a)))
	issue = |tx, path, reqs, a, owned| {
		var $tx = tx
		var $owned = owned
		for req in reqs {
			match req {
				Push(url) => {
					$tx = Engine.emit_op($tx, 15, |c| Engine.put_str(c.append(1), url))
				}
				Replace(url) => {
					$tx = Engine.emit_op($tx, 15, |c| Engine.put_str(c.append(2), url))
				}
				Focus(n) => {
					$tx = Engine.with_fx($tx, |fx| { ..fx, focus: fx.focus.append((1, n)) })
				}
				Blur(n) => {
					$tx = Engine.with_fx($tx, |fx| { ..fx, focus: fx.focus.append((2, n)) })
				}
				SelectText(n) => {
					$tx = Engine.with_fx($tx, |fx| { ..fx, focus: fx.focus.append((3, n)) })
				}
				Title(t) => {
					$tx = Engine.emit_op($tx, 17, |c| Engine.put_str(c, t))
				}
				StorageSet(k, v) => {
					$tx = Engine.emit_op($tx, 16, |c| Engine.put_str(Engine.put_str(c.append(1), k), v))
				}
				StorageRemove(k) => {
					$tx = Engine.emit_op($tx, 16, |c| Engine.put_str(c.append(2), k))
				}
				Self => {
					(id, t1) = Engine.fx_follow($tx, path, Now)
					$tx = t1
					$owned = $owned.append({ id, sub: False, keep: False, a })
				}
				_ => {
					(id, t1) = Engine.fx_admit($tx, path, req)
					$tx = t1
					$owned = $owned.append({ id, sub: Engine.is_sub(req), keep: Engine.is_kept(req), a })
				}
			}
		}
		($tx, $owned)
	}

	## A disposed site's requests (design.md, "Requests, effects, and
	## cancellation"): admitted requests (HTTP, storage read) survive and
	## become orphans that reparent to the nearest surviving ancestor;
	## subscriptions, intervals and timers are stopped (CANCEL) and forgotten;
	## queued follow-ups it would have received are dropped and counted stale.
	fx_dispose : Tx, Reaction(ctx, a), List(Owned(a)) -> (List(Orphan(ctx)), Tx)
	fx_dispose = |tx, react, owned| {
		var $tx = tx
		var $orph = []
		run = react.run
		mask = react.mask
		for o in owned {
			id = o.id
			if $tx.fx.live.any(|l| l.id == id) {
				if o.keep {
					a = o.a
					$orph = $orph.append({ id, run: |e, r| (run(e, a, r), mask, 0) })
				} else {
					t1 = Engine.with_fx($tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id), cancelled: fx.cancelled + 1 })
					$tx = Engine.emit_op(t1, 14, |c| Engine.put_u32(c, id))
				}
			} else if $tx.fx.queue.any(|q| q.id == id) {
				$tx = Engine.with_fx($tx, |fx| { ..fx, queue: fx.queue.keep_if(|q| q.id != id), stale: fx.stale + 1 })
			}
		}
		($orph, $tx)
	}

	## A surviving site takes over orphans: their results now route to it.
	fx_adopt : Tx, List(U32), List(Orphan(ctx)) -> Tx
	fx_adopt = |tx, path, orphans| {
		if orphans.is_empty() {
			tx
		} else {
			ids = orphans.map(|o| o.id)
			Engine.with_fx(
				tx,
				|fx| {
					..fx,
					live: fx.live.map(|l| if (ids.contains(l.id)) { id: l.id, path, sub: l.sub } else l),
					reparented: fx.reparented + ids.len(),
				},
			)
		}
	}

	## An effect result arriving at the site path itself (not below it).
	leaf_fx : List(U32), U64, Payload -> Try(Res, [NotFx])
	leaf_fx = |path, pos, payload| {
		if pos >= path.len() {
			match payload {
				Fx(r) => Ok(r)
				Ev(_) => Err(NotFx)
			}
		} else {
			Err(NotFx)
		}
	}

	## Deliver a result to an adopted orphan: its reaction runs in this
	## site's current environment; writes to retired states are counted as
	## skipped. An id this site does not hold is dropped and counted stale.
	adopt_deliver : List(Orphan(ctx)), ctx, U32, Res, Tx -> (List(Orphan(ctx)), Out(ctx), Tx)
	adopt_deliver = |adopted, env, id, res, tx| {
		match adopted.find_first_index(|o| o.id == id) {
			Ok(i) => {
				o = adopted.get(i) ?? crash "adopted"
				run = o.run
				kept = adopted.drop_at(i)
				(e2, m, sk) = run(env, res)
				(kept, Pending(e2, m), Engine.with_fx(tx, |fx| { ..fx, delivered: fx.delivered + 1, skipped: fx.skipped + sk }))
			}
			Err(_) => (adopted, Pending(env, 0), Engine.fx_count(tx, Stale))
		}
	}

	## Lower orphans through a state or derived layer at `depth` being
	## disposed with final value `v`: the layer is a discarded snapshot.
	lower_in : List(Orphan(In(ctx, s))), s, U64 -> List(Orphan(ctx))
	lower_in = |os, v, depth| {
		keep = Engine.bit(depth) - 1
		os.map(
			|o| {
				run = o.run
				{
					id: o.id,
					run: |e, r| {
						(inner, m, sk) = run(In.{ outer: e, value: v }, r)
						{ outer, value: _ } = inner
						(outer, m.bitwise_and(keep), if (m.bitwise_and(keep.bitwise_not()) != 0) sk + 1 else sk)
					},
				}
			},
		)
	}

	## Lower orphans through a removed row (key and item are snapshots).
	lower_row : List(Orphan(Row(ctx, item))), Str, item, U64 -> List(Orphan(ctx))
	lower_row = |os, key, item, depth| {
		keep = Engine.bit(depth) - 1
		os.map(
			|o| {
				run = o.run
				{
					id: o.id,
					run: |e, r| {
						(row, m, sk) = run(Row.{ outer: e, key, item }, r)
						{ outer, key: _, item: _ } = row
						(outer, m.bitwise_and(keep), if (m.bitwise_and(keep.bitwise_not()) != 0) sk + 1 else sk)
					},
				}
			},
		)
	}

	## Lower orphans through a disposed component: the prop is re-read from
	## the caller's environment, inner writes are discarded (counted), and
	## pushed actions go through the sink as for a live event.
	lower_comp : List(Orphan(Comp(p, a))), Val(ctx, p), Sink(ctx, a) -> List(Orphan(ctx))
	lower_comp = |os, prop, snk| {
		read = prop.read
		srun = snk.run
		os.map(
			|o| {
				run = o.run
				{
					id: o.id,
					run: |e, r| {
						(inner, m, sk) = run(Comp.{ prop: read(e), out: [] }, r)
						{ prop: _, out: actions } = inner
						var $e = e
						var $m = 0.U64
						for act in actions {
							(e2, m2) = srun($e, act)
							$e = e2
							$m = $m.bitwise_or(m2)
						}
						($e, $m, if (m != 0) sk + 1 else sk)
					},
				}
			},
		)
	}

	## Take a site's dropped rows and lower their orphans to the site.
	take_dropped : Cols(Row(ctx, item), item), U64 -> (Cols(Row(ctx, item), item), List(Orphan(ctx)))
	take_dropped = |cols, depth| {
		if cols.dropped.is_empty() {
			(cols, [])
		} else {
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
			var $o = []
			for d in dropped {
				$o = $o.concat(Engine.lower_row(d.orphans, d.key, d.item, depth))
			}
			({ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped: [], rnodes }, $o)
		}
	}

	## An effect site. `initial`: also issue for the value at mount.
	effect : Val(ctx, a), Bool, (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	effect = |v, initial, plan, react| Site(
		Mount(
			|env, args, tx| {
				a = (v.read)(env)
				cfg = { v, plan, react, path: args.path }
				t1 = Engine.count_evals(tx, 1)
				if initial {
					(t2, owned) = Engine.issue(t1, args.path, plan(a), a, [])
					(Engine.effect_inst(cfg, a, owned), Engine.eff_mask(v), t2)
				} else {
					(Engine.effect_inst(cfg, a, []), Engine.eff_mask(v), t1)
				}
			},
		),
		|_| Engine.eff_mask(v),
	)

	## A named cleanup: when the scope this site is mounted in is disposed,
	## `plan` turns the value `v` reads in that scope's last environment into
	## requests, in the disposing turn. Only commands are allowed (history,
	## title, storage writes, focus): a request that awaits a result would
	## outlive its owner, so it is a contract error. Each run is counted by
	## name (`expect-cleanup`). The site renders nothing and reads nothing
	## while it is live.
	on_cleanup : Str, Val(ctx, a), (a -> List(Req)) -> Elem(ctx)
	on_cleanup = |name, v, plan| Site(
		Mount(|_env, _args, tx| (Engine.cleanup_inst(name, v, plan), 0, tx)),
		|_| 0,
	)

	## A cleanup that only counts its runs.
	cleanup : Str -> Elem(ctx)
	cleanup = |name| Engine.on_cleanup(name, Engine.const({}), |_| [])

	cleanup_inst : Str, Val(ctx, a), (a -> List(Req)) -> Inst(ctx)
	cleanup_inst = |name, v, plan| Inst(
		|env, msg, tx| {
			match msg {
				Changed(_) => (Engine.cleanup_inst(name, v, plan), Done, tx)
				Fire(_, _, _, _) => (Engine.cleanup_inst(name, v, plan), Pending(env, 0), tx)
				Dispose(_) => {
					reqs = plan((v.read)(env))
					var $tx = Engine.bump(Engine.count_evals(tx, 1), Engine.w_cleanups, 1)
					for req in reqs {
						if Engine.is_command(req) {
							(t2, _) = Engine.issue($tx, [], [req], {}, [])
							$tx = t2
						} else {
							crash "contract: cleanup \"${name}\" asked for a request that awaits a result; a cleanup may only issue commands"
						}
					}
					(Engine.noop({}), Orphaned([]), Engine.with_fx($tx, |fx| { ..fx, cleanups: Engine.count_name(fx.cleanups, name) }))
				}
			}
		},
	)

	## Requests that are emitted and forgotten.
	is_command : Req -> Bool
	is_command = |req| match req {
		Push(_) | Replace(_) | Title(_) | Focus(_) | Blur(_) | SelectText(_) | StorageSet(_, _) | StorageRemove(_) => True
		_ => False
	}

	count_name : List((Str, U64)), Str -> List((Str, U64))
	count_name = |runs, name| match runs.find_first_index(|(n, _)| n == name) {
		Ok(i) => {
			(_, k) = runs.get(i) ?? crash "internal: cleanup"
			runs.set(i, (name, k + 1)) ?? crash "internal: cleanup"
		}
		Err(_) => runs.append((name, 1))
	}

	## Issue for the value at mount and on every change.
	watch : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch = |v, plan, react| Engine.effect(v, True, plan, react)

	## Issue on every change of the value after mount.
	on_change : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	on_change = |v, plan, react| Engine.effect(v, False, plan, react)

	effect_inst : EffectCfg(ctx, a), a, List(Owned(a)) -> Inst(ctx)
		where [a.is_eq : a, a -> Bool]
	effect_inst = |cfg0, last0, owned0| {
		held = Held({ cfg: cfg0, last: last0, owned: owned0 })
		Inst(
			|env, msg, tx| {
				Held({ cfg, last, owned }) = held
				match msg {
					Changed(mask) => {
						if Engine.eff_mask(cfg.v).bitwise_and(mask) == 0 {
							(Engine.effect_inst(cfg, last, owned), Done, tx)
						} else {
							a = (cfg.v.read)(env)
							t1 = Engine.count_evals(tx, 1)
							if a == last {
								(Engine.effect_inst(cfg, last, owned), Done, t1)
							} else {
								(t2, owned2) = Engine.issue(t1, cfg.path, (cfg.plan)(a), a, owned)
								(Engine.effect_inst(cfg, a, owned2), Done, t2)
							}
						}
					}
					Fire(path, pos, h, payload) => {
						if pos < path.len() {
							(Engine.effect_inst(cfg, last, owned), Pending(env, 0), tx)
						} else {
							match payload {
								Ev(_) => (Engine.effect_inst(cfg, last, owned), Pending(env, 0), tx)
								Fx(res) => Engine.effect_deliver(cfg, last, owned, env, h, res, tx)
							}
						}
					}
					Dispose(_) => {
						(orph, t2) = Engine.fx_dispose(tx, cfg.react, owned)
						(Engine.noop({}), Orphaned(orph), t2)
					}
				}
			},
		)
	}

	effect_deliver : EffectCfg(ctx, a), a, List(Owned(a)), ctx, U32, Res, Tx -> (Inst(ctx), Out(ctx), Tx)
		where [a.is_eq : a, a -> Bool]
	effect_deliver = |cfg, last, owned, env, id, res, tx| {
		match owned.find_first_index(|o| o.id == id) {
			Ok(i) => {
				entry = owned.get(i) ?? crash "owned"
				kept = if (entry.sub) owned else owned.drop_at(i)
				react = cfg.react
				next = Engine.effect_inst(cfg, last, kept)
				(next, Pending((react.run)(env, entry.a, res), react.mask), Engine.fx_count(tx, Delivered))
			}
			Err(_) => (Engine.effect_inst(cfg, last, owned), Pending(env, 0), Engine.fx_count(tx, Stale))
		}
	}

	## Engine counters for effects.
	fx_stats : App -> { issued : U64, delivered : U64, stale : U64, refused : U64, cancelled : U64, live : U64, reparented : U64, skipped : U64 }
	fx_stats = |a| {
		fx = a.tx.fx
		{ issued: fx.issued, delivered: fx.delivered, stale: fx.stale, refused: fx.refused, cancelled: fx.cancelled, live: fx.live.len(), reparented: fx.reparented, skipped: fx.skipped }
	}

	## Ids currently in flight (issue order).
	fx_live : App -> List(U32)
	fx_live = |a| a.tx.fx.live.map(|l| l.id)

	## Decode a host result payload (design.md, Appendix B). A payload that
	## does not follow the encoding (unknown tag, truncated, trailing bytes,
	## text that is not UTF-8) is a contract error: the host broke the
	## protocol, and nothing is guessed.
	decode_res : List(U8) -> Res
	decode_res = |b| {
		tag = b.first() ?? crash "contract: empty effect result"
		text = |n| Str.from_utf8(b.drop_first(n)) ?? crash "contract: effect result text is not UTF-8"
		bare = |r| if (b.len() == 1) r else crash "contract: effect result tag ${tag.to_str()} carries unexpected bytes"
		flag = || match b {
			[_, 0] => Bool.False
			[_, 1] => Bool.True
			_ => crash "contract: effect result tag ${tag.to_str()} needs one byte 0 or 1"
		}
		if tag == 1 {
			if b.len() < 7 {
				crash "contract: truncated HTTP effect result"
			}
			status = (b.get(1) ?? 0).to_u16() + (b.get(2) ?? 0).to_u16().shl_wrap(8)
			n = Engine.get_u32(b, 3, "HTTP effect result").to_u64()
			var $at = 7.U64
			var $hs = []
			var $i = 0.U64
			while $i < n {
				(k, a1) = Engine.get_str(b, $at, "HTTP effect result")
				(v, a2) = Engine.get_str(b, a1, "HTTP effect result")
				$hs = $hs.append((k, v))
				$at = a2
				$i = $i + 1
			}
			Http({ status, headers: $hs, body: text($at) })
		} else if tag == 7 {
			bare(Timeout)
		} else if tag == 2 {
			Network(text(1))
		} else if tag == 3 {
			Value(text(1))
		} else if tag == 4 {
			bare(Missing)
		} else if tag == 5 {
			bare(Fired)
		} else if tag == 6 {
			Location(text(1))
		} else if tag == 8 {
			Online(flag())
		} else if tag == 9 {
			Visible(flag())
		} else {
			crash "contract: unknown effect result tag ${tag.to_str()}"
		}
	}

	## What the host knows before the first render: the URL, the declared
	## storage keys' values (missing keys are absent), whether the browser is
	## online and the page visible, and whether local storage is available at
	## all. When it is not (storage disabled, or every access throws), the
	## storage list is empty and `StorageSet`/`StorageRemove` do not persist,
	## so an app that relies on reloads surviving can say so.
	Boot : { url : Str, storage : List((Str, Str)), online : Bool, visible : Bool, storage_available : Bool }

	get_u32 : List(U8), U64, Str -> U32
	get_u32 = |b, at, what| {
		b0 = (b.get(at) ?? crash "contract: truncated ${what}").to_u32()
		b1 = (b.get(at + 1) ?? crash "contract: truncated ${what}").to_u32()
		b2 = (b.get(at + 2) ?? crash "contract: truncated ${what}").to_u32()
		b3 = (b.get(at + 3) ?? crash "contract: truncated ${what}").to_u32()
		b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
	}

	get_str : List(U8), U64, Str -> (Str, U64)
	get_str = |b, at, what| {
		n = Engine.get_u32(b, at, what).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "contract: truncated ${what}"
		}
		(Str.from_utf8(bytes) ?? crash "contract: ${what} text is not UTF-8", at + 4 + n)
	}

	## Boot bytes: `url:str count:u32 (key:str value:str)* online:u8
	## visible:u8 storage:u8`. Empty bytes mean no boot data (online, visible,
	## storage available). Anything else that does not follow the encoding is
	## a contract error.
	decode_boot : List(U8) -> Boot
	decode_boot = |b| {
		if b.is_empty() {
			{ url: "", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }
		} else {
			(url, a1) = Engine.get_str(b, 0, "boot bytes")
			n = Engine.get_u32(b, a1, "boot bytes").to_u64()
			var $at = a1 + 4
			var $kv = []
			var $i = 0.U64
			while $i < n {
				(k, a2) = Engine.get_str(b, $at, "boot bytes")
				(v, a3) = Engine.get_str(b, a2, "boot bytes")
				$kv = $kv.append((k, v))
				$at = a3
				$i = $i + 1
			}
			flag = |at| match b.get(at) {
				Ok(0) => Bool.False
				Ok(1) => Bool.True
				_ => crash "contract: boot bytes end without online, visible and storage flags (0 or 1)"
			}
			online = flag($at)
			visible = flag($at + 1)
			storage_available = flag($at + 2)
			if b.len() != $at + 3 {
				crash "contract: boot bytes carry ${(b.len() - $at - 3).to_str()} unexpected trailing bytes"
			}
			{ url, storage: $kv, online, visible, storage_available }
		}
	}

	## The value of a boot storage key.
	boot_storage : Boot, Str -> Try(Str, [Missing])
	boot_storage = |boot, key| match boot.storage.find_first(|(k, _)| k == key) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(Missing)
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

	## A focus reference on this element (see Focus/Blur/SelectText).
	ref : Str -> Attr(ctx)
	ref = |name| Ref(name)

	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| On("click", h)

	## ------------------------------------------------------------------
	## The engine state the host holds in one Box.
	App := { root : Inst(Root), tx : Tx }

	new_tx : List(U8) -> Tx
	new_tx = |cmds| { cmds, next: 1, free: [], routes: [], work: Engine.work_zero, paths: [[]], site_free: [], fx: Engine.fx_empty }

	## Mount the application under host node 0 (default effect bound).
	mount : Elem(Root) -> App
	mount = |elem| Engine.mount_with(32, elem)

	## Mount with an in-flight effect bound; runs any follow-up turns the
	## mount queued.
	mount_with : U64, Elem(Root) -> App
	mount_with = |max, elem| {
		{ cmds, next, free, routes, work, paths, site_free, fx } = Engine.new_tx([])
		tx0 = { cmds, next, free, routes, work, paths, site_free, fx: { ..fx, max } }
		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, { cap: 0, local: False }, tx0)
		Engine.drain({ root: Engine.block_inst(block), tx: Engine.flush_focus(tx) })
	}

	## One turn: fire down `path`, then the root's Changed pass, then the
	## turn's focus commands (resolved now, so a reference mounted later in
	## the same turn is found; a missing one is counted stale).
	turn : App, List(U32), U32, Payload -> App
	turn = |{ root, tx }, path, h, payload| {
		(root2, out, tx2) = Engine.call(root, Root, Fire(path, 0, h, payload), Engine.bump(tx, Engine.w_turns, 1))
		mask = Engine.out_mask(out)
		if mask == 0 {
			{ root: root2, tx: Engine.flush_focus(tx2) }
		} else {
			(root3, _, tx3) = Engine.call(root2, Root, Changed(mask), Engine.bump(tx2, Engine.w_dirty_roots, Engine.popcount(mask)))
			{ root: root3, tx: Engine.flush_focus(tx3) }
		}
	}

	## Command 18 FOCUS op:u8 node:u32 (1 focus, 2 blur, 3 select text).
	flush_focus : Tx -> Tx
	flush_focus = |tx| {
		if tx.fx.focus.is_empty() {
			tx
		} else {
			reqs = tx.fx.focus
			var $tx = Engine.with_fx(tx, |fx| { ..fx, focus: [] })
			for (op, name) in reqs {
				match $tx.fx.refs.find_first(|(n, _)| n == name) {
					Ok((_, node)) => {
						$tx = Engine.emit_op($tx, 18, |c| Engine.put_u32(c.append(op), node))
					}
					Err(_) => {
						$tx = Engine.with_fx($tx, |fx| { ..fx, stale: fx.stale + 1 })
					}
				}
			}
			$tx
		}
	}

	## Run queued follow-up turns in order, bounded per host call.
	drain : App -> App
	drain = |app0| {
		var $app = app0
		var $turns = 0.U64
		while !$app.tx.fx.queue.is_empty() {
			if $turns >= Engine.max_turns {
				crash "contract: effect follow-up turns exceeded the per-call budget of 64 (feedback loop)"
			}
			{ root, tx } = $app
			q = tx.fx.queue.first() ?? crash "queue"
			tx1 = Engine.with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_first(1) })
			$app = Engine.turn({ root, tx: tx1 }, q.path, q.id, Fx(q.res))
			$turns = $turns + 1
		}
		$app
	}

	## Deliver an event on host node `node`: a static node (routes table) or a
	## row node (site path + slot, handler number from the template hole).
	## `payload` is the event's value ("" for clicks).
	event : App, U32, U32, Str -> App
	event = |{ root, tx }, node, handler, payload| {
		# O(1): the route gives a static node's block path or a row's site and
		# slot (the site's path + slot). The handler number comes from the host
		# (LISTEN or the template carried it per event name), so an element
		# with several handlers reaches each one. A freed node id has NoRoute.
		target = match tx.routes.get(node.to_u64()) ?? NoRoute {
			NoRoute => Err(Stale)
			Route(path, _) => Ok((path, handler))
			RowOf(site, slot) => {
				match tx.paths.get(site.to_u64()) {
					Ok(path) => if (path.is_empty()) Err(Stale) else Ok((path.append(slot), handler))
					Err(_) => Err(Stale)
				}
			}
		}
		match target {
			Err(Stale) => { root, tx }
			Ok((path, h)) => Engine.drain(Engine.turn({ root, tx }, path, h, Ev(payload)))
		}
	}

	## An effect result from the host: one turn, exactly like an event. An id
	## that is not in flight is dropped and counted (`stale`).
	result : App, U32, Res -> App
	result = |{ root, tx }, id, res| {
		match tx.fx.live.find_first(|l| l.id == id) {
			Err(_) => { root, tx: Engine.fx_count(tx, Stale) }
			Ok(entry) => {
				tx1 = if (entry.sub) tx else Engine.with_fx(tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id) })
				Engine.drain(Engine.turn({ root, tx: tx1 }, entry.path, id, Fx(res)))
			}
		}
	}

	popcount : U64 -> U64
	popcount = |m| {
		var $m = m
		var $n = 0.U64
		while $m != 0 {
			$m = $m.bitwise_and($m - 1)
			$n = $n + 1
		}
		$n
	}

	out_mask : Out(Root) -> U64
	out_mask = |out| match out {
		Pending(_, m) => m
		_ => 0
	}

	## Hand the accumulated commands to the host and take a buffer back.
	take_cmds : App, List(U8) -> (App, List(U8))
	take_cmds = |{ root, tx }, buf| {
		{ cmds, next, free, routes, work, paths, site_free, fx } = tx
		({ root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, fx } }, cmds)
	}

	## Evaluations of app closures so far (work counter `w_evals`).
	evals : App -> U64
	evals = |a| Engine.work_get(a.tx.work, Engine.w_evals)

	## The work counters so far (design.md, "Work assertions"), indexed as
	## the `w_` constants and opcodes describe.
	work_counters : App -> List(U64)
	work_counters = |a| {
		var $out = []
		var $i = 0.U64
		while $i < Engine.w_count {
			$out = $out.append(Engine.work_get(a.tx.work, $i))
			$i = $i + 1
		}
		$out
	}

	## The wire protocol version this engine speaks (design.md, Appendix B).
	## The host exports it, the runtime refuses an instance whose version it
	## does not implement, and the test oracle checks it too.
	protocol_version : U32
	protocol_version = 3

	## The host-facing program: the protocol version, the declared storage
	## keys (read by the host before mount), mount once with the boot bytes,
	## then one transaction per event or effect result.
	##
	## Each call returns the state, the command batch and the work record
	## (`work_bytes`). The caller lends both buffers back on the next call so
	## they are reused in place.
	Program(state) : {
		version : U32,
		keys : () -> List(U8),
		init : List(U8) -> (state, List(U8), List(U8)),
		event : state, List(U8), List(U8), U32, U32, List(U8) -> (state, List(U8), List(U8)),
	}

	program : (() -> Elem(Root)) -> Program(App)
	program = |view| Engine.program_boot({ storage_keys: [], max_inflight: 32 }, |_| view())

	program_boot : { storage_keys : List(Str), max_inflight : U64 }, (Boot -> Elem(Root)) -> Program(App)
	program_boot = |cfg, view| {
		version: Engine.protocol_version,
		keys: || {
			var $b = Engine.put_u32([], cfg.storage_keys.len().to_u32_wrap())
			for k in cfg.storage_keys {
				$b = Engine.put_str($b, k)
			}
			$b
		},
		init: |boot| Engine.finish(Engine.mount_with(cfg.max_inflight, view(Engine.decode_boot(boot))), [], []),
		event: |inst, buf, wbuf, node, handler, payload| {
			{ root, tx } = inst
			{ cmds: _, next, free, routes, work, paths, site_free, fx } = tx
			fresh = { root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, fx } }
			if node == Engine.fx_node {
				Engine.finish(Engine.result(fresh, handler, Engine.decode_res(payload)), [], wbuf)
			} else {
				Engine.finish(Engine.event(fresh, node, handler, Str.from_utf8(payload) ?? crash "contract: event payload is not UTF-8"), [], wbuf)
			}
		},
	}

	## Hand over the command batch (taking `buf` in its place) and write the
	## work record into `wbuf`.
	finish : App, List(U8), List(U8) -> (App, List(U8), List(U8))
	finish = |inst, buf, wbuf| {
		w = Engine.work_bytes(inst, wbuf)
		(a2, cmds) = Engine.take_cmds(inst, buf)
		(a2, cmds, w)
	}

	## The work record (design.md, Appendix B): `count:u32 (counter:u64)*`
	## in `w_` index order, then `n:u32 (name:str runs:u64)*` for the
	## cleanups that have run. Written into `buf`, which is cleared first.
	work_bytes : App, List(U8) -> List(U8)
	work_bytes = |inst, buf| {
		counters = inst.tx.work
		var $b = Engine.put_u32(buf.clear(), Engine.w_count.to_u32_wrap())
		var $i = 0.U64
		while $i < Engine.w_count {
			$b = Engine.put_u64($b, Engine.work_get(counters, $i))
			$i = $i + 1
		}
		runs = inst.tx.fx.cleanups
		$b = Engine.put_u32($b, runs.len().to_u32_wrap())
		for (name, k) in runs {
			$b = Engine.put_u64(Engine.put_str($b, name), k)
		}
		$b
	}

	put_u64 : List(U8), U64 -> List(U8)
	put_u64 = |buf, v| Engine.put_u32(Engine.put_u32(buf, v.to_u32_wrap()), v.shr_zf_wrap(32).to_u32_wrap())
}
