"""Thread a read-mask cap through mounting: inside an each row, nested sites
report the row template's static reads (plus every deeper layer) instead of
building the branches they are not showing to compute exact reads."""
import sys
p = sys.argv[1]
s = open(p).read()

def rep(a, b, n=1):
    global s
    c = s.count(a)
    assert c == n, (a[:70], c)
    s = s.replace(a, b)

rep("	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool }",
    "	## `cap` != 0: a known superset of what the site can read; the site may\n	## report it instead of computing its reads (set inside each rows).\n	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64 }")
rep("	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, Tx -> (Block(ctx), Tx)\n	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, tx| {",
    "	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, U64, Tx -> (Block(ctx), Tx)\n	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, cap, tx| {")
rep("					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, $t)",
    "					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, cap, $t)")
rep("				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top }, tx)",
    "				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap }, tx)")
rep("	mount_block = |env, elem, depth, path, parent, before, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, tx)",
    "	mount_block = |env, elem, depth, path, parent, before, cap, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, cap, tx)")
s = s.replace("	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Tx -> (Block(ctx), Tx)",
              "	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, U64, Tx -> (Block(ctx), Tx)")
rep("						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, t2)",
    "						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, w.cap, t2)")
rep("				(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False }, $tx)",
    "				(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False, cap: cfg.plan.kreads.bitwise_or(Engine.upto(cfg.depth).bitwise_not()) }, $tx)")
# state / derive keep the cap (their inner layers are deeper bits, already in the cap)
rep("			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, tx)",
    "			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, args.cap, tx)")
rep("		(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, Engine.count_evals(tx, 1))",
    "		(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, args.cap, Engine.count_evals(tx, 1))")
# a component restarts depth at 0: no cap inside
rep("		(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, Engine.count_evals(tx, 1))",
    "		(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, 0, Engine.count_evals(tx, 1))")
rep("		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, Engine.new_tx([]))",
    "		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, 0, Engine.new_tx([]))")
rep("""		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, Engine.count_evals(tx2, 1))
		# Listen to the condition, this branch, and what the other branch
		# would read once mounted.
		other = if c no() else yes()
		reads = Engine.eff_mask(cond).bitwise_or(block.reads).bitwise_or(Engine.elem_reads(other, args.depth))
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path }""",
    """		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, args.cap, Engine.count_evals(tx2, 1))
		# Listen to the condition, this branch, and what the other branch
		# would read once mounted (or the cap, when the parent knows it).
		reads = if args.cap != 0 {
			args.cap
		} else {
			other = if c no() else yes()
			Engine.eff_mask(cond).bitwise_or(block.reads).bitwise_or(Engine.elem_reads(other, args.depth))
		}
		w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap }""")
rep("	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32) }",
    "	When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64 }")
open(p, 'w').write(s)
