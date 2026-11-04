"""Give every dynamic site a conservative static read mask, so a row (or a
block) listens only to the layers its nested sites can read, instead of every
enclosing layer."""
import sys
p = sys.argv[1]
s = open(p).read()

def rep(a, b, n=1):
    global s
    c = s.count(a)
    assert c == n, (a[:70], c)
    s = s.replace(a, b)

rep("\t\tSite(Mount(ctx)),\n", "\t\t## A dynamic site and its conservative read mask, given the depth the\n\t\t## site is mounted at (computed without mounting it).\n\t\tSite(Mount(ctx), (U64 -> U64)),\n")
rep("\t\t\tSite(Mount(mount)) => {", "\t\t\tSite(Mount(mount), _) => {")
# compile: Plan gets kreads, compile_elem gets depth
rep("""		mounts : List(Mount(ctx)),
		ncols : U64,
	}""", """		mounts : List(Mount(ctx)),
		ncols : U64,
		kreads : U64,
	}""")
rep("plan_empty = |_| { tree: [], htab: [], holes: [], handlers: [], mounts: [], ncols: 0 }", "plan_empty = |_| { tree: [], htab: [], holes: [], handlers: [], mounts: [], ncols: 0, kreads: 0 }")
rep("""	val_hole = |{ tree, htab, holes, handlers, mounts, ncols }, kind, v, extra| {""", """	val_hole = |{ tree, htab, holes, handlers, mounts, ncols, kreads }, kind, v, extra| {""")
rep("""		{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if live ncols + 1 else ncols }""", """		{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if live ncols + 1 else ncols, kreads }""")
rep("""	compile_elem : Plan(ctx), Elem(ctx), List(U8) -> Plan(ctx)
	compile_elem = |plan, elem, path| {""", """	compile_elem : Plan(ctx), Elem(ctx), List(U8), U64 -> Plan(ctx)
	compile_elem = |plan, elem, path, depth| {""")
rep("""				{ tree, htab, holes, handlers, mounts, ncols } = $p""", """				{ tree, htab, holes, handlers, mounts, ncols, kreads } = $p""")
rep("""							r = Engine.val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols }, 2, v,""", """							r = Engine.val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, 2, v,""")
rep("""				$p = { tree: $tree, htab: $htab, holes: $holes, handlers: $handlers, mounts, ncols: $ncols }""", """				$p = { tree: $tree, htab: $htab, holes: $holes, handlers: $handlers, mounts, ncols: $ncols, kreads }""")
rep("""					$p = Engine.compile_elem($p, kid, path.append($i))""", """					$p = Engine.compile_elem($p, kid, path.append($i), depth)""")
rep("""			Text(s) => {
				{ tree, htab, holes, handlers, mounts, ncols } = plan
				{ tree: Engine.put_str(tree.append(2), s), htab, holes, handlers, mounts, ncols }
			}
			TextV(v) => {
				{ tree, htab, holes, handlers, mounts, ncols } = plan
				t2 = Engine.put_str(tree.append(2), "")
				Engine.val_hole({ tree: t2, htab, holes, handlers, mounts, ncols }, 1, v, Engine.put_path([], 1, path))
			}
			Site(m) => {
				{ tree, htab, holes, handlers, mounts, ncols } = plan
				hole = { kind: 4, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: mounts.len(), live: False }
				{ tree: Engine.put_str(tree.append(2), ""), htab: Engine.put_path(htab, 4, path), holes: holes.append(hole), handlers, mounts: mounts.append(m), ncols }
			}""", """			Text(s) => {
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
			}""")
rep("""	compile : Elem(ctx) -> Plan(ctx)
	compile = |elem| {
		match elem {
			Element(_, _, _) => Engine.compile_elem(Engine.plan_empty({}), elem, [])""", """	compile : Elem(ctx), U64 -> Plan(ctx)
	compile = |elem, depth| {
		match elem {
			Element(_, _, _) => Engine.compile_elem(Engine.plan_empty({}), elem, [], depth)""")

# elem_reads, placed before the constructors
rep("""	## ------------------------------------------------------------------
	## Application-facing constructors.
""", """	## ------------------------------------------------------------------
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
""")
rep("""	state = |init, body| Site(Mount(|env, args, tx| {
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
		reads = block.reads
		(Engine.state_inst(init, block, depth), reads, tx1)
	}))""", """	state = |init, body| Site(
		Mount(|env, args, tx| {
			depth = args.depth + 1
			elem = body(Engine.state_handle(depth))
			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, tx)
			reads = block.reads
			(Engine.state_inst(init, block, depth), reads, tx1)
		}),
		|d| Engine.elem_reads(body(Engine.state_handle(d + 1)), d + 1).bitwise_and(Engine.bit(d + 1) - 1),
	)""")
rep("""	each = |rows, key, template| Site(Mount(|env, args, tx| {
		depth = args.depth + 1
		row_bit = Engine.bit(depth)
		plan = Engine.compile(template(RowRef.{ depth }))""", """	each = |rows, key, template| Site(Mount(|env, args, tx| {
		depth = args.depth + 1
		row_bit = Engine.bit(depth)
		plan = Engine.compile(template(RowRef.{ depth }), depth)""")
rep("""		# A dynamic template's nested sites may read any enclosing layer (rows
		# mounted later included), so the site listens to all of them.
		reads = if dynamic row_bit - 1 else Engine.eff_mask(rows).bitwise_or(outer_mask).bitwise_or(smask_all)
		(Engine.each_inst(cfg, rows, cols), reads, tx4)
	}))""", """		# Nested sites in the template report their static reads (kreads),
		# which also covers rows mounted later.
		reads = Engine.eff_mask(rows).bitwise_or(outer_mask).bitwise_or(smask_all).bitwise_or(plan.kreads.bitwise_and(row_bit - 1))
		(Engine.each_inst(cfg, rows, cols), reads, tx4)
	}), |d| Engine.eff_mask(rows).bitwise_or(Engine.elem_reads(template(RowRef.{ depth: d + 1 }), d + 1).bitwise_and(Engine.bit(d + 1) - 1)))""")
rep("""		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, Engine.count_evals(tx2, 1))
		# The other branch may read layers this one does not: listen to all.
		reads = Engine.upto(args.depth)
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path }
		(Engine.when_inst(w, c, block), reads, tx3)
	}))""", """		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, Engine.count_evals(tx2, 1))
		# Listen to the condition, this branch, and what the other branch
		# would read once mounted.
		other = if c no() else yes()
		reads = Engine.eff_mask(cond).bitwise_or(block.reads).bitwise_or(Engine.elem_reads(other, args.depth))
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path }
		(Engine.when_inst(w, c, block), reads, tx3)
	}), |d| Engine.eff_mask(cond).bitwise_or(Engine.elem_reads(yes(), d)).bitwise_or(Engine.elem_reads(no(), d)))""")
rep("""		reads = block.reads.bitwise_and(Engine.bit(depth) - 1).bitwise_or(Engine.eff_mask(input))
		(Engine.derive_inst(input, v, block, depth), reads, tx1)
	}))""", """		reads = block.reads.bitwise_and(Engine.bit(depth) - 1).bitwise_or(Engine.eff_mask(input))
		(Engine.derive_inst(input, v, block, depth), reads, tx1)
	}), |d| Engine.eff_mask(input).bitwise_or(Engine.elem_reads(body({ mask: Engine.bit(d + 1), read: |e| e.value, sel: NoSel }), d + 1).bitwise_and(Engine.bit(d + 1) - 1)))""")
rep("""		(Engine.comp_inst(prop, snk, block), Engine.eff_mask(prop), tx1)
	}))""", """		(Engine.comp_inst(prop, snk, block), Engine.eff_mask(prop), tx1)
	}), |_| Engine.eff_mask(prop))""")
open(p, 'w').write(s)
