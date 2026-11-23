import fz.Fuzz
import pf.TableCore exposing [Table]
import pf.View
import FollowVectors

## A table view kept from its table's changes, held to a filter, a sort and
## a slice of a plain list: bytes decode into turns over one table cell and
## one view of it, and after every turn the view's ordered keys, its window
## and the rows its site draws must be the model's, reached in one change.
##
## The table holds up to 24 keys, and the view's ordered keys are held in
## chunks of four (`limit: 4`), so a session splits and merges chunks. A turn
## is, in order:
## - a write of the table through what a table cell's generated modifier
##   does (`begin_changes`, the function, `kept`, then `finish_changes` when
##   the turn ends): keyed operations, runs of puts and removes long enough
##   that the view rebuilds rather than absorbs (`Many`), `update_all`, or a
##   new table from `from_list` followed by keyed operations (`Rewritten`);
## - a change of the view's query (which rows, in what order) and of its
##   window, each optional, read by the site in the same pass;
## - or the site sitting the turn out, so that the next turn finds the view
##   behind its table (`Behind`), which the engine never does but `follow`
##   must answer.
## The site does what an `Engine.table_view` site does on `Changed`: `follow`
## the table, read the query and the window, and `draw` once if anything
## reached the rows drawn.
##
## After every turn the site takes part in:
## - the ordered keys are the rows the query keeps, in its order, and the
##   window shows the slice of them the window names; the view is at the
##   table's count;
## - the rows drawn, the rows drawn before with the turn's changes applied,
##   are that slice;
## - the rows entered and left are exactly the keys the slice gained and
##   lost, once each, so a row in both is never removed and created again;
##   a row moved is one in both, and the moves are the rows in both off one
##   longest run that kept its order;
## - the rows marked changed are exactly the rows in both whose row the turn
##   wrote (every one after a rebuild for a whole rewrite or missed writes);
## - `follow` says how it brought the view up to date as the model expects,
##   and absorbing places at most two rows for each written key.
## A seeded series must reach `Absorbed` and each reason to rebuild.

# ------------------------------------------------------------------ steps

Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), Fill(U64, U64), Clear(U64, U64), All]

## A view's window: `count` is 0 to 8, or every row from `start` on.
Window : { start : U64, count : U64 }

## One turn. `query` and `window` are what the pass brings, if the turn
## changes them; `fresh` starts the table's write from a new table; `ops`
## follow it. A turn with neither writes the table not at all.
Step : { skip : Bool, query : Try(U64, [Same]), window : Try(Window, [Same]), fresh : Try(U64, [Kept]), ops : List(Op) }

key_space : U64
key_space = 24

row_space : U64
row_space = 8

bump : U64 -> U64
bump = |row| (row + 1) % row_space

## The rows `from_list` builds for `Fresh(seed)`.
fresh_rows : U64 -> List((U64, U64))
fresh_rows = |seed| range(0, key_space).keep_if(|key| (seed * 7 + key * 13) % 3 == 0).map(|key| (key, (seed + key) % row_space))

range : U64, U64 -> List(U64)
range = |lo, hi| {
	var $out = []
	var $i = lo
	while $i < hi {
		$out = $out.append($i)
		$i = $i + 1
	}
	$out
}

## The keys a run starting at `key` covers.
run_of : U64, U64 -> List(U64)
run_of = |key, n| range(0, n).map(|i| (key + i) % key_space)

## A window's count from its code: 0 to 8, or every row.
count_of : U64 -> U64
count_of = |code| if (code >= 9) U64.highest else code

code_of : U64 -> U64
code_of = |count| if (count == U64.highest) 9 else count

first_rows : List((U64, U64))
first_rows = range(0, 10).map(|key| ((key * 5) % key_space, key % row_space)).sort_with(by_key)

first_window : Window
first_window = { start: 1, count: 4 }

# ---------------------------------------------------------------- queries

## The four queries a session moves between. Each order is total: its sort
## value ends in the key.
Plan : { keep : U64, U64 -> Bool, sort : U64, U64 -> (U64, U64), compare : (U64, U64), (U64, U64) -> [Before, Same, After] }

ascending : (U64, U64), (U64, U64) -> [Before, Same, After]
ascending = |(a1, a2), (b1, b2)| if (a1 < b1) Before else if (a1 > b1) After else if (a2 < b2) Before else if (a2 > b2) After else Same

descending : (U64, U64), (U64, U64) -> [Before, Same, After]
descending = |a, b| ascending(b, a)

plan : U64 -> Plan
plan = |q| match q % 4 {
	0 => { keep: |_, _| Bool.True, sort: |key, _| (0, key), compare: ascending }
	1 => { keep: |_, row| row % 2 == 0, sort: |key, row| (row, key), compare: ascending }
	2 => { keep: |_, _| Bool.True, sort: |key, row| (row, key), compare: descending }
	_ => { keep: |_, row| row >= 2, sort: |key, _| (0, key), compare: descending }
}

# ------------------------------------------------------------- the codec

byte : List(U8), U64 -> Try(U64, [End])
byte = |bytes, at| match bytes.get(at) {
	Ok(b) => Ok(b.to_u64())
	Err(_) => Err(End)
}

## Read the turns the bytes hold; a turn cut short by the end is dropped.
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

step_at : List(U8), U64 -> Try({ step : Step, next : U64 }, [End])
step_at = |bytes, at| {
	head = byte(bytes, at)?
	var $next = at + 1
	query =
		if (head // 2) % 2 == 1 {
			q = byte(bytes, $next)?
			$next = $next + 1
			Ok(q % 4)
		} else {
			Err(Same)
		}
	window =
		if (head // 4) % 2 == 1 {
			start = byte(bytes, $next)?
			code = byte(bytes, $next + 1)?
			$next = $next + 2
			Ok({ start: start % 12, count: count_of(code % 10) })
		} else {
			Err(Same)
		}
	fresh =
		if (head // 8) % 2 == 1 {
			seed = byte(bytes, $next)?
			$next = $next + 1
			Ok(seed)
		} else {
			Err(Kept)
		}
	count = (head // 16) % 8
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
			5 => Fill(key, 4 + 2 * row)
			6 => Clear(key, 4 + 2 * row)
			_ => All
		}
		$ops = $ops.append(op)
		$next = $next + 2
		$i = $i + 1
	}
	Ok({ step: { skip: head % 2 == 1, query, window, fresh, ops: $ops }, next: $next })
}

## The bytes a session is written as: what `steps_of` reads back.
bytes_of : List(Step) -> List(U8)
bytes_of = |steps| steps.fold([], |out, step| step_bytes(out, step))

step_bytes : List(U8), Step -> List(U8)
step_bytes = |out, step| {
	flag = |b, n| if (b) n else 0
	head = flag(step.skip, 1) + flag(step.query.is_ok(), 2) + flag(step.window.is_ok(), 4) + flag(step.fresh.is_ok(), 8) + 16 * step.ops.len()
	with_query = match step.query {
		Ok(q) => out.append(head.to_u8_wrap()).append(q.to_u8_wrap())
		Err(Same) => out.append(head.to_u8_wrap())
	}
	with_window = match step.window {
		Ok({ start, count }) => with_query.append(start.to_u8_wrap()).append(code_of(count).to_u8_wrap())
		Err(Same) => with_query
	}
	with_fresh = match step.fresh {
		Ok(seed) => with_window.append(seed.to_u8_wrap())
		Err(Kept) => with_window
	}
	arg = |key, row| (key + key_space * row).to_u8_wrap()
	step.ops.fold(
		with_fresh,
		|acc, op| {
			(kind, a) = match op {
				Insert(k, r) => (0, arg(k, r))
				Put(k, r) => (1, arg(k, r))
				Replace(k, r) => (2, arg(k, r))
				Update(k) => (3, arg(k, 0))
				Remove(k) => (4, arg(k, 0))
				Fill(k, n) => (5, arg(k, (n - 4) // 2))
				Clear(k, n) => (6, arg(k, (n - 4) // 2))
				All => (7, 0)
			}
			acc.append(kind).append(a)
		},
	)
}

# --------------------------------------------------------------- the model

by_key : (U64, U64), (U64, U64) -> [Before, Same, After]
by_key = |(a, _), (b, _)| if (a < b) Before else if (a > b) After else Same

rget : List((U64, U64)), U64 -> Try(U64, [Missing])
rget = |rows, key| match rows.find_first(|(k, _)| k == key) {
	Ok((_, row)) => Ok(row)
	Err(_) => Err(Missing)
}

## The model's rows within a turn, with the keys written and whether the
## table was rewritten whole.
Written : { rows : List((U64, U64)), keys : List(U64), whole : Bool }

note : Written, U64, Try(U64, [Missing]) -> Written
note = |t, key, after| {
	without = t.rows.drop_if(|(k, _)| k == key)
	rows = match after {
		Ok(row) => without.append((key, row)).sort_with(by_key)
		Err(Missing) => without
	}
	{ ..t, rows, keys: if (t.keys.contains(key)) t.keys else t.keys.append(key) }
}

model_op : Written, Op -> Written
model_op = |t, op| {
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
		Fill(k, n) => run_of(k, n).fold(t, |acc, key| note(acc, key, Ok((key + n) % row_space)))
		Clear(k, n) => run_of(k, n).fold(t, |acc, key| if (rget(acc.rows, key).is_ok()) note(acc, key, Err(Missing)) else acc)
		All => { ..t, rows: t.rows.map(|(k, r)| (k, bump(r))), whole: Bool.True }
	}
}

## The keys a query keeps, in its order: a filter and a sort of the rows.
spec_keys : U64, List((U64, U64)) -> List(U64)
spec_keys = |q, rows| plan_keys(plan(q), rows)

## The keys a plan keeps, in its order.
plan_keys : Plan, List((U64, U64)) -> List(U64)
plan_keys = |{ keep, sort, compare }, rows| {
	rows.keep_if(|(k, r)| keep(k, r)).map(|(k, r)| (sort(k, r), k)).sort_with(|(a, _), (b, _)| compare(a, b)).map(|(_, k)| k)
}

spec_window : List(U64), Window -> List(U64)
spec_window = |keys, { start, count }| keys.drop_first(start).take_first(count)

## Length of a longest strictly increasing subsequence, by the quadratic
## rule.
lis_length : List(U64) -> U64
lis_length = |values| {
	ends = values.fold([], |acc, x| acc.append((x, acc.keep_if(|(y, _)| y < x).fold(0, |m, (_, l)| if (l > m) l else m) + 1)))
	ends.fold(0, |m, (_, l)| if (l > m) l else m)
}

## A change of the rows drawn, applied to them.
Change : [Left(U64), Entered({ key : U64, before : [Row(U64), End] }), Moved({ key : U64, before : [Row(U64), End] }), Changed(U64)]

put_before : List(U64), U64, [Row(U64), End] -> Try(List(U64), Str)
put_before = |keys, key, before| match before {
	End => Ok(keys.append(key))
	Row(anchor) =>
		match keys.find_first_index(|x| x == anchor) {
			Ok(at) => Ok(keys.take_first(at).append(key).concat(keys.drop_first(at)))
			Err(_) => Err("a change places ${key.to_str()} before ${anchor.to_str()}, which is not drawn")
		}
}

apply_changes : List(U64), List(Change) -> Try(List(U64), Str)
apply_changes = |start, changes| {
	var $keys = start
	for change in changes {
		$keys = match change {
			Left(key) => $keys.drop_if(|x| x == key)
			Entered({ key, before }) => put_before($keys, key, before)?
			Moved({ key, before }) => put_before($keys.drop_if(|x| x == key), key, before)?
			Changed(_) => $keys
		}
	}
	Ok($keys)
}

# ------------------------------------------------------------- the session

## What a site holds between turns, beside the model.
Site : { view : View(U64, U64, (U64, U64)), q : U64, drawn : List(U64) }

## How a session's `follow` calls went: the tally the seeded series is
## held to.
Tally : { absorbed : U64, many : U64, rewritten : U64, behind : U64, unchanged : U64, split : U64 }

no_tally : Tally
no_tally = { absorbed: 0, many: 0, rewritten: 0, behind: 0, unchanged: 0, split: 0 }

sorted : List(U64) -> List(U64)
sorted = |keys| keys.sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)

## The table the cell holds at a session's start.
first_table : Table(U64, U64)
first_table = TableCore.with_id(TableCore.clear_changes(Table.from_list(first_rows.map(|(key, row)| { key, row })) ?? crash "view-follow: the first rows repeat a key"), 1)

run_op : Table(U64, U64), Op -> Table(U64, U64)
run_op = |table, op| match op {
	Insert(k, r) => table.insert(k, r)
	Put(k, r) => table.put(k, r)
	Replace(k, r) => table.replace(k, r)
	Update(k) => table.update(k, bump)
	Remove(k) => table.remove(k)
	Fill(k, n) => run_of(k, n).fold(table, |t, key| t.put(key, (key + n) % row_space))
	Clear(k, n) => run_of(k, n).fold(table, |t, key| t.remove(key))
	All => table.update_all(|_, r| bump(r))
}

## One turn's write of the table, as a table cell's modifier makes it.
write_table : Table(U64, U64), Step -> Table(U64, U64)
write_table = |table, step| {
	began = TableCore.begin_changes(table)
	mark = TableCore.mark(began)
	from = match step.fresh {
		Ok(seed) => Table.from_list(fresh_rows(seed).map(|(key, row)| { key, row })) ?? crash "view-follow: fresh rows repeat a key"
		Err(Kept) => began
	}
	TableCore.finish_changes(TableCore.kept(step.ops.fold(from, run_op), mark))
}

entered_key : Change -> Try(U64, [Other])
entered_key = |change| match change {
	Entered({ key, .. }) => Ok(key)
	_ => Err(Other)
}

left_key : Change -> Try(U64, [Other])
left_key = |change| match change {
	Left(key) => Ok(key)
	_ => Err(Other)
}

moved_key : Change -> Try(U64, [Other])
moved_key = |change| match change {
	Moved({ key, .. }) => Ok(key)
	_ => Err(Other)
}

changed_key : Change -> Try(U64, [Other])
changed_key = |change| match change {
	Changed(key) => Ok(key)
	_ => Err(Other)
}

## The rules after one turn the site took part in.
check : { site : Site, after : Site, changes : List(Change), how : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])], placed : U64, table : Table(U64, U64), rows : List((U64, U64)), window : Window, written : List(U64), every : Bool, want_how : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])], recorded : U64 } -> Try({}, Str)
check = |{ site, after, changes, how, placed, table, rows, window, written, every, want_how, recorded }| {
	keys = spec_keys(after.q, rows)
	shown = spec_window(keys, window)
	if after.view.keys() != keys {
		return Err("the view's ordered keys are ${Str.inspect(after.view.keys())}; the query keeps ${Str.inspect(keys)}")
	}
	if after.view.shown_keys() != shown or after.view.window_of() != window {
		return Err("the view shows ${Str.inspect(after.view.shown_keys())} through ${Str.inspect(after.view.window_of())}; the window ${Str.inspect(window)} holds ${Str.inspect(shown)}")
	}
	if after.view.version() != TableCore.version(table) {
		return Err("the view is at count ${after.view.version().to_str()}, its table at ${TableCore.version(table).to_str()}")
	}
	if after.drawn != shown {
		return Err("the site draws ${Str.inspect(after.drawn)}; the window holds ${Str.inspect(shown)}")
	}
	drawn_rules({ before: site.drawn, shown, changes, written, every })?
	if how != want_how {
		return Err("follow brought the view up to date by ${Str.inspect(how)}; the model expects ${Str.inspect(want_how)}")
	}
	if how == Absorbed and placed > 2 * recorded {
		return Err("absorbing ${recorded.to_str()} written keys placed ${placed.to_str()} rows")
	}
	Ok({})
}

## The rules for the changes of the rows drawn, from `before` to `shown`:
## rows entered and left once each, moves minimal, and the rows marked
## changed those in both the turn wrote (every one when `every`).
drawn_rules : { before : List(U64), shown : List(U64), changes : List(Change), written : List(U64), every : Bool } -> Try({}, Str)
drawn_rules = |{ before, shown, changes, written, every }| {
	entered = changes.keep_oks(entered_key)
	left = changes.keep_oks(left_key)
	moved = changes.keep_oks(moved_key)
	marked = changes.keep_oks(changed_key)
	both = before.keep_if(|k| shown.contains(k))
	if sorted(entered) != sorted(shown.drop_if(|k| before.contains(k))) or sorted(left) != sorted(before.drop_if(|k| shown.contains(k))) {
		return Err("the rows entered are ${Str.inspect(entered)} and left ${Str.inspect(left)}; from ${Str.inspect(before)} to ${Str.inspect(shown)} they are ${Str.inspect(shown.drop_if(|k| before.contains(k)))} and ${Str.inspect(before.drop_if(|k| shown.contains(k)))}")
	}
	if !moved.all(|k| both.contains(k)) or moved.len() != Set.from_list(moved).len() {
		return Err("the rows moved, ${Str.inspect(moved)}, are not each a row drawn before and after (${Str.inspect(both)}) once")
	}
	positions = both.map(|k| shown.find_first_index(|x| x == k) ?? 0)
	if moved.len() != both.len() - lis_length(positions) {
		return Err("${moved.len().to_str()} rows moved, where ${(both.len() - lis_length(positions)).to_str()} of ${Str.inspect(both)} are off a longest run of ${Str.inspect(shown)}")
	}
	want_marked = if (every) both else both.keep_if(|k| written.contains(k))
	if sorted(marked) != sorted(want_marked) {
		return Err("the rows marked changed are ${Str.inspect(marked)}; of the rows drawn before and after, the turn wrote ${Str.inspect(want_marked)}")
	}
	Ok({})
}

## How `follow` must bring a view up to date that last followed its table
## before `since`, the turns that wrote it since, and the turn whose changes
## it reads. A turn that wrote no row leaves the count; the next turn's first
## modifier still starts the changes again at the count. So the view reads
## the changes only when the one turn that changed rows is the last that ran
## a modifier; otherwise it has missed writes.
expected_how : List(Written) -> { how : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])], last : Written }
expected_how = |since| {
	none = { rows: [], keys: [], whole: Bool.False }
	last = since.last() ?? none
	changed = since.keep_if(|w| w.whole or !w.keys.is_empty())
	how =
		if changed.is_empty() {
			Unchanged
		} else if changed.len() > 1 or !(last.whole or !last.keys.is_empty()) {
			Rebuilt(Behind)
		} else if last.whole {
			Rebuilt(Rewritten)
		} else if last.keys.len() * 8 > last.rows.len() + 64 {
			Rebuilt(Many)
		} else {
			Absorbed
		}
	{ how, last }
}

## Run one session and give its tally; the first broken rule crashes with
## the turn it broke at.
run : List(Step) -> Tally
run = |steps| {
	var $table = first_table
	var $rows = first_rows
	var $site = { view: View.build(first_table, { query: plan(0), window: first_window, limit: 4, site: "view-follow" }), q: 0, drawn: spec_window(spec_keys(0, first_rows), first_window) }
	var $window = first_window
	# The turns that wrote the table since the site last followed it.
	var $since = []
	var $tally = no_tally
	var $n = 0
	for step in steps {
		writes = step.fresh.is_ok() or !step.ops.is_empty()
		start = {
			rows: match step.fresh {
				Ok(seed) => fresh_rows(seed).sort_with(by_key)
				Err(Kept) => $rows
			},
			keys: [],
			whole: step.fresh.is_ok(),
		}
		model = step.ops.fold(start, model_op)
		table = if (writes) write_table($table, step) else $table
		since = if (writes) $since.append(model) else $since
		if step.skip and writes {
			$since = since
		} else {
			q2 = step.query ?? $site.q
			w2 = step.window ?? $window
			recorded = match table.changes() {
				Keyed(record) => record.len()
				Rewritten => 0
			}
			{ how: want_how, last } = expected_how(since)
			# What an `Engine.table_view` site does on `Changed`.
			old = $site
			followed = old.view.follow(table)
			draws = followed.reached or (step.query.is_ok() and q2 != old.q) or (step.window.is_ok() and w2 != $window)
			(view, changes) =
				if !draws {
					(followed.view, followed.touched.map(|key| Changed(key)))
				} else if q2 == old.q {
					drawn = followed.view.draw(table, { query: Same, window: w2, wrote: followed.wrote })
					(drawn.view, drawn.changes)
				} else {
					drawn = followed.view.draw(table, { query: New(plan(q2)), window: w2, wrote: followed.wrote })
					(drawn.view, drawn.changes)
				}
			drawn_after = match apply_changes(old.drawn, changes) {
				Ok(keys) => keys
				Err(problem) => crash "view-follow: at turn ${$n.to_str()} (${Str.inspect(step)}): ${problem}"
			}
			after = { view, q: q2, drawn: drawn_after }
			every = want_how == Rebuilt(Behind) or want_how == Rebuilt(Rewritten)
			match check({ site: old, after, changes, how: followed.how, placed: followed.placed, table, rows: model.rows, window: w2, written: last.keys, every, want_how, recorded }) {
				Ok(_) => {}
				Err(problem) => crash "view-follow: at turn ${$n.to_str()} (${Str.inspect(step)}): ${problem}"
			}
			$tally = match followed.how {
				Absorbed => { ..$tally, absorbed: $tally.absorbed + 1 }
				Rebuilt(Many) => { ..$tally, many: $tally.many + 1 }
				Rebuilt(Rewritten) => { ..$tally, rewritten: $tally.rewritten + 1 }
				Rebuilt(Behind) => { ..$tally, behind: $tally.behind + 1 }
				Unchanged => { ..$tally, unchanged: $tally.unchanged + 1 }
			}
			$tally = if (view.chunk_count() >= 3) { ..$tally, split: $tally.split + 1 } else $tally
			$site = after
			$window = w2
			$since = []
		}
		$table = table
		$rows = model.rows
		$n = $n + 1
	}
	$tally
}

# ---------------------------------------------------------------- examples

## A turn that only writes the table.
writes : List(Op) -> Step
writes = |ops| { skip: Bool.False, query: Err(Same), window: Err(Same), fresh: Err(Kept), ops }

## A row inserted above the window in the event that moves the window down
## by one: one change of the rows drawn, which keeps every row.
one_change_steps : List(Step)
one_change_steps = [
	{ ..writes([Insert(1, 3)]), window: Ok({ start: 2, count: 4 }) },
	{ ..writes([Remove(1)]), window: Ok({ start: 1, count: 4 }) },
	{ ..writes([Put(4, 6), Put(9, 0)]), query: Ok(2), window: Ok({ start: 0, count: 5 }) },
]

## Absorbed writes inside, before and after the window; a run that rebuilds;
## a whole rewrite; a new table; and a turn the site sits out.
reasons_steps : List(Step)
reasons_steps = [
	writes([Update(5), Put(15, 7), Remove(20)]),
	writes([Fill(0, 18)]),
	writes([All]),
	{ ..writes([Insert(2, 1)]), fresh: Ok(5) },
	{ ..writes([Put(3, 3)]), skip: Bool.True },
	writes([Replace(3, 4)]),
	{ ..writes([]), window: Ok({ start: 0, count: U64.highest }) },
	writes([Clear(0, 18)]),
	writes([Fill(3, 10), Insert(23, 2)]),
]

## Chunks of four split and merge under inserts and removes across the
## order, with every row drawn.
chunks_steps : List(Step)
chunks_steps = [
	{ ..writes([Fill(0, 18)]), window: Ok({ start: 0, count: U64.highest }) },
	writes([Remove(3), Remove(4), Remove(5), Remove(6), Remove(7)]),
	writes([Insert(4, 1), Insert(5, 2), Insert(6, 3)]),
	{ ..writes([Update(0), Update(10), Update(17)]), query: Ok(1) },
	{ ..writes([Put(11, 0), Put(12, 4)]), query: Ok(3), window: Ok({ start: 3, count: 5 }) },
]

written_cases : List({ name : Str, steps : List(Step) })
written_cases = [
	{ name: "one-change", steps: one_change_steps },
	{ name: "reasons", steps: reasons_steps },
	{ name: "chunks", steps: chunks_steps },
]

expect written_cases.all(|written| steps_of(bytes_of(written.steps)) == written.steps)

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

## The tally of a seeded series of `count` sessions.
series : U64 -> Tally
series = |count| range(0, count).fold(
	no_tally,
	|acc, k| {
		t = run(steps_of(seeded(k + 1, 300)))
		{
			absorbed: acc.absorbed + t.absorbed,
			many: acc.many + t.many,
			rewritten: acc.rewritten + t.rewritten,
			behind: acc.behind + t.behind,
			unchanged: acc.unchanged + t.unchanged,
			split: acc.split + t.split,
		}
	},
)

## The seeded series reaches `Absorbed`, every reason to rebuild, an
## unchanged table and a view of three chunks or more.
expect {
	t = series(20)
	t.absorbed > 0 and t.many > 0 and t.rewritten > 0 and t.behind > 0 and t.unchanged > 0 and t.split > 0
}

## The written sessions reach each way `follow` answers.
expect {
	t = run(reasons_steps)
	t.absorbed > 0 and t.many > 0 and t.rewritten > 0 and t.behind > 0 and t.unchanged > 0
}

# ------------------------------------------------------------- the vectors

## The queries a vector names: 0 keeps
## every row by row then key, 1 the rows of 1 or more by row then key, 2
## every row by key descending.
vector_plan : U64 -> Plan
vector_plan = |q| match q {
	0 => { keep: |_, _| Bool.True, sort: |key, row| (row, key), compare: ascending }
	1 => { keep: |_, row| row >= 1, sort: |key, row| (row, key), compare: ascending }
	2 => { keep: |_, _| Bool.True, sort: |key, _| (0, key), compare: descending }
	_ => crash "view-follow: a vector names query ${q.to_str()}, which is not defined"
}

## A vector's operation as the session's; `undo` is not in its
## vocabulary, and no vector here holds one.
op_from : FollowVectors.Op -> Op
op_from = |op| match op {
	Insert(k, r) => Insert(k, r)
	Put(k, r) => Put(k, r)
	Replace(k, r) => Replace(k, r)
	Update(k) => Update(k)
	Remove(k) => Remove(k)
	All => All
	Undo => crash "view-follow: a vector holds an undo, which the model does not describe"
}

## `View.roc` fixes the rebuild thresholds; a vector with others cannot be
## replayed here.
fixed_thresholds : FollowVectors.Vector -> Try({}, Str)
fixed_thresholds = |vector|
	if vector.ratio == 8 and vector.floor == 64 {
		Ok({})
	} else {
		Err("vector ${vector.seed.to_str()} asks for rebuild thresholds ${vector.ratio.to_str()} and ${vector.floor.to_str()}; View.roc fixes 8 and 64")
	}

## A vector's record with its keys in order.
record_text : FollowVectors.Record -> Str
record_text = |record| match record {
	Rewritten => "rewritten"
	Keyed(entries) => Str.inspect(entries.sort_with(|a, b| if (a.key < b.key) Before else if (a.key > b.key) After else Same))
}

## An outcome as text, its record's keys in order.
outcome_text : FollowVectors.Outcome -> Str
outcome_text = |o| Str.inspect({ how: o.how, rows: o.rows, record: record_text(o.record), counts: (o.version, o.start), keys: o.keys, drawn: o.drawn, changes: o.changes })

## The model through a vector's turns, against the outcome each states:
## the rows, how `follow` must bring the view up to date, the ordered keys,
## the rows drawn, and the changes of the rows drawn by `drawn_rules`.
vector_model : FollowVectors.Vector -> Try({}, Str)
vector_model = |vector| {
	fixed_thresholds(vector)?
	var $rows = vector.rows.sort_with(by_key)
	var $q = vector.query
	var $window = vector.window
	var $drawn = spec_window(plan_keys(vector_plan($q), $rows), $window)
	var $saved = []
	var $n = 0.U64
	for turn in vector.turns {
		$n = $n + 1
		saved = $saved
		copy = |i| saved.get(i) ?? crash "view-follow: vector ${vector.seed.to_str()} names copy ${i.to_str()}, which was not kept"
		model = turn.modifiers.fold(
			{ rows: $rows, keys: [], whole: Bool.False },
			|w, modifier| match modifier {
				On(ops) => ops.map(op_from).fold(w, model_op)
				Saved(i, ops) => ops.map(op_from).fold({ ..w, rows: copy(i), whole: Bool.True }, model_op)
				Other(i) => { ..w, rows: copy(i), whole: Bool.True }
				Fresh(rows) => { ..w, rows: rows.sort_with(by_key), whole: Bool.True }
			},
		)
		q2 = turn.query ?? $q
		w2 = turn.window ?? $window
		keys = plan_keys(vector_plan(q2), model.rows)
		shown = spec_window(keys, w2)
		want_how = expected_how([model]).how
		want = turn.outcome
		at = "vector ${vector.seed.to_str()}, turn ${$n.to_str()}"
		if model.rows != want.rows or want_how != want.how or keys != want.keys or shown != want.drawn {
			return Err("${at}: the model holds ${Str.inspect(model.rows)}, follows by ${Str.inspect(want_how)}, orders ${Str.inspect(keys)} and draws ${Str.inspect(shown)}; the vector states ${Str.inspect(want.rows)}, ${Str.inspect(want.how)}, ${Str.inspect(want.keys)} and ${Str.inspect(want.drawn)}")
		}
		match apply_changes($drawn, want.changes) {
			Ok(after) if after == shown => {}
			Ok(after) => return Err("${at}: the vector's changes take the rows drawn from ${Str.inspect($drawn)} to ${Str.inspect(after)}, not ${Str.inspect(shown)}")
			Err(problem) => return Err("${at}: ${problem}")
		}
		every = want_how == Rebuilt(Behind) or want_how == Rebuilt(Rewritten)
		match drawn_rules({ before: $drawn, shown, changes: want.changes, written: model.keys, every }) {
			Ok(_) => {}
			Err(problem) => return Err("${at}: the vector's changes break a rule: ${problem}")
		}
		$saved = if (turn.keep) $saved.append(model.rows) else $saved
		$rows = model.rows
		$q = q2
		$window = w2
		$drawn = shown
	}
	Ok({})
}

## The identity a kept copy is handed under for `Other`: no cell's.
other_id : U64
other_id = 1000000

## The code through a vector's turns: the cell's modifier as `write_table`
## makes it, then what an `Engine.table_view` site does on `Changed`,
## against the outcome each states, write counts and the exact changes of
## the rows drawn included.
vector_code : FollowVectors.Vector -> Try({}, Str)
vector_code = |vector| {
	fixed_thresholds(vector)?
	start = TableCore.with_id(TableCore.clear_changes(Table.from_list(vector.rows.map(|(key, row)| { key, row })) ?? crash "view-follow: a vector's rows repeat a key"), 1)
	view0 = View.build(start, { query: vector_plan(vector.query), window: vector.window, limit: 4, site: "view-follow vectors" })
	var $table = start
	var $site = { view: view0, q: vector.query, drawn: view0.shown_keys() }
	var $window = vector.window
	var $saved = []
	var $n = 0.U64
	for turn in vector.turns {
		$n = $n + 1
		saved = $saved
		copy = |i| saved.get(i) ?? crash "view-follow: vector ${vector.seed.to_str()} names copy ${i.to_str()}, which was not kept"
		run_ops = |table, ops| ops.map(op_from).fold(table, run_op)
		written = turn.modifiers.fold(
			$table,
			|t0, modifier| {
				began = TableCore.begin_changes(t0)
				mark = TableCore.mark(began)
				out = match modifier {
					On(ops) => run_ops(began, ops)
					Saved(i, ops) => run_ops(copy(i), ops)
					Other(i) => TableCore.with_id(copy(i), other_id)
					Fresh(rows) => Table.from_list(rows.map(|(key, row)| { key, row })) ?? crash "view-follow: a vector's new table repeats a key"
				}
				TableCore.kept(out, mark)
			},
		)
		table = TableCore.finish_changes(written)
		q2 = turn.query ?? $site.q
		w2 = turn.window ?? $window
		old = $site
		followed = old.view.follow(table)
		draws = followed.reached or (turn.query.is_ok() and q2 != old.q) or (turn.window.is_ok() and w2 != $window)
		(view, changes) =
			if !draws {
				(followed.view, followed.touched.map(|key| Changed(key)))
			} else if q2 == old.q {
				drawn = followed.view.draw(table, { query: Same, window: w2, wrote: followed.wrote })
				(drawn.view, drawn.changes)
			} else {
				drawn = followed.view.draw(table, { query: New(vector_plan(q2)), window: w2, wrote: followed.wrote })
				(drawn.view, drawn.changes)
			}
		got = {
			how: followed.how,
			rows: table.to_list().map(|{ key, row }| (key, row)).sort_with(by_key),
			record: match table.changes() {
				Rewritten => Rewritten
				Keyed(entries) => Keyed(entries.fold([], |acc, key, before| acc.append({ key, before })))
			},
			version: TableCore.version(table),
			start: TableCore.changes_start(table),
			keys: view.keys(),
			drawn: View.apply_changes(old.drawn, changes),
			changes,
		}
		want = turn.outcome
		if outcome_text(got) != outcome_text(want) {
			return Err("vector ${vector.seed.to_str()}, turn ${$n.to_str()}: the code leaves ${outcome_text(got)}; the vector states ${outcome_text(want)}")
		}
		$saved = if (turn.keep) $saved.append(table) else $saved
		$table = table
		$site = { view, q: q2, drawn: got.drawn }
		$window = w2
	}
	Ok({})
}

## Crash naming every vector a replay does not hold to.
vectors_hold : (FollowVectors.Vector -> Try({}, Str)), Str -> Bool
vectors_hold = |replay, what| {
	wrong = FollowVectors.vectors.keep_oks(
		|vector| match replay(vector) {
			Ok(_) => Err(Held)
			Err(problem) => Ok(problem)
		},
	)
	if !wrong.is_empty() {
		crash "fuzz/view-follow/FollowVectors.roc, by the ${what}:\n${Str.join_with(wrong, "\n")}"
	}
	!FollowVectors.vectors.is_empty()
}

## The model leaves the outcome every vector's turns state.
expect vectors_hold(vector_model, "model")

## `TableCore`, `View` and the site's `Changed` leave the outcome every
## vector's turns state.
expect vectors_hold(vector_code, "code")

## `events` are a session's bytes. Mode 0 runs the session, as every
## generated input does; mode 1 with no events runs a seeded series of
## sessions instead; mode 2 with one event replays the vector that byte
## names through the code. Any other input, whatever its mode byte, runs
## the session, so exploration never repeats one fixed series.
Input : { mode : U8, events : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, events }| {
	if mode == 1 and events.is_empty() {
		Fuzz.expect_no_leaks!(|| series(200))
	} else if mode == 2 and events.len() == 1 {
		Fuzz.expect_no_leaks!(
			|| {
				# A declared example names its vector by index; an explored input
				# may name any number, counted round the list.
				at = (events.first() ?? 0).to_u64() % FollowVectors.vectors.len()
				vector = FollowVectors.vectors.get(at) ?? crash "view-follow: there are no vectors"
				match vector_code(vector) {
					Ok(_) => {}
					Err(problem) => crash "view-follow: ${problem}"
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
	name: "view-follow",
	examples: written_cases.map(|written| ex(written.name, written.steps)).append(Fuzz.example({ name: "series", revision: "1", make: || { mode: 1, events: [] } })).append(Fuzz.example({ name: "vector-index-past-end", revision: "1", make: || { mode: 2, events: [200] } })).concat(FollowVectors.vectors.map_with_index(|vector, at| Fuzz.example({ name: "vector-${vector.seed.to_str()}", revision: "1", make: || { mode: 2, events: [at.to_u8_wrap()] } }))),
	generator: { mode: Fuzz.constant(0), events: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: |{ mode, events }| if (mode == 1) "a seeded series" else if (mode == 2) "vector ${Str.inspect(events)}" else Str.inspect(steps_of(events)),
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzViewFollowProperty := [].{
	target = fuzz_target
}
