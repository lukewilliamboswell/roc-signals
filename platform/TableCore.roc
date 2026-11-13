## The engine's keyed table representation and change bookkeeping. Apps use
## Engine.Table; only internal modules can stamp, clear or guard this value.
TableCore := [].{
	## Unordered keyed rows, uniquely held by a cell. Its change record keeps
	## one earlier row per written key; the guard distinguishes keyed writes
	## from a replacement whose changes cannot describe the cell's old rows.
	Table(k, v) :: {
		rows : Dict(k, v),
		record : Dict(k, [Absent, Was(v)]),
		whole : [Keyed, Rewritten],
		version : U64,
		start : U64,
		id : U64,
	}.{

		## A table of `entries`, for a cell's starting value or a whole
		## rewrite. Two rows with one key are a contract error.
		from_list : List({ key : k, row : v }) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		from_list = |entries| { rows: rows_of(entries), record: Dict.empty(), whole: Keyed, version: 0, start: 0, id: 0 }

		## Replace every row with `entries`: a whole rewrite. Every view of the
		## table rebuilds, in the size of the table. Two rows with one key are
		## a contract error.
		load : Table(k, v), List({ key : k, row : v }) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		load = |table, entries| {
			{ record, version: now, start, id, .. } = table
			{ rows: rows_of(entries), record: if (record.is_empty()) record else Dict.empty(), whole: Rewritten, version: now + 1, start, id }
		}

		## The number of rows.
		len : Table(k, v) -> U64
		len = |table| table.rows.len()

		## The row at `key`.
		get : Table(k, v), k -> Try(v, [Missing])
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		get = |table, key| match table.rows.get(key) {
			Ok(row) => Ok(row)
			Err(_) => Err(Missing)
		}

		## Whether the table holds a row at `key`: what a decision asks before
		## an `insert`, which refuses a key already present.
		contains : Table(k, v), k -> Bool
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		contains = |table, key| table.rows.contains(key)

		## Add a row under a new key. A key already present is a contract
		## error: use `put` to insert or replace.
		insert : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		insert = |table, key, row| match table.rows.get(key) {
			Ok(_) => crash "contract: Table.insert: the key is already present; use put to insert or replace"
			Err(_) => write(table, key, Absent, Ok(row))
		}

		## Insert the row, or replace the row already at `key`.
		put : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		put = |table, key, row| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(row))
			Err(_) => write(table, key, Absent, Ok(row))
		}

		## Replace the row at `key`. A missing key leaves the table unchanged:
		## an earlier write of the same event may have removed it.
		replace : Table(k, v), k, v -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		replace = |table, key, row| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(row))
			Err(_) => table
		}

		## Change the row at `key` by a function. A missing key leaves the
		## table unchanged.
		update : Table(k, v), k, (v -> v) -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		update = |table, key, change| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Ok(change(old)))
			Err(_) => table
		}

		## Remove the row at `key`. A missing key leaves the table unchanged.
		remove : Table(k, v), k -> Table(k, v)
			where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
		remove = |table, key| match table.rows.get(key) {
			Ok(old) => write(table, key, Was(old), Err(Missing))
			Err(_) => table
		}

		## Change every row by a function: a whole rewrite, like `load`, so
		## every view rebuilds and the turn has no per-key changes. Costs the
		## size of the table.
		update_all : Table(k, v), (k, v -> v) -> Table(k, v)
		update_all = |table, change| {
			{ rows, record, version: now, start, id, .. } = table
			{ rows: rows.map(change), record: if (record.is_empty()) record else Dict.empty(), whole: Rewritten, version: now + 1, start, id }
		}

		## Fold over every row, in no particular order.
		fold : Table(k, v), state, (state, k, v -> state) -> state
		fold = |table, init, step| table.rows.fold(init, step)

		## Every row with its key, in no particular order: the order can differ
		## between two tables that hold the same rows, so sort the list before
		## anything that shows or compares it. Costs the size of the table.
		to_list : Table(k, v) -> List({ key : k, row : v })
		to_list = |table| table.rows.fold(List.with_capacity(table.rows.len()), |held, key, row| held.append({ key, row }))

		## The writes since the changes were last cleared: each written key with
		## its row as it was then (`Was(row)`, or `Absent`), or `Rewritten` if
		## a whole rewrite replaced the rows. In a pure test of a transition
		## (`Store.after`) it tells which rows the transition wrote.
		changes : Table(k, v) -> [Keyed(Dict(k, [Absent, Was(v)])), Rewritten]
		changes = |table| match table.whole {
			Keyed => Keyed(table.record)
			Rewritten => Rewritten
		}

		## The writes that undo every write since the last clear, or
		## `Rewritten` when a whole rewrite left no per-key changes. A handler
		## that keeps a history takes it in the event that made the writes:
		## the changes are cleared when the turn ends.
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

		## Apply a list of writes in order, recording each.
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

	## For the engine: forget the changes, at the end of a turn that wrote
	## the table, once every view has been refreshed. It is a step of its
	## own on the stored table. Empty changes are kept as they are; a
	## non-empty one is replaced by a new empty one, since `Dict.clear`
	## walks the whole capacity, which one large turn would leave at the
	## size of the table.
	clear_changes : Table(k, v) -> Table(k, v)
	clear_changes = |table| {
		{ rows, record, version: now, id, .. } = table
		{ rows, record: if (record.is_empty()) record else Dict.empty(), whole: Keyed, version: now, start: now, id }
	}

	## For the engine: the table as cell `id` of its store holds it.
	with_id : Table(k, v), U64 -> Table(k, v)
	with_id = |table, id| {
		{ rows, record, whole, version: now, start, .. } = table
		{ rows, record, whole, version: now, start, id }
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
			table
		} else {
			{ rows, .. } = table
			{ rows, record: Dict.empty(), whole: Rewritten, version: before.version + 1, start: before.start, id: before.id }
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
	{ rows, record, whole, version: now, start, id } = table
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
	{ rows: next_rows, record: next_record, whole, version: now + 1, start, id }
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
