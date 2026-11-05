Repro := [].{
	Inst(ctx) := [Inst((ctx, U8 -> Inst(ctx)))]

	inst : (ctx -> List(item)), List(item) -> Inst(ctx)
		where [item.is_eq : item, item -> Bool]
	inst = |read, items| Inst(
		|_env, n| match n {
			0 => {
				_c0 = Repro.inst(read, items)
				_c1 = Repro.inst(read, items)
				_c2 = Repro.inst(read, items)
				_c3 = Repro.inst(read, items)
				Repro.inst(read, items)
			}
			_ => {
				_c0 = Repro.inst(read, items)
				_c1 = Repro.inst(read, items)
				_c2 = Repro.inst(read, items)
				_c3 = Repro.inst(read, items)
				Repro.inst(read, items)
			}
		},
	)

	each : (ctx -> List(item)) -> (ctx -> Inst(ctx))
		where [item.is_eq : item, item -> Bool]
	each = |read| |env| Repro.inst(read, read(env))

	Item : { title : Str }

	col : (ctx -> List(Item)) -> (ctx -> Inst(ctx))
	col = |rows| {
		# Deleting this unused closure makes the check take 0.01 s.
		_unused = |_x| rows
		Repro.each(rows)
	}

	view : ({} -> Inst({}))
	view = Repro.col(|_| [])
}
