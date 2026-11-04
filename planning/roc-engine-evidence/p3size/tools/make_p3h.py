"""make_p3h.py P -- Engine.p3h.roc from Engine.p3e.roc: every typed closure that crosses
an erased call is pre-boxed once (reads, selector keys, handlers, row key and rows read),
the per-site entry points (block hole refresh, each Changed) are boxed once per mount,
so each per-site typed body is specialised once and no per-call closure conversion
allocates."""
import sys
P = sys.argv[1]
s = open(P + "/src/Engine.p3e.roc").read()
def rep(a, b, count=1):
    global s
    n = s.count(a)
    assert n >= 1, "missing: " + a[:90]
    if count == 0: s = s.replace(a, b)
    else:
        assert n == count, f"{n} occurrences of: " + a[:90]
        s = s.replace(a, b)
rep("	Read(ctx) : { read : (ctx -> Str), skey : (ctx -> Str) }",
"""	## Typed closures are boxed once when the element is built, so they can be
	## passed through erased per-site entry points without conversion.
	Read(ctx) : { read : Box((ctx -> Str)), skey : [NoKey, Key(Box((ctx -> Str)))] }

	HandlerB(ctx) : { mask : U64, run : Box((ctx -> ctx)) }

	skey_of : Read(ctx), ctx -> Str
	skey_of = |r, env| match r.skey {
		NoKey => ""
		Key(b) => (Box.unbox(b))(env)
	}""")
rep("	Elem(ctx) := { ops : List(Op), reads : List(Read(ctx)), handlers : List(Handler(ctx)), mounts : List(Mount(ctx)) }",
    "	Elem(ctx) := { ops : List(Op), reads : List(Read(ctx)), handlers : List(HandlerB(ctx)), mounts : List(Mount(ctx)) }")
rep("""		NoSel => ({ read, skey: |_| "" }, mask, 0)
		Sel(m, k) => ({ read, skey: k }, mask, m)""", """		NoSel => ({ read: Box.box(read), skey: NoKey }, mask, 0)
		Sel(m, k) => ({ read: Box.box(read), skey: Key(Box.box(k)) }, mask, m)""")
rep("""				AOn(h) => {
					$ops = $ops.append(OnA)
					$hs = $hs.append(h)
				}""", """				AOn(h) => {
					$ops = $ops.append(OnA)
					$hs = $hs.append({ mask: h.mask, run: Box.box(h.run) })
				}""")
rep("(r.read)(env)", "(Box.unbox(r.read))(env)", 0)
rep("(r.read)(row_env)", "(Box.unbox(r.read))(row_env)", 0)
rep("(r.skey)(row_env)", "Engine.skey_of(r, row_env)", 0)
rep("(r.skey)(probe)", "Engine.skey_of(r, probe)", 0)
rep("(handler.run)(env)", "(Box.unbox(handler.run))(env)", 0)
rep("(handler.run)(row_env)", "(Box.unbox(handler.run))(row_env)", 0)
# blocks
rep("	TBlock(ctx) : { core : Core, reads : List(Read(ctx)), handlers : List(Handler(ctx)), kids : List(Inst(ctx)) }",
"""	TBlock(ctx) := {
		core : Core,
		reads : List(Read(ctx)),
		handlers : List(HandlerB(ctx)),
		kids : List(Inst(ctx)),
		holes : Box((Core, List(Read(ctx)), ctx, U64, Tx -> (Core, Tx))),
	}""")
rep("		({ core: $core, reads, handlers, kids: $kids }, $tx)\n\t}\n\n\trefresh :",
    "		({ core: $core, reads, handlers, kids: $kids, holes: Box.box(Engine.refresh_holes) }, $tx)\n\t}\n\n\trefresh :")
rep("""	refresh : TBlock(ctx), ctx, U64, Tx -> (TBlock(ctx), Tx)
	refresh = |{ core, reads, handlers, kids }, env, mask, tx| {
		var $core = core
		var $tx = tx""", """	refresh : TBlock(ctx), ctx, U64, Tx -> (TBlock(ctx), Tx)
	refresh = |{ core, reads, handlers, kids, holes }, env, mask, tx| {
		(c1, t1) = (Box.unbox(holes))(core, reads, env, mask, tx)
		var $tx = t1
		var $kids = kids
		var $j = 0.U64
		while $j < $kids.len() {
			if Engine.kid_hit(c1, $j, mask) {
				{ list, prev } = $kids.replace($j, Engine.noop({})) ?? crash "child"
				(next, _, t2) = Engine.call(prev, env, Changed(mask), $tx)
				$kids = list.set($j, next) ?? crash "child"
				$tx = t2
			}
			$j = $j + 1
		}
		({ core: c1, reads, handlers, kids: $kids, holes }, $tx)
	}

	## The hole half of a refresh, boxed once per mounted block.
	refresh_holes : Core, List(Read(ctx)), ctx, U64, Tx -> (Core, Tx)
	refresh_holes = |core, reads, env, mask, tx| {
		var $core = core
		var $tx = tx""")
rep("""			$i = $i + 1
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
	}""", """			$i = $i + 1
		}
		($core, $tx)
	}""")
rep("""			{ core, reads, handlers, kids } = block
			match kids.replace(k, Engine.noop({})) {
				Ok({ list, prev }) => {
					(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
					({ core, reads, handlers, kids: list.set(k, next) ?? crash "child" }, out, tx1)
				}
				Err(_) => ({ core, reads, handlers, kids }, Pending(env, 0), tx)""", """			{ core, reads, handlers, kids, holes } = block
			match kids.replace(k, Engine.noop({})) {
				Ok({ list, prev }) => {
					(next, out, tx1) = Engine.call(prev, env, Fire(path, pos + 1, h), tx)
					({ core, reads, handlers, kids: list.set(k, next) ?? crash "child", holes }, out, tx1)
				}
				Err(_) => ({ core, reads, handlers, kids, holes }, Pending(env, 0), tx)""")
rep("	dispose_block = |{ core, reads: _, handlers: _, kids }, env, remove, tx| {", "	dispose_block = |{ core, reads: _, handlers: _, kids, holes: _ }, env, remove, tx| {")
rep("		reads = block.core.reads\n", "		reads = block.core.reads\n")
# each
rep("	EachT(ctx, item) : { rows : Val(ctx, List(item)), key : (item -> Str), reads : List(Read(Row(ctx, item))), handlers : List(Handler(Row(ctx, item))) }",
"""	EachT(ctx, item) := {
		rows_mask : U64,
		rows : Box((ctx -> List(item))),
		key : Box((item -> Str)),
		reads : List(Read(Row(ctx, item))),
		handlers : List(HandlerB(Row(ctx, item))),
		changed : Box((EachT(ctx, item), EachCore, List(item), ctx, U64, Tx -> (EachCore, List(item), Tx))),
	}""")
rep("			key = (t.key)(item)", "			key = (Box.unbox(t.key))(item)")
rep("		(c3, it3, t1) = if Engine.eff_mask(t.rows).bitwise_and(mask) != 0 {\n			Engine.each_rows(t, c2, items, env, (t.rows.read)(env), Engine.count_evals(tx, 1))",
    "		(c3, it3, t1) = if t.rows_mask.bitwise_and(mask) != 0 {\n			Engine.each_rows(t, c2, items, env, (Box.unbox(t.rows))(env), Engine.count_evals(tx, 1))")
rep("				(c4, it4, t4) = Engine.each_changed(t, core, items, env, mask, tx)", "				(c4, it4, t4) = (Box.unbox(t.changed))(t, core, items, env, mask, tx)")
rep("		t = { rows, key, reads, handlers }", "		t = { rows_mask: Engine.eff_mask(rows), rows: Box.box(rows.read), key: Box.box(key), reads, handlers, changed: Box.box(Engine.each_changed) }")
s = s.replace("## Phase 3 size spike (p3e)", "## Phase 3 size spike (p3h)", 1)
open(P + "/src/Engine.p3h.roc", "w").write(s)
