"""assemble_p3e.py -- build src/Engine.p3e.roc from Engine.p3a.roc plus src/parts/{tx,each}.roc."""
import sys
P = sys.argv[1]
a = open(P + "/src/Engine.p3a.roc").read()
tx = open(P + "/src/parts/tx.roc").read()
each = open(P + "/src/parts/each.roc").read()
SEP = "\t## ------------------------------------------------------------------\n"
head = a[:a.index("\tTx : {")]
blocks = a[a.index(SEP + "\t## Untyped block core."):a.index(SEP + "\t## The each core: one untyped record per site.")]
tail = a[a.index(SEP + "\t## Application-facing constructors."):]
def rep(s, x, y):
    assert x in s, x[:80]
    return s.replace(x, y, 1)
tail = rep(tail, """		(core, tx1) = Engine.each_core_new(ops, args, depth, tx)
		t = { rows, key, reads, handlers }
		list = (rows.read)(env)
		(core2, items, tx2) = Engine.append_rows(t, core, [], env, list, 0, Engine.count_evals(tx1, 1))""", """		(core, tx1) = Engine.each_core_new(ops, args, depth, tx)
		t = { rows, key, reads, handlers }
		(core2, items, tx2) = Engine.each_rows(t, core, [], env, (rows.read)(env), Engine.count_evals(tx1, 1))""")
tail = rep(tail, "	new_tx = |cmds| { cmds, next: 1, free: [], routes: [], evals: 0, paths: [[]], site_free: [] }",
                 "	new_tx = |cmds| { cmds, evals: 0, ids: [{ next: 1, free: [], routes: [], paths: [[]], site_free: [] }] }")
tail = rep(tail, """		sid = node.shr_zf_wrap(20)
		target = if sid == 0 {
			match tx.routes.get(node.to_u64()) ?? NoRoute {""", """		sid = node.shr_zf_wrap(20)
		d = tx.ids.get(0) ?? Engine.ids_empty
		target = if sid == 0 {
			match d.routes.get(node.to_u64()) ?? NoRoute {""")
tail = rep(tail, "			match tx.paths.get(sid.to_u64()) {", "			match d.paths.get(sid.to_u64()) {")
tail = rep(tail, """		{ cmds, next, free, routes, evals, paths, site_free } = tx
		({ root, tx: { cmds: buf.clear(), next, free, routes, evals, paths, site_free } }, cmds)""", """		{ cmds, evals, ids } = tx
		({ root, tx: { cmds: buf.clear(), evals, ids } }, cmds)""")
tail = rep(tail, """			{ cmds: _, next, free, routes, evals: ev, paths, site_free } = tx
			fresh = { root, tx: { cmds: buf.clear(), next, free, routes, evals: ev, paths, site_free } }""", """			{ cmds: _, evals: ev, ids } = tx
			fresh = { root, tx: { cmds: buf.clear(), evals: ev, ids } }""")
out = head + tx + blocks + each + tail
out = out.replace("## Phase 3 size spike: the Phase 2 unified engine", "## Phase 3 size spike (p3e): the Phase 2 unified engine", 1)
open(P + "/src/Engine.p3e.roc", "w").write(out)
