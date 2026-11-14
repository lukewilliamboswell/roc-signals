## The keyed table representation and recording phase used by the engine.
## Apps reach rows through Engine.Table; bookkeeping remains in this namespace.
TableCore := [].{

	## Unordered rows and one earlier row per distinct key of the last writing
	## turn. The private phase rearms clearing without changing an observation.
	Table(k, v) :: {
		rows : Dict(k, v),
		record : Dict(k, [Absent, Was(v)]),
		whole : [Keyed, Rewritten],
		version : U64,
		start : U64,
		id : U64,
		phase : [Ready, Writing],
	}.{

		## Build an unassigned, ready table with no recorded writes. Duplicate
		## keys fail here before a cell can admit ambiguous identity.
		from_list : List({ key : k, row : v }) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		from_list = |entries| { rows: rows_of(entries), record: Dict.empty(), whole: Keyed, version: 0, start: 0, id: 0, phase: Ready }

		## Replace rows and discard keyed history while preserving cell identity
		## and recording phase. The incremented version forces a view rebuild;
		## constructing the dictionary is linear in entries.
		load : Table(k, v), List({ key : k, row : v }) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		load = |table, entries| {
			{ record, version: now, start, id, phase, .. } = table
			{ rows: rows_of(entries), record: if (record.is_empty()) record else Dict.empty(), whole: Rewritten, version: now + 1, start, id, phase }
		}

		## Read the dictionary count without walking rows or the change record.
		len : Table(k, v) -> U64
		len = |table| table.rows.len()

		## Look up by the key's own hash and equality. Returning a row may share
		## its storage with the table; callers must consume such readings before writes.
		get : Table(k, v), k -> Try(v, [Missing])
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		get = |table, key| match table.rows.get(key) {
			Ok(row) => Ok(row)
			Err(_) => Err(Missing)
		}

		## Test membership through the dictionary without retaining a row
		## alias across a later write.
		contains : Table(k, v), k -> Bool
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		contains = |table, key| table.rows.contains(key)

		## Reject duplicate identity before recording an absent key. The shared
		## write path retains only the first pre-write state of this key.
		insert : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		insert = |table, key, row| match table.rows.get(key) {
			Ok(_) => crash "contract: Table.insert: the key is already present; use put to insert or replace"
			Err(_) => write(table, key, Absent, Ok(row))
		}

		## Capture the current row or absence for the shared write path, which
		## keeps the first earlier row even when this key is written again.
		put : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		put = |table, key, row| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(row))
			Err(_) => write(table, key, Absent, Ok(row))
		}

		## Record and replace an existing row. A missing key is inert because
		## an earlier operation in the same event may have removed it.
		replace : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		replace = |table, key, row| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(row))
			Err(_) => table
		}

		## Apply the modifier to the current row while preserving the first
		## earlier row for this turn. A missing key invokes no modifier.
		update : Table(k, v), k, (v -> v) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		update = |table, key, change| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(change(old)))
			Err(_) => table
		}

		## Record an existing row before deletion, retaining it in the change
		## record until the next recording phase or holder disposal.
		remove : Table(k, v), k -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		remove = |table, key| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Err(Missing))
			Err(_) => table
		}

		## Map every row and replace keyed history with Rewritten. Preserve
		## cell identity and phase while advancing the version; work is linear
		## in rows, plus releasing the preceding change record.
		update_all : Table(k, v), (k, v -> v) -> Table(k, v)
		update_all = |table, change| {
			{ rows, record, version: now, start, id, phase, .. } = table
			{ rows: rows.map(change), record: if (record.is_empty()) record else Dict.empty(), whole: Rewritten, version: now + 1, start, id, phase }
		}

		## Walk the dictionary once in unspecified order, threading the
		## accumulator without constructing an intermediate row list.
		fold : Table(k, v), state, (state, k, v -> state) -> state
		fold = |table, init, step| table.rows.fold(init, step)

		## Allocate one list entry per dictionary row. Its unspecified order
		## is unsuitable as table-view identity or ordering.
		to_list : Table(k, v) -> List({ key : k, row : v })
		to_list = |table| table.rows.fold(List.with_capacity(table.rows.len()), |held, key, row| held.append({ key, row }))

		## Expose the retained first-earlier-row record without copying it.
		## Readers can share its rows, so dropping the table's record releases
		## only that holder; the next writing phase determines its replacement.
		changes : Table(k, v) -> [Keyed(Dict(k, [Absent, Was(v)])), Rewritten]
		changes = |table| match table.whole {
			Keyed => Keyed(table.record)
			Rewritten => Rewritten
		}

		## Translate the retained record into one inverse operation per key.
		## The traversal and output are linear in recorded keys; whole rewrites
		## have no per-key inverse. Returned rows become independent holders.
		inverse : Table(k, v) -> Try(List([Put(k, v), Remove(k)]), [Rewritten])
		inverse = |table| match table.whole {
			Rewritten => Err(Rewritten)
			Keyed =>
				Ok(
					table.record.fold(
						List.with_capacity(table.record.len()),
						|acc, key, before| match before {
							Was(row) => acc.append(Put(key, row))
							Absent => acc.append(Remove(key))
						},
					),
				)
		}

		## Replay writes in list order through the same keyed write path.
		## Repeated keys retain their first earlier row, preserving one inverse
		## for the complete sequence.
		apply : Table(k, v), List([Put(k, v), Remove(k)]) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		apply = |table, writes| writes.fold(
			table,
			|acc, op| match op {
				Put(key, row) => acc.put(key, row)
				Remove(key) => acc.remove(key)
			},
		)

	}

	## For the engine: how many writes the table has taken.
	version : Table(k, v) -> U64
	version = |table| table.version

	## For the engine: the version at the last clear. A view that has seen
	## exactly this version can bring itself up to date from `changes`.
	changes_start : Table(k, v) -> U64
	changes_start = |table| table.start

	## For the engine: forget recorded writes at mount, initialization or
	## the next writing turn's first modifier. Empty changes are kept as
	## they are; a
	## non-empty one is replaced by a new empty one, since `Dict.clear`
	## walks the whole capacity, which one large turn would leave at the
	## size of the table.
	clear_changes : Table(k, v) -> Table(k, v)
	clear_changes = |table| {
		{ rows, record, version: now, id, .. } = table
		{ rows, record: if (record.is_empty()) record else Dict.empty(), whole: Keyed, version: now, start: now, id, phase: Ready }
	}

	## Start recording a turn once, before its first modifier. Retained
	## changes from the previous writing turn stop holding their rows here.
	begin_changes : Table(k, v) -> Table(k, v)
	begin_changes = |table| match table.phase {
		Writing => table
		Ready => { ..TableCore.clear_changes(table), phase: Writing }
	}

	## Rearm the next write without changing what changes/inverse observe.
	finish_changes : Table(k, v) -> Table(k, v)
	finish_changes = |table| { ..table, phase: Ready }

	## The settled invariant checks that the root closed the writing turn.
	is_ready : Table(k, v) -> Bool
	is_ready = |table| table.phase == Ready

	## For the engine: the table as cell `id` of its store holds it.
	with_id : Table(k, v), U64 -> Table(k, v)
	with_id = |table, id| {
		{ rows, record, whole, version: now, start, phase, .. } = table
		{ rows, record, whole, version: now, start, id, phase }
	}

	## For the engine: what a table cell notes before a write of it runs, to
	## judge what the write leaves (`kept`).
	mark : Table(k, v) -> { id : U64, start : U64, version : U64 }
	mark = |table| { id: table.id, start: table.start, version: table.version }

	## For the engine: what a table cell stores after a write of it. A
	## write that leaves the table the cell held, changed by the operations
	## above, keeps its changes: it has the cell's `id` and `start`. Any
	## other table (a new one from `from_list`, another cell's, a copy kept
	## from an earlier turn) has no changes describing how it differs from what the
	## views last saw, so it is stored as a whole rewrite and every view
	## rebuilds. No write can leave a view stale.
	kept : Table(k, v), { id : U64, start : U64, version : U64 } -> Table(k, v)
	kept = |table, before|
		if table.id == before.id and table.start == before.start {
			{ ..table, phase: Writing }
		} else {
			{ rows, .. } = table
			{ rows, record: Dict.empty(), whole: Rewritten, version: before.version + 1, start: before.start, id: before.id, phase: Writing }
		}
}

## The rows of `entries` by key.
rows_of : List({ key : k, row : v }) -> Dict(k, v)
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
rows_of = |entries| {
	rows = entries.fold(Dict.with_capacity(entries.len()), |acc, { key, row }| acc.insert(key, row))
	if rows.len() != entries.len() {
		crash "contract: a table's rows: two rows have the same key"
	} else {
		rows
	}
}

## Remember `key`'s state when the turn began (its first write wins) and
## apply the write: `Ok(row)` stores the row, `Err(Missing)` removes it.
write : Table(k, v), k, [Absent, Was(v)], Try(v, [Missing]) -> Table(k, v)
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
write = |table, key, before, after| {
	{ rows, record, whole, version: now, start, id, phase } = table
	next_record = match whole {
		Rewritten => record
		Keyed =>
			record.update(
				key,
				|found| match found {
					Ok(first) => Ok(first)
					Err(Missing) => Ok(before)
				},
			)
	}
	next_rows = match after {
		Ok(row) => rows.insert(key, row)
		Err(Missing) => rows.remove(key)
	}
	{ rows: next_rows, record: next_record, whole, version: now + 1, start, id, phase }
}

## How many keys a table's changes hold, or `Rewritten`.
recorded : Table(k, v) -> Try(U64, [Rewritten])
recorded = |table| match table.changes() {
	Keyed(record) => Ok(record.len())
	Rewritten => Err(Rewritten)
}

## A key written twice keeps its first state, and the inverse undoes the turn.
expect {
	t0 = Table.from_list([{ key: 1.U64, row: "a" }, { key: 2, row: "b" }])
	t1 = t0.update(1, |r| "${r}!").update(1, |r| "${r}?").remove(2).insert(3, "c")
	undone = match t1.inverse() {
		Ok(writes) => t1.apply(writes)
		Err(Rewritten) => t1
	}
	actual =
		\\row 1: ${Str.inspect(t1.get(1))}
		\\changed: ${Str.inspect(recorded(t1))}
		\\undone 1: ${Str.inspect(undone.get(1))}
		\\undone 2: ${Str.inspect(undone.get(2))}
		\\undone 3: ${Str.inspect(undone.get(3))}
	expected =
		\\row 1: Ok("a!?")
		\\changed: Ok(3)
		\\undone 1: Ok("a")
		\\undone 2: Ok("b")
		\\undone 3: Err(Missing)
	actual == expected
}

## `contains` follows the writes, and `to_list` gives every row once with
## its key, whatever order the table holds them in.
expect {
	table = Table.from_list([{ key: 1.U64, row: "a" }, { key: 2, row: "b" }, { key: 3, row: "c" }]).remove(2).put(4, "d")
	listed = table.to_list().sort_with(|x, y| if (x.key < y.key) Before else if (x.key > y.key) After else Same)
	(table.contains(1), table.contains(2), table.contains(4), listed) == (Bool.True, Bool.False, Bool.True, [{ key: 1, row: "a" }, { key: 3, row: "c" }, { key: 4, row: "d" }])
}

## A write that leaves the cell's own table keeps its changes; a new table,
## another cell's and a copy from before the last clear are each stored as a
## whole rewrite.
expect {
	cell = TableCore.with_id(Table.from_list([{ key: 1.U64, row: "a" }]), 7)
	before = TableCore.mark(cell)
	own = TableCore.kept(cell.put(2, "b"), before)
	fresh = TableCore.kept(Table.from_list([{ key: 9.U64, row: "z" }]), before)
	other = TableCore.kept(TableCore.with_id(cell, 8).put(2, "b"), before)
	later = TableCore.clear_changes(cell.put(2, "b"))
	stale = TableCore.kept(cell.put(3, "c"), TableCore.mark(later))
	show = |t| {
		how = match t.changes() {
			Keyed(_) => "keyed"
			Rewritten => "rewritten"
		}
		"${how} v${TableCore.version(t).to_str()} from ${TableCore.changes_start(t).to_str()} rows ${t.len().to_str()}"
	}
	actual =
		\\own: ${show(own)}
		\\fresh: ${show(fresh)}
		\\other: ${show(other)}
		\\stale: ${show(stale)}
	expected =
		\\own: keyed v1 from 0 rows 2
		\\fresh: rewritten v1 from 0 rows 1
		\\other: rewritten v1 from 0 rows 2
		\\stale: rewritten v2 from 1 rows 2
	actual == expected
}

## A writing turn keeps the first earlier row of each key. Closing it
## preserves that record; only the next writing turn replaces it.
expect {
	started = TableCore.begin_changes(Table.from_list([{ key: 1.U64, row: "a" }]))
	wrote_first = TableCore.begin_changes(started.put(1, "b")).put(1, "c")
	first = TableCore.finish_changes(wrote_first)
	second = TableCore.finish_changes(TableCore.begin_changes(first).put(1, "d"))
	actual = {
		first_inverse: first.inverse()?,
		second_inverse: second.inverse()?,
		ready: TableCore.is_ready(first),
	}
	actual == { first_inverse: [Put(1, "a")], second_inverse: [Put(1, "c")], ready: True }
}
