Engine := {}.{
	
	## A typed four-node diamond, stored in columns rather than erased node cells.
	## This tests storage and specialization; topology is fixed, not a general DAG.
	Ops(a, b, c, d) : { left : a -> b, right : a -> c, join : b, c -> d }
	Row(a, b, c, d) : { source : a, ops : Ops(a, b, c, d) }
	Graph(a, b, c, d) : {
		sources : List(a),
		lefts : List(b),
		rights : List(c),
		outputs : List(d),
		operations : List(Ops(a, b, c, d)),
		work : { calls : U64, prunes : U64, emitted : U64 },
	}
	
	create : List(Row(a, b, c, d)) -> Graph(a, b, c, d)
	create = |rows| {
		var $sources = List.with_capacity(rows.len())
		var $lefts = List.with_capacity(rows.len())
		var $rights = List.with_capacity(rows.len())
		var $outputs = List.with_capacity(rows.len())
		var $operations = List.with_capacity(rows.len())
		for { source, ops } in rows {
			left = (ops.left)(source)
			right = (ops.right)(source)
			$sources = $sources.append(source)
			$lefts = $lefts.append(left)
			$rights = $rights.append(right)
			$outputs = $outputs.append((ops.join)(left, right))
			$operations = $operations.append(ops)
		}
		{ sources: $sources, lefts: $lefts, rights: $rights, outputs: $outputs, operations: $operations, work: { calls: 0, prunes: 0, emitted: 0 } }
	}
	
	## Consumes the graph so list updates can reuse uniquely owned column storage.
	## Equality is statically dispatched for all four independently typed values.
	update : Graph(a, b, c, d), U64, a -> Graph(a, b, c, d)
		where [a.is_eq : a, a -> Bool, b.is_eq : b, b -> Bool, c.is_eq : c, c -> Bool, d.is_eq : d, d -> Bool]
	update = |graph, row, source| commit(graph, row, prepare(graph, row, source))

	Change(a) : [Keep, Replace(a)]
	Plan(a, b, c, d) : { source : Change(a), left : Change(b), right : Change(c), output : Change(d), work : { calls : U64, prunes : U64, emitted : U64 } }

	prepare : Graph(a, b, c, d), U64, a -> Plan(a, b, c, d)
		where [a.is_eq : a, a -> Bool, b.is_eq : b, b -> Bool, c.is_eq : c, c -> Bool, d.is_eq : d, d -> Bool]
	prepare = |graph, row, source| {
		old = graph.sources.get(row) ?? crash "missing source"
		if old == source {
			{ source: Keep, left: Keep, right: Keep, output: Keep, work: { calls: 0, prunes: 1, emitted: 0 } }
		} else {
			ops = graph.operations.get(row) ?? crash "missing operations"
			left = (ops.left)(source)
			right = (ops.right)(source)
			left_same = left == (graph.lefts.get(row) ?? crash "missing left")
			right_same = right == (graph.rights.get(row) ?? crash "missing right")
			prunes = (if left_same { 1.U64 } else { 0 }) + (if right_same { 1.U64 } else { 0 })
			joined = if left_same and right_same {
				{ output: Keep, calls: 2.U64, prunes, emitted: 0.U64 }
			} else {
				output = (ops.join)(left, right)
				if output == (graph.outputs.get(row) ?? crash "missing output") {
					{ output: Keep, calls: 3, prunes: prunes + 1, emitted: 0 }
				} else {
					{ output: Replace(output), calls: 3, prunes, emitted: 1 }
				}
			}
			{ source: Replace(source), left: if left_same { Keep } else { Replace(left) }, right: if right_same { Keep } else { Replace(right) }, output: joined.output, work: { calls: joined.calls, prunes: joined.prunes, emitted: joined.emitted } }
		}
	}

	commit : Graph(a, b, c, d), U64, Plan(a, b, c, d) -> Graph(a, b, c, d)
	commit = |{ sources, lefts, rights, outputs, operations, work: _ }, row, plan| {
		{ sources: install(sources, row, plan.source), lefts: install(lefts, row, plan.left), rights: install(rights, row, plan.right), outputs: install(outputs, row, plan.output), operations, work: plan.work }
	}

	install : List(a), U64, Change(a) -> List(a)
	install = |items, row, change| match change {
		Keep => items
		Replace(value) => items.set(row, value) ?? crash "missing column slot"
	}

	get : Graph(a, b, c, d), U64 -> { source : a, left : b, right : c, output : d }
	get = |graph, row| {
		{
			source: graph.sources.get(row) ?? crash "missing source",
			left: graph.lefts.get(row) ?? crash "missing left",
			right: graph.rights.get(row) ?? crash "missing right",
			output: graph.outputs.get(row) ?? crash "missing output",
		}
	}
	
	work : Graph(a, b, c, d) -> { calls : U64, prunes : U64, emitted : U64 }
	work = |graph| graph.work
}
