import fz.Fuzz
import pf.Core
import pf.TableCore exposing [Table]
import pf.View
import ChangeVectors

## A table's changes, held to a model of what they must say: bytes decode
## into a session of pure turns (`Store.after`) over one store of two table
## cells, `rows` and `spare`, and after every turn each cell's table must say
## exactly how it differs from the rows its last writing turn began with.
##
## A session keeps up to four `Store` values, and each turn takes one of them
## up again, so histories branch: two values of one store share their cells'
## identities and can reach one write count with different rows. A turn is
## one to three writes, in order:
## - keyed operations on the table the modifier was handed (`insert`, `put`,
##   `replace`, `update`, `remove`), `update_all`, an undo of the turn so far
##   (`apply` of the table's own `inverse`) and an undo of the base value's
##   last writing turn (its `inverse`, read before the turn);
## - the same operations after the modifier ignores its argument and starts
##   from another table: a copy of `rows` read from any kept value (an older
##   one, the base itself, one of another history), a copy of `spare` (another
##   cell's identity) or a new table from `from_list`;
## - keyed writes of `spare`, which leave `rows`' changes as they were.
##
## The model holds rows as a sorted list and, for each cell, the rows its last
## writing turn began with and the keys it wrote, or that it rewrote the table
## whole. It never asks the table. After every turn, for both cells of the new
## value:
## - the rows are the model's;
## - the changes are a whole rewrite exactly when a write of the turn left a
##   table other than the one its modifier was handed, or replaced every row;
##   otherwise they name exactly the keys the turn wrote, each with its row (or
##   absence) when the turn began, and nothing else;
## - `inverse`, applied to the table, gives the rows the turn began with;
## - the table is rearmed for its next writing turn, and a count equal to the
##   changes' start means the table holds the rows its turn began with;
## - a view of the base value's table, brought up to date with the new one by
##   `View.follow`, holds the ordered keys of a view built from scratch: a
##   count can never make a changed table look unchanged.
## The session frees everything it allocated.

# ------------------------------------------------------------------ steps

## A keyed operation, `update_all` (`All`), an undo of the turn so far
## (`Undo`) or an undo of the base value's last writing turn (`UndoLast`).
Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), All, Undo, UndoLast]

## The table a write of `rows` starts from: the one its modifier was handed,
## a copy of `rows` or of `spare` read from the kept value at that index, or
## a new table of the rows `fresh_rows` gives.
Source : [Arg, Copy(U64), Other(U64), Fresh(U64)]

## One write of a turn: one modifier of a cell.
Write : [Rows(Source, List(Op)), Spare(List(Op))]

## One pure turn: which kept value it starts from, its writes, and whether
## its result is kept beside the others or in the base's place.
Step : { base : U64, writes : List(Write), push : Bool }

## Keys and rows are small, so sessions write one key twice and histories
## meet at one count with different rows.
key_space : U64
key_space = 6

row_space : U64
row_space = 4

held_limit : U64
held_limit = 4

## What `update` and `update_all` do to a row.
bump : U64 -> U64
bump = |row| (row + 1) % row_space

## The rows `Fresh(seed)` stands for: the keys below five whose bit `seed`
## sets.
fresh_rows : U64 -> List((U64, U64))
fresh_rows = |seed| [(0, 1), (1, 2), (2, 4), (3, 8), (4, 16)].keep_if(|(_, bit)| (seed // bit) % 2 == 1).map(|(key, _)| (key, (seed + key) % row_space))

first_rows : List((U64, U64))
first_rows = [(0, 0), (1, 1)]

first_spare : List((U64, U64))
first_spare = [(1, 0), (2, 1)]

# ------------------------------------------------------------- the codec

## Read the steps the bytes hold; a step cut short by the end is dropped.
steps_of : List(U8) -> List(Step)
steps_of = |bytes| {
	var $at = 0
	var $out = []
	var $more = Bool.True
	while $more {
		match step_at(bytes, $at) {
			Ok({ step, next }) => {
				$out = $out.append(step)
				$at = next
			}
			Err(End) => {
				$more = Bool.False
			}
		}
	}
	$out
}

byte : List(U8), U64 -> Try(U64, [End])
byte = |bytes, at| match bytes.get(at) {
	Ok(b) => Ok(b.to_u64())
	Err(_) => Err(End)
}

step_at : List(U8), U64 -> Try({ step : Step, next : U64 }, [End])
step_at = |bytes, at| {
	head = byte(bytes, at)?
	count = (head // 4) % 4
	var $next = at + 1
	var $writes = []
	var $i = 0
	while $i < count {
		{ write, next } = write_at(bytes, $next)?
		$writes = $writes.append(write)
		$next = next
		$i = $i + 1
	}
	Ok({ step: { base: head % 4, writes: $writes, push: (head // 16) % 2 == 1 }, next: $next })
}

write_at : List(U8), U64 -> Try({ write : Write, next : U64 }, [End])
write_at = |bytes, at| {
	kind = byte(bytes, at)?
	{ ops, next } = ops_at(bytes, at + 1)?
	sub = kind // 8
	write = match kind % 8 {
		1 => Rows(Copy(sub % held_limit), ops)
		2 => Rows(Other(sub % held_limit), ops)
		3 => Rows(Fresh(sub), ops)
		4 => Spare(ops)
		_ => Rows(Arg, ops)
	}
	Ok({ write, next })
}

ops_at : List(U8), U64 -> Try({ ops : List(Op), next : U64 }, [End])
ops_at = |bytes, at| {
	count = byte(bytes, at)? % 4
	var $next = at + 1
	var $ops = []
	var $i = 0
	while $i < count {
		kind = byte(bytes, $next)?
		arg = byte(bytes, $next + 1)?
		key = arg % key_space
		row = (arg // key_space) % row_space
		op = match kind % 8 {
			0 => Insert(key, row)
			1 => Put(key, row)
			2 => Replace(key, row)
			3 => Update(key)
			4 => Remove(key)
			5 => All
			6 => Undo
			_ => UndoLast
		}
		$ops = $ops.append(op)
		$next = $next + 2
		$i = $i + 1
	}
	Ok({ ops: $ops, next: $next })
}

## The bytes a session is written as: what `steps_of` reads back.
bytes_of : List(Step) -> List(U8)
bytes_of = |steps| steps.fold([], |out, step| step_bytes(out, step))

step_bytes : List(U8), Step -> List(U8)
step_bytes = |out, { base, writes, push }| {
	head = base + 4 * writes.len() + (if (push) 16 else 0)
	writes.fold(out.append(head.to_u8_wrap()), |acc, write| write_bytes(acc, write))
}

write_bytes : List(U8), Write -> List(U8)
write_bytes = |out, write| {
	(kind, ops) = match write {
		Rows(Arg, os) => (0, os)
		Rows(Copy(i), os) => (1 + 8 * i, os)
		Rows(Other(i), os) => (2 + 8 * i, os)
		Rows(Fresh(seed), os) => (3 + 8 * seed, os)
		Spare(os) => (4, os)
	}
	ops.fold(out.append(kind.to_u8_wrap()).append(ops.len().to_u8_wrap()), |acc, op| op_bytes(acc, op))
}

op_bytes : List(U8), Op -> List(U8)
op_bytes = |out, op| {
	arg = |key, row| (key + key_space * row).to_u8_wrap()
	(kind, a) = match op {
		Insert(k, r) => (0, arg(k, r))
		Put(k, r) => (1, arg(k, r))
		Replace(k, r) => (2, arg(k, r))
		Update(k) => (3, arg(k, 0))
		Remove(k) => (4, arg(k, 0))
		All => (5, 0)
		Undo => (6, 0)
		UndoLast => (7, 0)
	}
	out.append(kind).append(a)
}

# --------------------------------------------------------------- the model

## What the model knows of a cell's last writing turn: the rows it began
## with and the keys it wrote, or that it rewrote the table whole.
Last : [Keyed(List((U64, U64)), List(U64)), Whole]

## One cell as the model holds it.
Held : { rows : List((U64, U64)), last : Last }

## A cell's rows within a turn: the rows the turn began with, the keys it
## has written and whether it has rewritten the table whole.
Turn : { rows : List((U64, U64)), began : List((U64, U64)), whole : Bool, written : List(U64) }

rget : List((U64, U64)), U64 -> Try(U64, [Missing])
rget = |rows, key| match rows.find_first(|(k, _)| k == key) {
	Ok((_, row)) => Ok(row)
	Err(_) => Err(Missing)
}

by_key : (U64, U64), (U64, U64) -> [Before, Same, After]
by_key = |(a, _), (b, _)| if (a < b) Before else if (a > b) After else Same

rset : List((U64, U64)), U64, Try(U64, [Missing]) -> List((U64, U64))
rset = |rows, key, after| {
	without = rows.drop_if(|(k, _)| k == key)
	match after {
		Ok(row) => without.append((key, row)).sort_with(by_key)
		Err(Missing) => without
	}
}

sorted_keys : List(U64) -> List(U64)
sorted_keys = |keys| keys.sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)

note : Turn, U64, Try(U64, [Missing]) -> Turn
note = |t, key, after| {
	written = if (t.written.contains(key)) t.written else sorted_keys(t.written.append(key))
	{ ..t, rows: rset(t.rows, key, after), written }
}

## The undo of the base value's last writing turn, as the operations its
## inverse holds: one per key it wrote.
last_undo : Last -> List(Op)
last_undo = |last| match last {
	Keyed(began, written) => written.map(
		|key| match rget(began, key) {
			Ok(row) => Put(key, row)
			Err(Missing) => Remove(key)
		},
	)
	Whole => []
}

model_op : Turn, Op, List(Op) -> Turn
model_op = |t, op, undo_last| {
	present = |key| rget(t.rows, key).is_ok()
	match op {
		Insert(k, r) => if (present(k)) t else note(t, k, Ok(r))
		Put(k, r) => note(t, k, Ok(r))
		Replace(k, r) => if (present(k)) note(t, k, Ok(r)) else t
		Update(k) => match rget(t.rows, k) {
			Ok(r) => note(t, k, Ok(bump(r)))
			Err(Missing) => t
		}
		Remove(k) => if (present(k)) note(t, k, Err(Missing)) else t
		All => { ..t, rows: t.rows.map(|(k, r)| (k, bump(r))), whole: Bool.True }
		Undo =>
			if t.whole {
				t
			} else {
				t.written.fold(t, |acc, key| { ..acc, rows: rset(acc.rows, key, rget(t.began, key)) })
			}
		UndoLast => undo_last.fold(t, |acc, o| model_op(acc, o, []))
	}
}

## One model value: both cells.
Model : { rows : Held, spare : Held }

model_start : Model
model_start = { rows: { rows: first_rows, last: Keyed(first_rows, []) }, spare: { rows: first_spare, last: Keyed(first_spare, []) } }

## The model after one turn from `base`, with `kept` the model values the
## turn's copies read from.
model_turn : Model, List(Model), List(Write) -> Model
model_turn = |base, kept, writes| {
	pick = |i| kept.get(i % kept.len()) ?? crash "table-changes: no kept value"
	start = |held| { rows: held.rows, began: held.rows, whole: Bool.False, written: [] }
	# A copy carries its own last writing turn's changes, which its
	# operations and an undo inside the modifier read until the cell stores
	# it, as a whole rewrite.
	copied = |held| match held.last {
		Keyed(began, written) => { rows: held.rows, began, whole: Bool.False, written }
		Whole => { rows: held.rows, began: held.rows, whole: Bool.True, written: [] }
	}
	undo_last = last_undo(base.rows.last)
	folded = writes.fold(
		{ rows: start(base.rows), spare: start(base.spare), wrote_rows: Bool.False, wrote_spare: Bool.False },
		|acc, write| match write {
			Rows(source, ops) => {
				run = |t| ops.fold(t, |u, op| model_op(u, op, undo_last))
				stored = |t| { ..acc.rows, rows: run(t).rows, whole: Bool.True }
				rows = match source {
					Arg => run(acc.rows)
					Copy(i) => stored(copied(pick(i).rows))
					Other(i) => stored(copied(pick(i).spare))
					Fresh(seed) => {
						fresh = fresh_rows(seed).sort_with(by_key)
						stored({ rows: fresh, began: fresh, whole: Bool.False, written: [] })
					}
				}
				{ ..acc, rows, wrote_rows: Bool.True }
			}
			Spare(ops) => { ..acc, spare: ops.fold(acc.spare, |t, op| model_op(t, op, last_undo(base.spare.last))), wrote_spare: Bool.True }
		},
	)
	close = |t, held, wrote|
		if wrote {
			{ rows: t.rows, last: if (t.whole) Whole else Keyed(t.began, t.written) }
		} else {
			held
		}
	{ rows: close(folded.rows, base.rows, folded.wrote_rows), spare: close(folded.spare, base.spare, folded.wrote_spare) }
}

# ------------------------------------------------------------- the subject

start_table : List((U64, U64)) -> Table(U64, U64)
start_table = |rows| Table.from_list(rows.map(|(key, row)| { key, row })) ?? crash "table-changes: a starting table repeats a key"

## The store every session starts from.
store = Core.store_of({}, { rows: Core.table(start_table(first_rows)), spare: Core.table(start_table(first_spare)) }.Core.Cells)

cells = store.cells()

run_op : Table(U64, U64), Op, List([Put(U64, U64), Remove(U64)]) -> Table(U64, U64)
run_op = |table, op, undo_last| match op {
	Insert(k, r) => table.insert(k, r)
	Put(k, r) => table.put(k, r)
	Replace(k, r) => table.replace(k, r)
	Update(k) => table.update(k, bump)
	Remove(k) => table.remove(k)
	All => table.update_all(|_, r| bump(r))
	Undo => match table.inverse() {
		Ok(writes) => table.apply(writes)
		Err(Rewritten) => table
	}
	UndoLast => table.apply(undo_last)
}

inverse_or_none : Table(U64, U64) -> List([Put(U64, U64), Remove(U64)])
inverse_or_none = |table| match table.inverse() {
	Ok(writes) => writes
	Err(Rewritten) => []
}

## The rows a table holds, sorted by key.
rows_of : Table(U64, U64) -> List((U64, U64))
rows_of = |table| table.to_list().map(|{ key, row }| (key, row)).sort_with(by_key)

# -------------------------------------------------------------- the checks

## A view of every row, by key, in chunks of four.
view_of : Table(U64, U64) -> View(U64, U64, U64)
view_of = |table| View.build(table, { query: { keep: |_, _| Bool.True, sort: |key, _| key, compare: |a, b| if (a < b) Before else if (a > b) After else Same }, window: { start: 0, count: 2 }, limit: 4, site: "table-changes" })

## What a table must hold and say, against the model's cell.
check_cell : Str, Table(U64, U64), Held -> Try({}, Str)
check_cell = |name, table, held| {
	rows = rows_of(table)
	if rows != held.rows {
		return Err("${name} holds ${Str.inspect(rows)}, the model ${Str.inspect(held.rows)}")
	}
	if !TableCore.is_ready(table) {
		return Err("${name} was not rearmed when its writing turn ended")
	}
	version = TableCore.version(table)
	start = TableCore.changes_start(table)
	match (table.changes(), held.last) {
		(Rewritten, Whole) =>
			if version <= start {
				Err("${name} was rewritten whole, but its count ${version.to_str()} is not past its start ${start.to_str()}")
			} else {
				Ok({})
			}
		(Rewritten, Keyed(_, written)) => Err("${name}'s changes say it was rewritten whole; its turn wrote the keys ${Str.inspect(written)} of the table its modifier was handed")
		(Keyed(record), Whole) => Err("${name}'s changes name the keys ${Str.inspect(sorted_keys(record.fold([], |acc, key, _| acc.append(key))))}; its turn left another table, or replaced every row, which is a whole rewrite")
		(Keyed(record), Keyed(began, written)) => {
			keys = sorted_keys(record.fold([], |acc, key, _| acc.append(key)))
			if keys != written {
				return Err("${name}'s changes name the keys ${Str.inspect(keys)}; its turn wrote ${Str.inspect(written)}")
			}
			wrong = record.fold([], |acc, key, before| acc.append((key, before))).keep_if(
				|(key, before)| match (before, rget(began, key)) {
					(Was(row), Ok(was)) => row != was
					(Absent, Err(Missing)) => Bool.False
					_ => Bool.True
				},
			)
			if !wrong.is_empty() {
				return Err("${name}'s changes give ${Str.inspect(wrong)}, but the turn began with ${Str.inspect(began)}")
			}
			undone = rows_of(table.apply(inverse_or_none(table)))
			if undone != began {
				return Err("${name}'s inverse gives ${Str.inspect(undone)}; its turn began with ${Str.inspect(began)}")
			}
			if version == start and rows != began {
				return Err("${name}'s count ${version.to_str()} equals its start, but it holds ${Str.inspect(rows)} and its turn began with ${Str.inspect(began)}")
			}
			Ok({})
		}
	}
}

## A view of the base value's table, brought up to date with the new one,
## holds what a view built from scratch holds.
check_follow : Str, Table(U64, U64), Table(U64, U64) -> Try({}, Str)
check_follow = |name, before, after| {
	followed = view_of(before).follow(after)
	keys = followed.view.keys()
	want = rows_of(after).map(|(key, _)| key)
	if keys != want {
		Err("${name}: a view followed to the new table (${Str.inspect(followed.how)}) holds ${Str.inspect(keys)}; the table holds ${Str.inspect(want)}")
	} else if followed.how == Unchanged and rows_of(before) != rows_of(after) {
		Err("${name}: follow found the table unchanged, but it went from ${Str.inspect(rows_of(before))} to ${Str.inspect(rows_of(after))}")
	} else {
		Ok({})
	}
}

## Every rule, for both cells of the value a turn left.
check_turn : Table(U64, U64), Table(U64, U64), Table(U64, U64), Table(U64, U64), Model -> Try({}, Str)
check_turn = |rows_before, spare_before, rows, spare, model| {
	check_cell("rows", rows, model.rows)?
	check_cell("spare", spare, model.spare)?
	check_follow("rows", rows_before, rows)?
	check_follow("spare", spare_before, spare)
}

# ------------------------------------------------------------- the session

## Run one session; the first broken rule crashes with the step it broke at.
run : List(Step) -> {}
run = |steps| {
	var $kept = [{ value: store, model: model_start }]
	var $n = 0
	for step in steps {
		at = step.base % $kept.len()
		base = $kept.get(at) ?? crash "table-changes: no base"
		pick = |i| $kept.get(i % $kept.len()) ?? crash "table-changes: no kept value"
		undo_last = inverse_or_none(base.value.read(cells.rows))
		undo_spare = inverse_or_none(base.value.read(cells.spare))
		writes = step.writes.map(
			|write| match write {
				Rows(source, ops) => {
					from = match source {
						Arg => Err(Arg)
						Copy(i) => Ok(pick(i).value.read(cells.rows))
						Other(i) => Ok(pick(i).value.read(cells.spare))
						Fresh(seed) => Ok(start_table(fresh_rows(seed)))
					}
					cells.rows.update(
						|table| {
							began = match from {
								Ok(other) => other
								Err(Arg) => table
							}
							ops.fold(began, |t, op| run_op(t, op, undo_last))
						},
					)
				}
				Spare(ops) => cells.spare.update(|table| ops.fold(table, |t, op| run_op(t, op, undo_spare)))
			},
		)
		value = base.value.after(writes)
		model = model_turn(base.model, $kept.map(|k| k.model), step.writes)
		match check_turn(base.value.read(cells.rows), base.value.read(cells.spare), value.read(cells.rows), value.read(cells.spare), model) {
			Ok(_) => {}
			Err(problem) => crash "table-changes: at step ${$n.to_str()} (${Str.inspect(step)}): ${problem}"
		}
		$kept =
			if step.push and $kept.len() < held_limit {
				$kept.append({ value, model })
			} else {
				$kept.set(at, { value, model }) ?? crash "table-changes: no base"
			}
		$n = $n + 1
	}
	{}
}

# ---------------------------------------------------------------- examples

w : List(Write) -> Step
w = |writes| { base: 0, writes, push: Bool.False }

## Keep the result beside the others.
kept_as : Step, U64 -> Step
kept_as = |step, base| { ..step, base, push: Bool.True }

## Two histories of one store reach one count with different rows, and a
## copy from one is handed to the other: the shortest trace the table model
## found against a `kept` that judged by identity and start alone.
branching_steps : List(Step)
branching_steps = [
	kept_as(w([Rows(Arg, [Insert(5, 0)])]), 0),
	kept_as(w([Rows(Arg, [])]), 1),
	kept_as(w([Rows(Arg, [Insert(5, 1)])]), 0),
	{ base: 3, writes: [Rows(Copy(2), [Put(5, 0)])], push: Bool.False },
]

## Keyed writes: one key twice in a turn, removes of absent keys, an undo of
## the turn so far, and an undo of the last writing turn.
keyed_steps : List(Step)
keyed_steps = [
	w([Rows(Arg, [Put(0, 2), Put(0, 3), Remove(1)]), Rows(Arg, [Insert(2, 0), Update(0)])]),
	w([Rows(Arg, [Replace(4, 1), Remove(4), Insert(0, 1)])]),
	w([Rows(Arg, [Put(3, 3), Undo, Put(5, 2)])]),
	w([Rows(Arg, [UndoLast])]),
	w([Spare([Put(4, 3)])]),
	w([Rows(Arg, [UndoLast, Update(2)])]),
]

## Whole rewrites: `update_all`, a new table, the other cell's table, and a
## copy of this one, each followed by keyed writes in the same turn, then an
## undo after a whole rewrite, which writes nothing.
whole_steps : List(Step)
whole_steps = [
	w([Rows(Arg, [Put(1, 2), All, Put(3, 0)])]),
	w([Rows(Fresh(13), [Insert(5, 1)])]),
	w([Rows(Other(0), [Remove(1)]), Rows(Arg, [Undo])]),
	kept_as(w([Rows(Arg, [Put(0, 3)])]), 0),
	w([Rows(Copy(1), [])]),
	w([Rows(Arg, [UndoLast])]),
	w([Rows(Copy(0), [Put(2, 2)]), Rows(Arg, [Update(2)])]),
]

## A copy kept across a turn that wrote nothing: still another table.
idle_copy_steps : List(Step)
idle_copy_steps = [
	kept_as(w([Rows(Arg, [])]), 0),
	w([Spare([Update(1)])]),
	{ base: 0, writes: [Rows(Copy(1), [Put(1, 3)])], push: Bool.False },
	w([Rows(Arg, [UndoLast])]),
]

## Every named session must decode to the steps it is written as.
written_cases : List({ name : Str, steps : List(Step) })
written_cases = [
	{ name: "branching-histories", steps: branching_steps },
	{ name: "keyed", steps: keyed_steps },
	{ name: "whole", steps: whole_steps },
	{ name: "idle-copy", steps: idle_copy_steps },
]

expect written_cases.all(|written| steps_of(bytes_of(written.steps)) == written.steps)

## The model alone: a copy handed to a cell is a whole rewrite, and an undo
## of the last writing turn writes back exactly the keys it wrote.
expect {
	copied = model_turn(model_start, [model_start], [Rows(Copy(0), [Put(1, 3)])])
	edited = model_turn(model_start, [model_start], [Rows(Arg, [Put(0, 2), Remove(1)])])
	undone = model_turn(edited, [edited], [Rows(Arg, [UndoLast])])
	copied.rows.last == Whole
		and edited.rows.last == Keyed(first_rows, [0, 1])
		and undone.rows.rows == first_rows
		and undone.rows.last == Keyed([(0, 2)], [0, 1])
}

## A seeded series of sessions, for fixed replays: varied, and long enough
## to branch, copy and rewrite.
seeded : U64, U64 -> List(U8)
seeded = |seed, n| {
	var $x = seed
	var $out = List.with_capacity(n)
	while $out.len() < n {
		$x = $x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
		$out = $out.append($x.shr_zf_wrap(40).to_u8_wrap())
	}
	$out
}

series : U64 -> {}
series = |count| {
	var $k = 0
	while $k < count {
		run(steps_of(seeded($k + 1, 400)))
		$k = $k + 1
	}
	{}
}

# ------------------------------------------------------------- the vectors

## A vector's operation as the session's.
op_from : ChangeVectors.Op -> Op
op_from = |op| match op {
	Insert(k, r) => Insert(k, r)
	Put(k, r) => Put(k, r)
	Replace(k, r) => Replace(k, r)
	Update(k) => Update(k)
	Remove(k) => Remove(k)
	All => All
	Undo => Undo
}

## A vector's record with its keys in order, as the model and a `Dict` give
## them in no particular order.
record_text : ChangeVectors.Record -> Str
record_text = |record| match record {
	Rewritten => "rewritten"
	Keyed(entries) => Str.inspect(entries.sort_with(|a, b| if (a.key < b.key) Before else if (a.key > b.key) After else Same))
}

## A cell whose last writing turn began with `rows` and wrote nothing.
held_of : List((U64, U64)) -> Held
held_of = |rows| { rows, last: Keyed(rows, []) }

## The model through a vector's turns, against what Lean says each leaves.
## A kept copy is a model value whose `spare` is its `rows`, so `Other(i)`
## reads the copy; a new table is a kept value of its rows that no turn
## has written, so `Copy(i)` of it is what `Fresh` is for the session.
vector_model : ChangeVectors.Vector -> Try({}, Str)
vector_model = |vector| {
	var $model = { rows: held_of(vector.start), spare: held_of(first_spare) }
	var $saved = []
	var $n = 0.U64
	for turn in vector.turns {
		$n = $n + 1
		(writes, kept) = turn.modifiers.fold(
			([], $saved),
			|(ws, ks), modifier| match modifier {
				On(ops) => (ws.append(Rows(Arg, ops.map(op_from))), ks)
				Saved(i, ops) => (ws.append(Rows(Copy(i), ops.map(op_from))), ks)
				Other(i) => (ws.append(Rows(Other(i), [])), ks)
				Fresh(rows) => {
					fresh = held_of(rows.sort_with(by_key))
					(ws.append(Rows(Copy(ks.len()), [])), ks.append({ rows: fresh, spare: fresh }))
				}
			},
		)
		model = model_turn($model, kept, writes)
		record = match model.rows.last {
			Whole => Rewritten
			Keyed(began, written) =>
				Keyed(
					written.map(
						|key| match rget(began, key) {
							Ok(row) => { key, before: Was(row) }
							Err(Missing) => { key, before: Absent }
						},
					),
				)
		}
		want = turn.outcome
		if model.rows.rows != want.rows or record_text(record) != record_text(want.record) {
			return Err("vector ${vector.seed.to_str()}, turn ${$n.to_str()}: the model holds ${Str.inspect(model.rows.rows)} and says ${record_text(record)}; Lean ${Str.inspect(want.rows)} and ${record_text(want.record)}")
		}
		$saved = if (turn.keep) $saved.append({ rows: model.rows, spare: model.rows }) else $saved
		$model = model
	}
	Ok({})
}

## The identity a kept copy is handed under for `Other`: no cell's.
other_id : U64
other_id = 1000000

## The code through a vector's turns, as `Store.after` makes them with the
## cell's generated modifier, against what Lean's transliteration of that
## code says each leaves, write counts included.
vector_code : ChangeVectors.Vector -> Try({}, Str)
vector_code = |vector| {
	var $value = Core.store_of({}, { rows: Core.table(start_table(vector.start)), spare: Core.table(start_table(first_spare)) }.Core.Cells)
	held = $value.cells()
	var $saved = []
	var $n = 0.U64
	for turn in vector.turns {
		$n = $n + 1
		saved = $saved
		copy = |i| saved.get(i) ?? crash "table-changes: vector ${vector.seed.to_str()} names copy ${i.to_str()}, which was not kept"
		run_ops = |table, ops| ops.fold(table, |t, op| run_op(t, op_from(op), []))
		writes = turn.modifiers.map(
			|modifier| held.rows.update(
				|table| match modifier {
					On(ops) => run_ops(table, ops)
					Saved(i, ops) => run_ops(copy(i), ops)
					Other(i) => TableCore.with_id(copy(i), other_id)
					Fresh(rows) => start_table(rows)
				},
			),
		)
		$value = $value.after(writes)
		table = $value.read(held.rows)
		got = {
			rows: rows_of(table),
			record: match table.changes() {
				Rewritten => Rewritten
				Keyed(entries) => Keyed(entries.fold([], |acc, key, before| acc.append({ key, before })))
			},
			version: TableCore.version(table),
			start: TableCore.changes_start(table),
		}
		want = turn.outcome
		if got.rows != want.rows or record_text(got.record) != record_text(want.record) or got.version != want.version or got.start != want.start {
			return Err("vector ${vector.seed.to_str()}, turn ${$n.to_str()}: the table holds ${Str.inspect(got.rows)}, says ${record_text(got.record)}, counts ${got.version.to_str()} from ${got.start.to_str()}; Lean ${Str.inspect(want.rows)}, ${record_text(want.record)}, ${want.version.to_str()} from ${want.start.to_str()}")
		}
		$saved = if (turn.keep) $saved.append(table) else $saved
	}
	Ok({})
}

## Crash naming every vector a replay does not hold to.
vectors_hold : (ChangeVectors.Vector -> Try({}, Str)), Str -> Bool
vectors_hold = |replay, what| {
	wrong = ChangeVectors.vectors.keep_oks(
		|vector| match replay(vector) {
			Ok(_) => Err(Held)
			Err(problem) => Ok(problem)
		},
	)
	if !wrong.is_empty() {
		crash "fuzz/table-changes/vectors.txt, by the ${what}:\n${Str.join_with(wrong, "\n")}"
	}
	!ChangeVectors.vectors.is_empty()
}

## The model says what Lean says of every vector's turns.
expect vectors_hold(vector_model, "model")

## `TableCore` and the generated modifier do what Lean's transliteration of
## them does on every vector's turns.
expect vectors_hold(vector_code, "code")

## `events` are a session's bytes. Mode 0 runs the session, as every
## generated input does; mode 1 runs a seeded series of sessions instead;
## mode 2 replays the vector at index `events[0]` through the code.
Input : { mode : U8, events : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, events }| {
	if mode == 1 {
		Fuzz.expect_no_leaks!(|| series(200))
	} else if mode == 2 {
		Fuzz.expect_no_leaks!(
			|| {
				vector = match events {
					[at] => ChangeVectors.vectors.get(at.to_u64()) ?? crash "table-changes: no vector at ${at.to_str()}"
					_ => crash "table-changes: a vector replay names one index"
				}
				match vector_code(vector) {
					Ok(_) => {}
					Err(problem) => crash "table-changes: ${problem}"
				}
			},
		)
	} else {
		Fuzz.expect_no_leaks!(|| run(steps_of(events)))
	}
	Fuzz.keep
}

ex : Str, List(Step) -> Fuzz.Example(Input)
ex = |name, steps| Fuzz.example({ name, revision: "1", make: || { mode: 0, events: bytes_of(steps) } })

fuzz_target = Fuzz.target_with!({
	name: "table-changes",
	examples: written_cases.map(|written| ex(written.name, written.steps)).append(Fuzz.example({ name: "series", revision: "1", make: || { mode: 1, events: [] } })).concat(ChangeVectors.vectors.map_with_index(|vector, at| Fuzz.example({ name: "vector-${vector.seed.to_str()}", revision: "1", make: || { mode: 2, events: [at.to_u8_wrap()] } }))),
	generator: { mode: Fuzz.constant(0), events: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: |{ mode, events }| if (mode == 1) "a seeded series" else if (mode == 2) "vector ${Str.inspect(events)}" else Str.inspect(steps_of(events)),
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzTableChangesProperty := [].{
	target = fuzz_target
}
