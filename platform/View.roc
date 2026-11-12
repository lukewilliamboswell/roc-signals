import EngineOnly
import Seq
import Table

## A filtered, sorted, windowed view of a table, kept up to date from
## the table's record of changes, never by filtering, sorting or comparing
## the whole table again. It is the storage of an `Engine.each_view` site.
##
## A view holds the ordered keys of the rows that pass `keep`, each with the
## sort value it was placed by (`Seq`), the window (`start`, `count`) and the
## entries of the rows drawn: what the window showed when it was last drawn.
## The view's state is owned by the site that holds it, apart from the table.
##
## A site brings a view up to date in two steps. `follow` reads the table's
## record. For each written key it computes the key's place under the old row
## (from the record) and under the new row (from the table). If both are the
## same place, nothing in the sequence is touched. Otherwise the key is removed
## and reinserted: a binary search over the chunks and within one chunk, and a
## move within the chunk. The rows drawn are left as they were. `draw` then
## changes them, once, for whatever the turn changed (the table, the query, the
## window): its changes are a diff of the rows drawn before against the window
## now, which costs the two windows. A site that finds no write at or before
## its window's last row, and the same query and window, does not draw.
##
## The order must be total: `compare` must never answer `Same` for two
## different rows, so a sort value includes the key when the sorted field can
## tie. Two rows comparing `Same` is a contract error.
View(k, v, s) :: {
	query : { keep : k, v -> Bool, sort : k, v -> s, compare : s, s -> [Before, Same, After] },
	seq : Seq(k, s),
	window : { start : U64, count : U64 },
	shown : List({ sort : s, key : k }),
	version : U64,
}.{

	## Build a view from scratch, in the size of the table: a pass to filter
	## and a sort of what is kept. `limit` is the chunk size of the ordered
	## keys (see `Seq`).
	build : Table(k, v), { query : { keep : k, v -> Bool, sort : k, v -> s, compare : s, s -> [Before, Same, After] }, window : { start : U64, count : U64 }, limit : U64 } -> View(k, v, s)
	build = |table, { query, window, limit }| {
		seq = scratch(table, query, limit)
		{ query, seq, window, shown: seq.slice(window), version: table.version(engine) }
	}

	## Bring the ordered keys up to date with the table, leaving the rows
	## drawn as they were: `draw` changes those, once the site knows the
	## query and the window the turn leaves.
	##
	## The view absorbs the record when it has seen exactly the version the
	## record starts at and the record is small next to the table. It builds
	## its ordered keys again when the record is large (`Many`), when a bulk
	## write replaced the rows (`Rewritten`), or when it missed writes
	## (`Behind`): a missed refresh is repaired at the cost of a rebuild, and
	## reported so the engine can treat it as the contract error it is.
	##
	## `placed` counts the rows whose place was worked out with the query's
	## `keep` and `sort`: two for each written key it absorbed (its row
	## before and after), or every row of the table for a rebuild. The engine
	## counts each as one evaluation.
	##
	## `reached` says whether the rows drawn may no longer be the window: a
	## rebuild, or a row that entered, left or moved at or before the
	## window's last row. The site then draws. When it does not, `touched`
	## are the rows drawn whose row was written in place, which it marks.
	## `wrote` is what `draw` needs of the record: which rows were written.
	follow : View(k, v, s), Table(k, v) -> { view : View(k, v, s), how : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])], placed : U64, reached : Bool, touched : List(k), wrote : [NoRow, Rows(Dict(k, [Absent, Was(v)])), EveryRow] }
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	follow = |view, table|
		if view.version == table.version(engine) {
			{ view, how: Unchanged, placed: 0, reached: False, touched: [], wrote: NoRow }
		} else if view.version != table.changes_start(engine) {
			{ view: resorted(view, table), how: Rebuilt(Behind), placed: table.len(), reached: True, touched: [], wrote: EveryRow }
		} else {
			match table.changes() {
				Rewritten => { view: resorted(view, table), how: Rebuilt(Rewritten), placed: table.len(), reached: True, touched: [], wrote: EveryRow }
				Keyed(record) =>
					if record.len() * rebuild_ratio > table.len() + rebuild_floor {
						{ view: resorted(view, table), how: Rebuilt(Many), placed: table.len(), reached: True, touched: [], wrote: Rows(record) }
					} else {
						absorbed = absorb(view, table, record)
						{ view: absorbed.view, how: Absorbed, placed: absorbed.placed, reached: absorbed.reached, touched: absorbed.touched, wrote: Rows(record) }
					}
			}
		}

	## Draw `window` of the view: the one change of the rows drawn that a
	## turn makes, whatever it changed. The changes say which rows left,
	## which entered and where, which moved, and which of the rows drawn
	## before and after had their row written (`wrote`, from `follow`).
	## Applied in order to the rows drawn before, they give the window. A
	## row drawn before and after is never in `Left` or `Entered`, so it
	## keeps what is its own.
	##
	## `query` is `New` when the filter or the order changed: the ordered
	## keys are then built again, in the size of the table. The view must be
	## up to date with the table first (`follow`). With the same query the
	## cost is a pass over the chunk sizes and the two windows.
	draw : View(k, v, s), Table(k, v), { query : [Same, New({ keep : k, v -> Bool, sort : k, v -> s, compare : s, s -> [Before, Same, After] })], window : { start : U64, count : U64 }, wrote : [NoRow, Rows(Dict(k, [Absent, Was(v)])), EveryRow] } -> { view : View(k, v, s), changes : List([Left(k), Entered({ key : k, before : [Row(k), End] }), Moved({ key : k, before : [Row(k), End] }), Changed(k)]) }
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	draw = |view, table, { query: asked, window, wrote }|
		if view.version != table.version(engine) {
			crash "View.draw: follow the table before drawing the view"
		} else {
			{ query: held, seq: old_seq, shown, version, .. } = view
			(query, seq) = match asked {
				Same => (held, old_seq)
				New(next) => (next, scratch(table, next, old_seq.limit_of()))
			}
			next_shown = seq.slice(window)
			changes = match wrote {
				NoRow => window_changes(shown.map(|e| e.key), next_shown.map(|e| e.key), |_| False)
				Rows(record) => window_changes(shown.map(|e| e.key), next_shown.map(|e| e.key), |key| record.contains(key))
				EveryRow => window_changes(shown.map(|e| e.key), next_shown.map(|e| e.key), |_| True)
			}
			{ view: { query, seq, window, shown: next_shown, version }, changes }
		}

	## The rows just before and just after `key` in the view, as their keys and
	## sort values: what giving a row a place between two others needs. The
	## view must be up to date with the table, and `key` must be in it. Costs a
	## lookup and two binary searches.
	neighbours : View(k, v, s), Table(k, v), k -> { before : Try({ sort : s, key : k }, [First]), after : Try({ sort : s, key : k }, [Last]) }
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	neighbours = |view, table, key| {
		{ keep, sort, compare } = view.query
		row = match table.get(key) {
			Ok(r) => r
			Err(Missing) => crash "View.neighbours: the key has no row"
		}
		if view.version != table.version(engine) or !keep(key, row) {
			crash "View.neighbours: the view is behind the table, or the row is not in it"
		} else {
			view.seq.neighbours(sort(key, row), compare)
		}
	}

	## The keys in the window, in order.
	shown_keys : View(k, v, s) -> List(k)
	shown_keys = |view| view.shown.map(|e| e.key)

	## Every key in the view, in order: for tests.
	keys : View(k, v, s) -> List(k)
	keys = |view| view.seq.to_list().map(|e| e.key)

	## The window: the position of its first row and how many rows it holds.
	window_of : View(k, v, s) -> { start : U64, count : U64 }
	window_of = |view| view.window

	## The version of the table the view is up to date with.
	version : View(k, v, s) -> U64
	version = |view| view.version

	## The number of rows that pass the filter.
	len : View(k, v, s) -> U64
	len = |view| view.seq.len()

	## The number of chunks holding the ordered keys, for measuring.
	chunk_count : View(k, v, s) -> U64
	chunk_count = |view| view.seq.chunk_count()

	## Apply window changes to a list of keys: the oracle a test holds the
	## changes to, and what the engine does to its rows.
	apply_changes : List(k), List([Left(k), Entered({ key : k, before : [Row(k), End] }), Moved({ key : k, before : [Row(k), End] }), Changed(k)]) -> List(k)
		where [k.is_eq : k, k -> Bool]
	apply_changes = |start_keys, changes| changes.fold(
		start_keys,
		|current, change| match change {
			Left(key) => current.drop_if(|x| x == key)
			Entered({ key, before }) => place(current, key, before)
			Moved({ key, before }) => place(current.drop_if(|x| x == key), key, before)
			Changed(_) => current
		},
	)
}

## The value the table's bookkeeping asks for (`EngineOnly`).
engine : EngineOnly
engine = EngineOnly.witness({})

## A record larger than the table's size divided by this, plus the floor, is
## cheaper to rebuild from than to absorb: absorbing costs a search and a
## move in the ordered keys for each written row, and rebuilding one pass
## over the table and one sort. The table's size is what a rebuild costs,
## however few of its rows the view keeps.
rebuild_ratio : U64
rebuild_ratio = 8

rebuild_floor : U64
rebuild_floor = 64

place : List(k), k, [Row(k), End] -> List(k) where [k.is_eq : k, k -> Bool]
place = |keys, key, before| match before {
	End => keys.append(key)
	Row(anchor) =>
		match keys.find_first_index(|x| x == anchor) {
			Ok(at) =>
				match keys.insert(at, key) {
					Ok(placed) => placed
					Err(_) => crash "View.place: index"
				}
			Err(_) => crash "View.place: the anchor row is not in the window"
		}
}

## The ordered entries of the rows that pass the query's filter.
scratch : Table(k, v), { keep : k, v -> Bool, sort : k, v -> s, compare : s, s -> [Before, Same, After] }, U64 -> Seq(k, s)
scratch = |table, { keep, sort, compare }, limit| {
	kept = table.fold(
		List.with_capacity(table.len()),
		|acc, key, row| if (keep(key, row)) acc.append({ sort: sort(key, row), key }) else acc,
	)
	sorted = kept.sort_with(|a, b| compare(a.sort, b.sort))
	var $i = 1
	while $i < sorted.len() {
		tie = match (sorted.get($i - 1), sorted.get($i)) {
			(Ok(a), Ok(b)) => compare(a.sort, b.sort) == Same
			_ => crash "View.scratch: index"
		}
		if tie {
			crash "contract: two rows of a view compare Same; a view's order must be total, so its sort value must break ties by key"
		} else {
			{}
		}
		$i = $i + 1
	}
	Seq.from_sorted(sorted, limit)
}

## The view with its ordered keys built again from the table, at the table's
## version. The rows drawn are left as they were.
resorted : View(k, v, s), Table(k, v) -> View(k, v, s)
resorted = |view, table| {
	{ query, seq: old_seq, window, shown, .. } = view
	{ query, seq: scratch(table, query, old_seq.limit_of()), window, shown, version: table.version(engine) }
}

absorb : View(k, v, s), Table(k, v), Dict(k, [Absent, Was(v)]) -> { view : View(k, v, s), reached : Bool, touched : List(k), placed : U64 }
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
absorb = |view, table, record| {
	{ query, seq, window, shown, .. } = view
	{ keep, sort, compare } = query
	full = shown.len() >= window.count
	first = shown.first()
	last = shown.last()
	# A change at or before the window's last row shifts or changes the
	# window; one after it cannot, unless the window is not full.
	reaches_window = |at| if (full)
		match last {
			Ok(boundary) => compare(at, boundary.sort) != After
			Err(_) => True
		}
	else
		True
	in_window = |at| match (first, last) {
		(Ok(low), Ok(high)) => compare(low.sort, at) != After and compare(at, high.sort) != After
		_ => False
	}
	placed = |key, row| if (keep(key, row)) Placed(sort(key, row)) else Out
	step = record.fold(
		{ seq, moved: False, touched: [], placed: 0 },
		|acc, key, before| {
			(old, was) = match before {
				Was(row) => (placed(key, row), 1)
				Absent => (Out, 0)
			}
			(new, is) = match table.get(key) {
				Ok(row) => (placed(key, row), 1)
				Err(Missing) => (Out, 0)
			}
			count = acc.placed + was + is
			match (old, new) {
				(Placed(a), Placed(b)) =>
					if compare(a, b) == Same {
						{ seq: acc.seq, moved: acc.moved, touched: if (in_window(b)) acc.touched.append(key) else acc.touched, placed: count }
					} else {
						{
							seq: acc.seq.remove(a, compare).insert({ sort: b, key }, compare),
							moved: acc.moved or reaches_window(a) or reaches_window(b),
							touched: acc.touched,
							placed: count,
						}
					}
				(Placed(a), Out) => { seq: acc.seq.remove(a, compare), moved: acc.moved or reaches_window(a), touched: acc.touched, placed: count }
				(Out, Placed(b)) => { seq: acc.seq.insert({ sort: b, key }, compare), moved: acc.moved or reaches_window(b), touched: acc.touched, placed: count }
				(Out, Out) => { seq: acc.seq, moved: acc.moved, touched: acc.touched, placed: count }
			}
		},
	)
	{ view: { query, seq: step.seq, window, shown, version: table.version(engine) }, reached: step.moved, touched: if (step.moved) [] else step.touched, placed: step.placed }
}

## The changes that turn the window `old` into `new`: `Left` for rows that
## left, then `Entered` and `Moved` from the first row to the last, each placed
## before the next row that stays put (or at the end), then `Changed` for rows
## in both windows that `is_changed`. Rows that enter together are therefore
## created in the view's order, as the rows of a mount are. Rows on a longest
## increasing run of the old order stay put, so a row moving within the window
## is one `Moved`. Costs the size of the two windows.
window_changes : List(k), List(k), (k -> Bool) -> List([Left(k), Entered({ key : k, before : [Row(k), End] }), Moved({ key : k, before : [Row(k), End] }), Changed(k)])
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
window_changes = |old, new, is_changed| {
	new_at = new.fold({ at: Dict.with_capacity(new.len()), next: 0 }, |acc, key| { at: acc.at.insert(key, acc.next), next: acc.next + 1 }).at
	old_set = Set.from_list(old)
	lefts = old.keep_if(|key| !new_at.contains(key)).map(|key| Left(key))
	retained = old.keep_if(|key| new_at.contains(key))
	positions = retained.map(|key| new_at.get(key) ?? crash "View.window_changes: a retained key has no position")
	staying = Set.from_list(longest_run(positions).map(|i| retained.get(i) ?? crash "View.window_changes: index"))
	# The row each position is placed before: the next row after it that
	# stays put, or the end. Found from the last row to the first, so
	# `anchors` is in reverse.
	var $anchors = List.with_capacity(new.len())
	var $anchor = End
	var $i = new.len()
	while $i > 0 {
		$i = $i - 1
		key = new.get($i) ?? crash "View.window_changes: index"
		$anchors = $anchors.append($anchor)
		if staying.contains(key) {
			$anchor = Row(key)
		}
	}
	var $placed = []
	var $j = 0
	while $j < new.len() {
		key = new.get($j) ?? crash "View.window_changes: index"
		before = $anchors.get(new.len() - 1 - $j) ?? crash "View.window_changes: anchor"
		if !old_set.contains(key) {
			$placed = $placed.append(Entered({ key, before }))
		} else if !staying.contains(key) {
			$placed = $placed.append(Moved({ key, before }))
		} else {
			{}
		}
		$j = $j + 1
	}
	changed = new.keep_if(|key| old_set.contains(key) and is_changed(key)).map(|key| Changed(key))
	lefts.concat($placed).concat(changed)
}

## The indices of a longest strictly increasing subsequence of `values`.
longest_run : List(U64) -> List(U64)
longest_run = |values| {
	none = U64.highest
	var $tails = []
	var $previous = List.repeat(none, values.len())
	var $i = 0
	while $i < values.len() {
		value = values.get($i) ?? crash "View.longest_run: index"
		var $lo = 0
		var $hi = $tails.len()
		while $lo < $hi {
			mid = $lo + ($hi - $lo) // 2
			tail = values.get($tails.get(mid) ?? crash "View.longest_run: tail") ?? crash "View.longest_run: value"
			if tail < value {
				$lo = mid + 1
			} else {
				$hi = mid
			}
		}
		if $lo > 0 {
			$previous = $previous.set($i, $tails.get($lo - 1) ?? crash "View.longest_run: tail") ?? crash "View.longest_run: index"
		} else {
			{}
		}
		$tails = if ($lo == $tails.len()) $tails.append($i) else $tails.set($lo, $i) ?? crash "View.longest_run: tail"
		$i = $i + 1
	}
	var $out = []
	var $at = $tails.last() ?? none
	while $at != none {
		$out = $out.append($at)
		$at = $previous.get($at) ?? crash "View.longest_run: index"
	}
	$out.rev()
}

## The keys `lo` up to `hi`, as rows of a table whose row is its key.
numbered : U64, U64 -> List({ key : U64, row : U64 })
numbered = |lo, hi| {
	var $out = List.with_capacity(hi - lo)
	var $i = lo
	while $i < hi {
		$out = $out.append({ key: $i, row: $i })
		$i = $i + 1
	}
	$out
}

## Every row, or the rows whose key is below `below`, in the order of their
## keys.
by_key : U64 -> { keep : U64, U64 -> Bool, sort : U64, U64 -> U64, compare : U64, U64 -> [Before, Same, After] }
by_key = |below| {
	keep: |key, _| key < below,
	sort: |key, _| key,
	compare: |a, b| if (a < b) Before else if (a > b) After else Same,
}

## Rows that enter together are placed from the first to the last, each
## before the next row that stays put, and a row that moves is one move.
expect {
	entered = window_changes([1.U64, 2, 3], [7, 1, 8, 9, 2, 3, 10], |_| False)
	moved = window_changes([1.U64, 2, 3, 4], [4, 1, 2, 3], |key| key == 2)
	entered == [Entered({ key: 7, before: Row(1) }), Entered({ key: 8, before: Row(2) }), Entered({ key: 9, before: Row(2) }), Entered({ key: 10, before: End })]
		and View.apply_changes([1, 2, 3], entered) == [7, 1, 8, 9, 2, 3, 10]
		and moved == [Moved({ key: 4, before: Row(1) }), Changed(2)]
		and View.apply_changes([1, 2, 3, 4], moved) == [4, 1, 2, 3]
}

## One event that inserts a row above the window and moves the window down
## by one draws the same rows: a single draw changes nothing, where a draw
## for the table and another for the window would remove a row and create
## it again.
expect {
	table = Table.from_list(numbered(10, 20))
	view = View.build(table, { query: by_key(U64.highest), window: { start: 0, count: 4 }, limit: 8 })
	written = table.insert(5, 5)
	followed = view.follow(written)
	once = followed.view.draw(written, { query: Same, window: { start: 1, count: 4 }, wrote: followed.wrote })
	first = followed.view.draw(written, { query: Same, window: { start: 0, count: 4 }, wrote: followed.wrote })
	second = first.view.draw(written, { query: Same, window: { start: 1, count: 4 }, wrote: NoRow })
	followed.reached
		and once.changes == []
		and once.view.shown_keys() == [10, 11, 12, 13]
		and first.changes == [Left(13), Entered({ key: 5, before: Row(10) })]
		and second.changes == [Left(5), Entered({ key: 13, before: End })]
}

## A view that keeps few rows of a larger table absorbs a record of all of
## them: what a rebuild costs is the table, so the record is weighed against
## the table. A record large next to the table is rebuilt from.
expect {
	table = Table.from_list(numbered(0, 200))
	view = View.build(table, { query: by_key(10), window: { start: 0, count: U64.highest }, limit: 8 })
	few = numbered(0, 10).fold(table, |acc, { key, row }| acc.put(key, row + 1))
	many = numbered(0, 40).fold(table, |acc, { key, row }| acc.put(key, row + 1))
	absorbed = view.follow(few)
	rebuilt = view.follow(many)
	absorbed.how == Absorbed
		and absorbed.placed == 20
		and absorbed.touched == numbered(0, 10).map(|e| e.key)
		and rebuilt.how == Rebuilt(Many)
		and rebuilt.placed == 200
}
