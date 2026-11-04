"""Move each_inst's nested-kid event route into its own function that takes
the columns owned, and return the row environment's outer part through a
separate function (so no matched value outlives the rebuild)."""
import sys
p = sys.argv[1]
s = open(p).read()
a = """						} else {
							j = (path.get(pos + 1) ?? 0).to_u64()
							{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask } = cols
							{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
							if j < row_kids.len() {
								{ list: rl, prev: kid } = row_kids.replace(j, Engine.noop({})) ?? crash "kid"
								(k2, out, t2) = Engine.call(kid, row_env, Fire(path, pos + 2, h, payload), tx)
								kids2 = kl.set(si, rl.set(j, k2) ?? crash "kid") ?? crash "kids"
								cols2 = { items, keys, order, free, index, lasts, kids: kids2, binds, pend, dirty, sels, known, kid_mask }
								match out {
									Pending(e2, m) => {
										{ outer, key: _, item: _ } = e2
										(Engine.each_inst(cfg, rows, cols2), Pending(outer, m), t2)
									}
									Done => crash "fire must hand the environment back"
								}
							} else {
								cols2 = { items, keys, order, free, index, lasts, kids: kl.set(si, row_kids) ?? crash "kids", binds, pend, dirty, sels, known, kid_mask }
								{ outer, key: _, item: _ } = row_env
								(Engine.each_inst(cfg, rows, cols2), Pending(outer, 0), tx)
							}
						}"""
b = """						} else {
							(cols2, outer, m, t2) = Engine.each_fire_kid(cols, row_env, si, path, pos, h, payload, tx)
							(Engine.each_inst(cfg, rows, cols2), Pending(outer, m), t2)
						}"""
assert s.count(a) == 1
s = s.replace(a, b)
helper = """	## Route an event into nested site `path[pos + 1]` of row slot `si`.
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

	each_inst : EachCfg"""
s = s.replace("	each_inst : EachCfg", helper, 1)
open(p, 'w').write(s)
