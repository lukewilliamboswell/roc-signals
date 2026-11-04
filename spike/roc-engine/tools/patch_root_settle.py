"""Settle at the root. A state outside rows and components no longer
refreshes its subtree while the event's call frames are still active: it
hands its layer's bit up, and the root runs one Changed pass after Fire
returns. States inside each rows or components (whose layers the root cannot
reach by mask) still refresh locally (`local`)."""
import sys
p = sys.argv[1]
s = open(p).read()

def rep(a, b, n=1):
    global s
    c = s.count(a)
    assert c == n, (a[:80], c)
    s = s.replace(a, b)

rep("	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64 }",
    "	## `local`: the site is inside an each row or a component, where the\n	## root's Changed pass cannot reach its layers by mask.\n	Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64, local : Bool }\n\n	Scope : { cap : U64, local : Bool }")
rep("	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, U64, Tx -> (Block(ctx), Tx)\n	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, cap, tx| {",
    "	mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, Scope, Tx -> (Block(ctx), Tx)\n	mount_elem = |block, env, elem, depth, path, parent, before, top, sole, scope, tx| {")
rep("					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, cap, $t)",
    "					(b3, t3) = Engine.mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, scope, $t)")
rep("				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap }, tx)",
    "				(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap: scope.cap, local: scope.local }, tx)")
rep("	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, U64, Tx -> (Block(ctx), Tx)\n	mount_block = |env, elem, depth, path, parent, before, cap, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, cap, tx)",
    "	mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Scope, Tx -> (Block(ctx), Tx)\n	mount_block = |env, elem, depth, path, parent, before, scope, tx| Engine.mount_elem(Engine.empty_block({}), env, elem, depth, path, parent, before, True, False, scope, tx)")
rep("						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, w.cap, t2)",
    "						(b3, t3) = Engine.mount_block(env, elem, w.depth, w.path, 0, w.anchor, { cap: w.cap, local: w.local }, t2)")
rep("sole: False, cap: cfg.plan.kreads.bitwise_or(Engine.upto(cfg.depth).bitwise_not()) }, $tx)",
    "sole: False, cap: cfg.plan.kreads.bitwise_or(Engine.upto(cfg.depth).bitwise_not()), local: True }, $tx)")
rep("			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, args.cap, tx)\n			reads = block.reads\n			(Engine.state_inst(init, block, depth), reads, tx1)",
    "			(block, tx1) = Engine.mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, tx)\n			reads = block.reads\n			(Engine.state_inst(init, block, depth, args.local), reads, tx1)")
rep("		(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, args.cap, Engine.count_evals(tx, 1))",
    "		(block, tx1) = Engine.mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, Engine.count_evals(tx, 1))")
rep("		(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, 0, Engine.count_evals(tx, 1))",
    "		(block, tx1) = Engine.mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, { cap: 0, local: True }, Engine.count_evals(tx, 1))")
rep("		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, 0, Engine.new_tx([]))",
    "		(block, tx) = Engine.mount_block(Root, elem, 0, [], 0, 0, { cap: 0, local: False }, Engine.new_tx([]))")
rep("		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, args.cap, Engine.count_evals(tx2, 1))",
    "		(block, tx3) = Engine.mount_block(env, elem, args.depth, args.path, 0, anchor, { cap: args.cap, local: args.local }, Engine.count_evals(tx2, 1))")
rep("		w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap }",
    "		w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap, local: args.local }")
rep("path : List(U32), cap : U64 }", "path : List(U32), cap : U64, local : Bool }")

# state_inst / state_settle carry `local`
rep("	state_settle : Block(In(ctx, s)), U64, Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)\n	state_settle = |block, depth, out, tx| {",
    "	state_settle : Block(In(ctx, s)), U64, Bool, Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)\n	state_settle = |block, depth, local, out, tx| {")
rep("""				if above != 0 or mask.bitwise_and(own) == 0 {
					# An outer layer changed (it will refresh us), or the change
					# was handled below.
					(Engine.state_inst(s2, block, depth), Pending(next_outer, mask), tx)
				} else {
					(b3, t3) = Engine.refresh(block, In.{ outer: next_outer, value: s2 }, own, tx)
					(Engine.state_inst(s2, b3, depth), Pending(next_outer, 0), t3)
				}""", """				if !local or above != 0 or mask.bitwise_and(own) == 0 {
					# Hand the change up: the root (or the outer layer that
					# changed) runs the Changed pass once the event has unwound.
					(Engine.state_inst(s2, block, depth, local), Pending(next_outer, mask), tx)
				} else {
					(b3, t3) = Engine.refresh(block, In.{ outer: next_outer, value: s2 }, own, tx)
					(Engine.state_inst(s2, b3, depth, local), Pending(next_outer, 0), t3)
				}""")
rep("	state_inst : s, Block(In(ctx, s)), U64 -> Inst(ctx)\n	state_inst = |s0, block0, depth0| {\n		held = Held({ s: s0, block: block0, depth: depth0 })",
    "	state_inst : s, Block(In(ctx, s)), U64, Bool -> Inst(ctx)\n	state_inst = |s0, block0, depth0, local0| {\n		held = Held({ s: s0, block: block0, depth: depth0, local: local0 })")
rep("			Held({ s, block, depth }) = held", "			Held({ s, block, depth, local }) = held")
rep("					(Engine.state_inst(s, b2, depth), Done, t2)", "					(Engine.state_inst(s, b2, depth, local), Done, t2)")
rep("						Leaf => Engine.state_settle(block, depth, Engine.fire_leaf(",
    "						Leaf => Engine.state_settle(block, depth, local, Engine.fire_leaf(")
rep("							Engine.state_settle(b2, depth, out, t2)", "							Engine.state_settle(b2, depth, local, out, t2)")
rep("						Miss => Engine.state_settle(block, depth, Pending(", "						Miss => Engine.state_settle(block, depth, local, Pending(")

# root: one Changed pass after Fire
rep("""				(root2, _, tx2) = Engine.call(root, Root, Fire(path, 0, h, payload), tx)
				{ root: root2, tx: tx2 }""", """				(root2, out, tx2) = Engine.call(root, Root, Fire(path, 0, h, payload), tx)
				mask = Engine.out_mask(out)
				if mask == 0 {
					{ root: root2, tx: tx2 }
				} else {
					(root3, _, tx3) = Engine.call(root2, Root, Changed(mask), tx2)
					{ root: root3, tx: tx3 }
				}""")
rep("""	## Hand the accumulated commands to the host and take a buffer back.""", """	out_mask : Out(Root) -> U64
	out_mask = |out| match out {
		Pending(_, m) => m
		Done => 0
	}

	## Hand the accumulated commands to the host and take a buffer back.""")
open(p, 'w').write(s)
