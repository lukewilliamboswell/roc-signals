app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Engine exposing [Elem, Signal, State, Table]

## Tables and their views: bytes decode into a session of events over one
## app, and after every event each view must draw what a model that filters,
## sorts and windows the table from scratch says it draws.
##
## The app holds two tables of at most 16 rows (`rows` and `spare`) and
## draws eight views of them, each placed differently:
## - `a`: its listing (which rows, what order) and its window are store cells;
## - `b`: its listing and window are one local state, written by a handler
##   composed with a decision, so one event writes the table's cell and a
##   layer below it, and the view must meet both together;
## - `e`: beside `b`, its listing and window a `derive` of `b`'s state, so
##   what it reads of that state is recomputed in the pass that brings the
##   table;
## - `c`: mounted and unmounted by a `when`, its listing computed from `a`'s;
## - `d`: the only view of `spare`, every row of it drawn
##   (`Engine.every_row`);
## - `lane 0` to `lane 2`: one view in each row of an `each`, whose list of
##   lanes is a cell, so views mount, move and unmount with their rows.
## Every row shows `key:rank:shade:marks`, where `marks` is a state of the
## row's own, and has buttons that write its row through the row's `State`,
## remove it through the table's cell, and write its marks and its row as
## one event.
##
## A step is a decision or a click on a drawn row:
## - a decision is one event whose payload names every write it makes: how
##   the table's cell is replaced first, if at all (a new table, the reset
##   of its group, a copy saved earlier, the other table), keyed writes in
##   order (insert, put, replace, update, remove; a run of up to 16 puts or
##   updates, which crosses the size at which a view rebuilds instead of
##   absorbing the changes; a whole rewrite by `load` or `update_all`; an
##   undo of the turn so far), as one `update` or one for each, a write of
##   `spare`, a copy of the table saved, `a`'s listing and window, the lanes
##   and whether `c` is mounted. It fires from a control whose handler is
##   the decision alone, one whose decision also reads the tables it may
##   copy, or `b`'s control, which writes `b`'s listing and window too;
## - a click presses a row's `mark`, `bump`, `tint`, `drop` or `both`.
##
## Oracles, after every step:
## - the engine is settled (`Core.settled`): no reader is stale, and every
##   view equals one built from scratch with its table's changes cleared;
## - each view is drawn exactly when the model has it mounted, and its rows'
##   texts, in order, are the model's: the rows its listing keeps, in its
##   order, inside its window;
## - a row is one row while its view's window holds it: a row the window
##   holds before the event and after it keeps its marks, and one that
##   enters starts without any, whatever the event wrote of the table, the
##   listing and the window;
## - the rows created are exactly those that entered a window, and the rows
##   moved are exactly those off a longest run that kept its order, so an
##   event changes the rows a view draws once and never by way of a window
##   it does not end with;
## - the readers of the row count and of the serial show the model's.
## The session frees everything it allocated.

# --------------------------------------------------------------------- rows

## One row: `rank` is what a listing orders by and `shade` what it filters on.
Item : { rank : U64, shade : U64 }

## A row with its key, as a table is built from.
Entry : { key : U64, row : Item }

## What a view shows: which rows and in what order. Plain data a view site
## compares. `ByRank` and `ByRankDown` order equal ranks by key, ascending.
Listing : { show : [All, Only(U64), Except(U64)], order : [ByKey, ByKeyDown, ByRank, ByRankDown] }

## Where a row stands in a listing's order: its order's number, then its key,
## so no two rows tie.
Place : { primary : I64, key : U64 }

## What `b` holds in its local state.
Local : { listing : Listing, window : Engine.Window }

## The keys a table can hold: small, so sessions collide on keys and windows
## sit at the edges of their views.
key_space : U64
key_space = 16

## 0, 1, ... `n - 1`.
span : U64 -> List(U64)
span = |n| {
	var $out = List.with_capacity(n)
	var $i = 0.U64
	while $i < n {
		$out = $out.append($i)
		$i = $i + 1
	}
	$out
}

## The row a number names, and the number that names a row.
item_of : U64 -> Item
item_of = |n| { rank: n % 8, shade: (n // 8) % 3 }

item_word : Item -> U64
item_word = |item| item.shade * 8 + item.rank

## A row changed in one of four ways; the last leaves it equal.
bumped : Item, U64 -> Item
bumped = |item, code| match code % 4 {
	0 => { ..item, rank: (item.rank + 1) % 8 }
	1 => { ..item, rank: (item.rank + 3) % 8 }
	2 => { ..item, shade: (item.shade + 1) % 3 }
	_ => item
}

## `count` rows (at most `key_space`) under distinct keys.
entries : U64, U64 -> List(Entry)
entries = |seed, count| span(count).map(|i| { key: (seed + i * 5) % key_space, row: item_of(seed + i * 3) })

## How a listing selects and orders rows: the `plan` of every view.
query_plan : Listing -> Engine.QueryPlan(U64, Item, Place)
query_plan = |{ show, order }| {
	keep: |_, item| match show {
		All => True
		Only(shade) => item.shade == shade
		Except(shade) => item.shade != shade
	},
	sort: |key, item| match order {
		ByKey => { primary: 0, key }
		ByKeyDown => { primary: 0 - key.to_i64_wrap(), key }
		ByRank => { primary: item.rank.to_i64_wrap(), key }
		ByRankDown => { primary: 0 - item.rank.to_i64_wrap(), key }
	},
	compare: compare_place,
}

compare_place : Place, Place -> [Before, Same, After]
compare_place = |x, y|
	if (x.primary < y.primary)
		Before
	else if (x.primary > y.primary)
		After
	else if (x.key < y.key)
		Before
	else if (x.key > y.key)
		After
	else
		Same

## The listing a number names: 5 filters by 4 orders.
listing_of : U64 -> Listing
listing_of = |n| {
	show: match n % 5 {
		0 => All
		1 => Only(0)
		2 => Only(1)
		3 => Only(2)
		_ => Except(0)
	},
	order: match (n // 5) % 4 {
		0 => ByKey
		1 => ByKeyDown
		2 => ByRank
		_ => ByRankDown
	},
}

listing_word : Listing -> U64
listing_word = |{ show, order }| {
	filter = match show {
		All => 0
		Only(0) => 1
		Only(1) => 2
		Only(2) => 3
		Except(0) => 4
		_ => crash "table-view: a listing no number names"
	}
	by = match order {
		ByKey => 0
		ByKeyDown => 1
		ByRank => 2
		ByRankDown => 3
	}
	filter + by * 5
}

## The same rows in the opposite order: what `c` shows of `a`'s listing.
turned : Listing -> Listing
turned = |{ show, order }| {
	show,
	order: match order {
		ByKey => ByKeyDown
		ByKeyDown => ByKey
		ByRank => ByRankDown
		ByRankDown => ByRank
	},
}

## Every list of lanes: the orders of every subset of the three shades.
lane_lists : List(List(U64))
lane_lists = [[], [0], [1], [2], [0, 1], [1, 0], [0, 2], [2, 0], [1, 2], [2, 1], [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

## What the views that never change it show: a lane the first three rows
## of its shade by rank, `c` three rows from the second, and `d` every row
## of the other table, highest rank first.
lane_listing : U64 -> Listing
lane_listing = |shade| { show: Only(shade), order: ByRank }

lane_window : Engine.Window
lane_window = { start: 0, count: 3 }

c_window : Engine.Window
c_window = { start: 1, count: 3 }

d_listing : Listing
d_listing = { show: All, order: ByRankDown }

d_window : Engine.Window
d_window = Engine.every_row

## What the app starts with. `rows` is described with one set of rows, which
## its group's reset puts back, and started with another.
described : List(Entry)
described = entries(3, 6)

first_rows : List(Entry)
first_rows = entries(0, 10)

first_spare : List(Entry)
first_spare = entries(9, 5)

first_listing : Listing
first_listing = { show: All, order: ByRank }

first_window : Engine.Window
first_window = { start: 0, count: 4 }

first_local : Local
first_local = { listing: { show: Except(0), order: ByKeyDown }, window: { start: 1, count: 3 } }

first_lanes : List(U64)
first_lanes = [0, 2]

# ---------------------------------------------------------------- decisions

## One write of a table. `Insert` of a key the table holds writes nothing;
## `Fill(from, count, seed)` puts `count` consecutive keys and
## `Sweep(from, count, code)` updates them; `Load` and `All` replace every
## row; `Undo` applies the inverse of what the turn has written so far.
Op : [
	Insert(U64, Item),
	Put(U64, Item),
	Replace(U64, Item),
	Update(U64, U64),
	Remove(U64),
	Fill(U64, U64, U64),
	Sweep(U64, U64, U64),
	Load(U64, U64),
	All(U64),
	Undo,
]

## Everything one event writes.
## - `head`: how the cell of `rows` is replaced before `ops`: by a new table
##   (`Fresh(seed, count)`), by its group's reset, by the copy `saved`
##   holds (`Restore`) or by `spare`'s table (`Borrow`). The last two need
##   a reading, so only the control that takes one applies them.
## - `ops`: writes of `rows`, in order, as one `update` for each (`split`)
##   or one `update` that folds them.
## - `spare`: a write of the other table.
## - `save`: put the table as it was read into `saved` (the reading control).
## - `tick`: add one to `serial`, which is in `rows`' group.
## - `flip`: mount or unmount `c`.
## - `listing`, `window`, `lanes`: set those cells.
## - `local_listing`, `local_window`: what `b`'s control writes to its state.
Decision : {
	head : [Keep, Fresh(U64, U64), Reset, Restore, Borrow],
	ops : List(Op),
	split : Bool,
	spare : [Untouched, Wrote(Op)],
	save : Bool,
	tick : Bool,
	flip : Bool,
	listing : [Same, To(Listing)],
	window : [Same, To(Engine.Window)],
	lanes : [Same, To(List(U64))],
	local_listing : [Same, To(Listing)],
	local_window : [Same, To(Engine.Window)],
}

## The decision that writes nothing.
quiet : Decision
quiet = {
	head: Keep,
	ops: [],
	split: False,
	spare: Untouched,
	save: False,
	tick: False,
	flip: False,
	listing: Same,
	window: Same,
	lanes: Same,
	local_listing: Same,
	local_window: Same,
}

## The words of a decision before its writes of `rows`, four words each.
header_len : U64
header_len = 17

## The most writes of `rows` one decision holds.
max_ops : U64
max_ops = 8

## The decision a payload's words name. Every list of words names one; a
## missing word reads as 0, which changes nothing.
decision_of : List(U64) -> Decision
decision_of = |words| {
	w = |at| words.get(at) ?? 0
	head = match w(0) % 16 {
		12 => Fresh(w(1), w(2) % (key_space + 1))
		13 => Reset
		14 => Restore
		15 => Borrow
		_ => Keep
	}
	# An undo after a restore is not generated: what it undoes depends on
	# whether the copy is still the cell's own table, which the model does
	# not follow.
	undoes = match head {
		Restore => False
		_ => True
	}
	count = if (words.len() > header_len) ((words.len() - header_len) // 4).min(max_ops) else 0
	ops = span(count).map(
		|i| {
			at = header_len + i * 4
			op_of(w(at), w(at + 1), w(at + 2), w(at + 3), undoes)
		},
	)
	{
		head,
		ops,
		split: w(3) % 2 == 1,
		tick: (w(3) // 2) % 2 == 1,
		save: (w(3) // 4) % 4 == 3,
		flip: (w(3) // 16) % 4 == 3,
		listing: if (w(4) % 4 == 3) To(listing_of(w(5))) else Same,
		window: if ((w(4) // 4) % 4 == 3) To({ start: w(6) % 20, count: w(7) % 7 }) else Same,
		lanes: if ((w(4) // 16) % 4 == 3) To(lane_lists.get(w(8) % 16) ?? []) else Same,
		local_listing: if (w(9) % 2 == 1) To(listing_of(w(10))) else Same,
		local_window: if ((w(9) // 2) % 2 == 1) To({ start: w(11) % 20, count: w(12) % 7 }) else Same,
		spare: if (w(13) % 4 == 3) Wrote(op_of((w(13) // 4) * 2, w(14), w(15), w(16), True)) else Untouched,
	}
}

## The write four words name. Keyed writes are the most likely; one in
## thirty-two is each of the whole rewrites and the undo.
op_of : U64, U64, U64, U64, Bool -> Op
op_of = |kind, a, b, c, undoes| {
	key = a % key_space
	k = kind % 32
	if k < 6 {
		Put(key, item_of(b))
	} else if k < 11 {
		Insert(key, item_of(b))
	} else if k < 18 {
		Update(key, c % 4)
	} else if k < 20 {
		Replace(key, item_of(b))
	} else if k < 26 {
		Remove(key)
	} else if k < 28 {
		Fill(key, b % (key_space + 1), c)
	} else if k == 28 {
		Sweep(key, b % (key_space + 1), c % 4)
	} else if k == 29 {
		Load(a, b % (key_space + 1))
	} else if k == 30 {
		All(c % 4)
	} else if undoes {
		Undo
	} else {
		Update(key, c % 4)
	}
}

## The words that name a decision: `decision_of` of them is the decision.
words_of : Decision -> List(U64)
words_of = |d| {
	head = match d.head {
		Keep => [0, 0, 0]
		Fresh(seed, count) => [12, seed, count]
		Reset => [13, 0, 0]
		Restore => [14, 0, 0]
		Borrow => [15, 0, 0]
	}
	flags = (if (d.split) 1 else 0) + (if (d.tick) 2 else 0) + (if (d.save) 12 else 0) + (if (d.flip) 48 else 0)
	(listing, listing_word_of) = match d.listing {
		To(l) => (3, listing_word(l))
		Same => (0, 0)
	}
	(window, start, count) = match d.window {
		To(win) => (12, win.start, win.count)
		Same => (0, 0, 0)
	}
	(lanes, lanes_word) = match d.lanes {
		To(list) => (48, lane_lists.find_first_index(|l| l == list) ?? crash "table-view: a list of lanes no number names")
		Same => (0, 0)
	}
	(local_listing, local_listing_word) = match d.local_listing {
		To(l) => (1, listing_word(l))
		Same => (0, 0)
	}
	(local_window, local_start, local_count) = match d.local_window {
		To(win) => (2, win.start, win.count)
		Same => (0, 0, 0)
	}
	spare = match d.spare {
		Wrote(op) => {
			four = op_words(op)
			kind = four.first() ?? 0
			if kind % 2 == 1 {
				crash "table-view: a write of the spare table no number names"
			} else {
				[(kind // 2) * 4 + 3].concat(four.drop_first(1))
			}
		}
		Untouched => [0, 0, 0, 0]
	}
	head
		.concat([flags, listing + window + lanes, listing_word_of, start, count, lanes_word])
		.concat([local_listing + local_window, local_listing_word, local_start, local_count])
		.concat(spare)
		.concat(d.ops.fold([], |acc, op| acc.concat(op_words(op))))
}

## The four words that name a write.
op_words : Op -> List(U64)
op_words = |op| match op {
	Put(key, item) => [0, key, item_word(item), 0]
	Insert(key, item) => [6, key, item_word(item), 0]
	Update(key, code) => [12, key, 0, code]
	Replace(key, item) => [18, key, item_word(item), 0]
	Remove(key) => [20, key, 0, 0]
	Fill(from, count, seed) => [26, from, count, seed]
	Sweep(from, count, code) => [28, from, count, code]
	Load(seed, count) => [29, seed, count, 0]
	All(code) => [30, 0, 0, code]
	Undo => [31, 0, 0, 0]
}

## A decision as an event's payload, one character for each word, and back.
payload_of : Decision -> Str
payload_of = |d| Str.from_utf8(words_of(d).map(|n| (48 + n % 64).to_u8_wrap())) ?? crash "table-view: a payload that is not text"

decided_by : Str -> Decision
decided_by = |payload| decision_of(payload.to_utf8().map(|b| (b.to_u64() + 16) % 64))

# ------------------------------------------------------------------ the app

## The store's name.
Tag := [TableView]

## The app's store. `rows` is the table most views draw, in a group with
## `serial`, a count, so that the group's reset starts both again. `spare`
## is the other table. `saved` holds a copy of `rows`' table as a plain
## value. `listing` and `window` are what `a` shows, `shown` is whether `c`
## is mounted, and `lanes` lists the shades that have a lane.
store = Engine.store(
	Tag.TableView,
	{
		items: {
			rows: Engine.table(described),
			serial: Engine.cell(0.U64),
		}.Engine.Cells.with_reset(|made, reset| { rows: made.rows, serial: made.serial, reset }),
		spare: Engine.table(first_spare),
		saved: Engine.cell(Table.from_list([])),
		listing: Engine.cell(first_listing),
		window: Engine.cell(first_window),
		shown: Engine.cell(False),
		lanes: Engine.cell(first_lanes),
	}.Engine.Cells,
)

## The store's cells.
cells = store.cells()

## The store as a session starts it.
started : {} -> Engine.Store(_, _)
started = |{}| store.with_initial(cells.items.rows, Table.from_list(first_rows))

## What a decision's control read before the event wrote anything: the
## table of `rows`, the copy in `saved` and the table of `spare`.
Reading : [Unread, Read({ now : Table(U64, Item), kept : Table(U64, Item), lent : Table(U64, Item) })]

## One write of a table.
applied : Table(U64, Item), Op -> Table(U64, Item)
applied = |table, op| match op {
	Insert(key, item) =>
		match table.get(key) {
			Ok(_) => table
			Err(Missing) => table.insert(key, item)
		}
	Put(key, item) => table.put(key, item)
	Replace(key, item) => table.replace(key, item)
	Update(key, code) => table.update(key, |item| bumped(item, code))
	Remove(key) => table.remove(key)
	# Many edits in one event are a fold over the keys, not a loop over a
	# `var` holding the table (roc-lang/roc#12971).
	Fill(from, count, seed) => span(count).fold(table, |acc, i| acc.put((from + i) % key_space, item_of(seed + i)))
	Sweep(from, count, code) => span(count).fold(table, |acc, i| acc.update((from + i) % key_space, |item| bumped(item, code)))
	Load(seed, count) => table.load(entries(seed, count))
	All(code) => table.update_all(|_, item| bumped(item, code))
	Undo =>
		match table.inverse() {
			Ok(writes) => table.apply(writes)
			Err(Rewritten) => table
		}
}

## A decision's writes: the transition of one event.
writes_of : Decision, Reading -> List(Engine.Write(_))
writes_of = |d, reading| {
	rows = cells.items.rows
	head = match (d.head, reading) {
		(Fresh(seed, count), _) => [rows.set(Table.from_list(entries(seed, count)))]
		(Reset, _) => [cells.items.reset]
		(Restore, Read({ kept, .. })) => [rows.set(kept)]
		(Borrow, Read({ lent, .. })) => [rows.set(lent)]
		_ => []
	}
	ops = d.ops
	keyed =
		if d.split {
			ops.map(|op| rows.update(|table| applied(table, op)))
		} else if ops.is_empty() {
			[]
		} else {
			[rows.update(|table| ops.fold(table, applied))]
		}
	spare = match d.spare {
		Wrote(op) => [cells.spare.update(|table| applied(table, op))]
		Untouched => []
	}
	save = match reading {
		Read({ now, .. }) => if (d.save) [cells.saved.set(now)] else []
		Unread => []
	}
	tick = if (d.tick) [cells.items.serial.update(|n| n + 1)] else []
	flip = if (d.flip) [cells.shown.update(|on| !on)] else []
	listing = match d.listing {
		To(l) => [cells.listing.set(l)]
		Same => []
	}
	window = match d.window {
		To(win) => [cells.window.set(win)]
		Same => []
	}
	lanes = match d.lanes {
		To(list) => [cells.lanes.set(list)]
		Same => []
	}
	head.concat(keyed).concat(spare).concat(save).concat(tick).concat(flip).concat(listing).concat(window).concat(lanes)
}

## What `b`'s state holds after a decision.
local_after : Local, Decision -> Local
local_after = |held, d| {
	listing: match d.local_listing {
		To(l) => l
		Same => held.listing
	},
	window: match d.local_window {
		To(win) => win
		Same => held.window
	},
}

## A button named `name` with no text of its own, so a row's text is its
## key, its row and its marks alone.
press : Str, Engine.Handler(ctx) -> Elem(ctx)
press = |name, handler| Engine.element("button", [Engine.attr("data-do", name), Engine.on_click(handler)], [])

## One row of a view of `table`: `key:rank:shade`, then `:marks` from a
## state of the row's own. `bump` and `tint` write the row through its
## `State`, `drop` removes it through the table's cell, `mark` writes the
## row's state and `both` writes that state and the row as one event.
row_view : Engine.Cell(st, Table(U64, Item)), Signal(Engine.Row(ctx, U64), U64), State(Engine.Row(ctx, U64), Item) -> Elem(Engine.Row(ctx, U64))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
row_view = |table, key, row| Engine.element(
	"li",
	[],
	[
		Engine.text_s(key.map2(row.signal(), |k, item| "${k.to_str()}:${item.rank.to_str()}:${item.shade.to_str()}")),
		press("bump", row.update(|item| bumped(item, 1))),
		press("tint", row.update(|item| bumped(item, 2))),
		press("drop", Engine.handle_by(key, |k, _| [table.update(|held| held.remove(k))])),
		Engine.state(
			0.U64,
			|marks| Engine.element(
				"span",
				[],
				[
					Engine.text_s(marks.signal().map(|n| ":${n.to_str()}")),
					press("mark", marks.update(|n| n + 1)),
					press("both", marks.update(|n| n + 1).also(row.lift().update(|item| bumped(item, 0)))),
				],
			),
		),
	],
)

## A view of `table`: the window `window` of `listing`, in a list that
## carries `name`.
list_of : Engine.Attr(ctx), Engine.Cell(st, Table(U64, Item)), Signal(ctx, Listing), Signal(ctx, Engine.Window) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, st)]
list_of = |name, table, listing, window| Engine.element(
	"ul",
	[name],
	# The template is given as a lambda, not returned from a helper
	# (roc-lang/roc#12970).
	[Engine.table_view(table, { query: listing, plan: query_plan, window }, |key, row| row_view(table, key, row))],
)

## The page: the three controls a decision fires from (`plain`, `copy`,
## and `local` inside `b`'s state), the readers of the row count and of
## the serial, and the eight views.
page : {} -> Elem(Engine.StoreRoot(_))
page = |{}| {
	rows = cells.items.rows
	reading = rows.signal().map2(cells.saved.signal(), |now, kept| { now, kept }).map2(cells.spare.signal(), |read, lent| { now: read.now, kept: read.kept, lent })
	Engine.element(
		"main",
		[],
		[
			Engine.element("input", [Engine.test_id("plain"), Engine.on("input", Engine.handle(|payload| writes_of(decided_by(payload), Unread)))], []),
			Engine.element("input", [Engine.test_id("copy"), Engine.on("input", Engine.handle_by(reading, |read, payload| writes_of(decided_by(payload), Read(read))))], []),
			Engine.element("p", [Engine.test_id("count")], [Engine.text_s(rows.signal().map(|table| table.len().to_str()))]),
			Engine.element("p", [Engine.test_id("serial")], [Engine.text_s(cells.items.serial.signal().map(|n| n.to_str()))]),
			list_of(Engine.test_id("a"), rows, cells.listing.signal(), cells.window.signal()),
			Engine.state(
				first_local,
				|local| Engine.element(
					"section",
					[],
					[
						Engine.element(
							"input",
							[
								Engine.test_id("local"),
								Engine.on(
									"input",
									local.set_value(|held, payload| local_after(held, decided_by(payload))).also(Engine.handle(|payload| writes_of(decided_by(payload), Unread))),
								),
							],
							[],
						),
						list_of(Engine.test_id("b"), rows, local.signal().map(|held| held.listing), local.signal().map(|held| held.window)),
						Engine.derive(
							local.signal().map(|held| { listing: turned(held.listing), window: held.window }),
							|shown| list_of(Engine.test_id("e"), rows, shown.map(|held| held.listing), shown.map(|held| held.window)),
						),
					],
				),
			),
			Engine.when(
				cells.shown.signal(),
				|| list_of(Engine.test_id("c"), rows, cells.listing.signal().map(turned), Engine.const(c_window)),
				|| Engine.text(""),
			),
			list_of(Engine.test_id("d"), cells.spare, Engine.const(d_listing), Engine.const(d_window)),
			Engine.element(
				"ol",
				[Engine.test_id("lanes")],
				[
					Engine.each(
						cells.lanes.signal(),
						|shade| shade.to_str(),
						|lane| Engine.element(
							"li",
							[],
							[list_of(Engine.test_id_s(lane.key().map(|shade| "lane ${shade}")), rows, lane.field(lane_listing), Engine.const(lane_window))],
						),
					),
				],
			),
		],
	)
}

# ---------------------------------------------------------------- the model

## A view of the app.
ViewId : [A, B, C, D, E, Lane(U64)]

all_views : List(ViewId)
all_views = [A, B, C, D, Lane(0), Lane(1), Lane(2), E]

## The test id of a view's list.
name_of : ViewId -> Str
name_of = |view| match view {
	A => "a"
	B => "b"
	C => "c"
	D => "d"
	E => "e"
	Lane(shade) => "lane ${shade.to_str()}"
}

## The marks of one drawn row of one view. A row without an entry has none.
Mark : { view : ViewId, key : U64, count : U64 }

## What the app holds, as plain lists: the tables' rows in no order, the
## cells, `b`'s state, and the marks of the rows drawn.
Model : {
	rows : List(Entry),
	spare : List(Entry),
	saved : List(Entry),
	serial : U64,
	listing : Listing,
	window : Engine.Window,
	local : Local,
	shown : Bool,
	lanes : List(U64),
	marks : List(Mark),
}

## The model of the app as it mounts.
model_start : Model
model_start = {
	rows: first_rows,
	spare: first_spare,
	saved: [],
	serial: 0,
	listing: first_listing,
	window: first_window,
	local: first_local,
	shown: False,
	lanes: first_lanes,
	marks: [],
}

## The order of two numbers.
compare_u64 : U64, U64 -> [Before, Same, After]
compare_u64 = |x, y| if (x < y) Before else if (x > y) After else Same

## The keys a view of `rows` draws: the rows the listing keeps, sorted from
## scratch in the listing's order, and of those the window.
drawn : List(Entry), Listing, Engine.Window -> List(U64)
drawn = |rows, { show, order }, window| {
	kept = rows.keep_if(
		|e| match show {
			All => True
			Only(shade) => e.row.shade == shade
			Except(shade) => e.row.shade != shade
		},
	)
	sorted = kept.sort_with(
		|x, y| match order {
			ByKey => compare_u64(x.key, y.key)
			ByKeyDown => compare_u64(y.key, x.key)
			ByRank => if (x.row.rank == y.row.rank) compare_u64(x.key, y.key) else compare_u64(x.row.rank, y.row.rank)
			ByRankDown => if (x.row.rank == y.row.rank) compare_u64(x.key, y.key) else compare_u64(y.row.rank, x.row.rank)
		},
	)
	sorted.sublist({ start: window.start, len: window.count.min(sorted.len()) }).map(|e| e.key)
}

## The keys view `view` draws, mounted or not.
window_keys : Model, ViewId -> List(U64)
window_keys = |m, view| match view {
	A => drawn(m.rows, m.listing, m.window)
	B => drawn(m.rows, m.local.listing, m.local.window)
	C => drawn(m.rows, turned(m.listing), c_window)
	D => drawn(m.spare, d_listing, d_window)
	E => drawn(m.rows, turned(m.local.listing), m.local.window)
	Lane(shade) => drawn(m.rows, lane_listing(shade), lane_window)
}

## Whether the app draws view `view` at all.
is_mounted : Model, ViewId -> Bool
is_mounted = |m, view| match view {
	C => m.shown
	Lane(shade) => m.lanes.contains(shade)
	_ => True
}

## The marks of the row of `key` in `view`.
marks_of : Model, ViewId, U64 -> U64
marks_of = |m, view, key| match m.marks.find_first(|mark| mark.view == view and mark.key == key) {
	Ok(mark) => mark.count
	Err(_) => 0
}

## The model with one more mark on the row of `key` in `view`.
marked : Model, ViewId, U64 -> Model
marked = |m, view, key| {
	count = marks_of(m, view, key) + 1
	{ ..m, marks: m.marks.drop_if(|mark| mark.view == view and mark.key == key).append({ view, key, count }) }
}

## The text of the row of `key` in `view`.
row_text : Model, ViewId, U64 -> Str
row_text = |m, view, key| {
	held = match view {
		D => m.spare
		_ => m.rows
	}
	item = match held.find_first(|e| e.key == key) {
		Ok(e) => e.row
		Err(_) => crash "table-view: the model draws a key its table does not hold"
	}
	"${key.to_str()}:${item.rank.to_str()}:${item.shade.to_str()}:${marks_of(m, view, key).to_str()}"
}

## A table through one turn: its rows, its rows when the turn began, and
## whether the turn replaced every row, after which an undo has nothing to
## go by.
Written : { rows : List(Entry), began : List(Entry), rewritten : Bool }

## `rows` with `row` under `key`, new or in place of the one there.
with_row : List(Entry), U64, Item -> List(Entry)
with_row = |rows, key, row|
	if rows.any(|e| e.key == key) {
		rows.map(|e| if (e.key == key) { key, row } else e)
	} else {
		rows.append({ key, row })
	}

## One write of a table, on the model's rows.
model_op : Written, Op -> Written
model_op = |t, op| match op {
	Insert(key, item) => if (t.rows.any(|e| e.key == key)) t else { ..t, rows: t.rows.append({ key, row: item }) }
	Put(key, item) => { ..t, rows: with_row(t.rows, key, item) }
	Replace(key, item) => if (t.rows.any(|e| e.key == key)) { ..t, rows: with_row(t.rows, key, item) } else t
	Update(key, code) => { ..t, rows: t.rows.map(|e| if (e.key == key) { key, row: bumped(e.row, code) } else e) }
	Remove(key) => { ..t, rows: t.rows.drop_if(|e| e.key == key) }
	Fill(from, count, seed) => span(count).fold(t, |acc, i| { ..acc, rows: with_row(acc.rows, (from + i) % key_space, item_of(seed + i)) })
	Sweep(from, count, code) => span(count).fold(t, |acc, i| { ..acc, rows: acc.rows.map(|e| if (e.key == (from + i) % key_space) { key: e.key, row: bumped(e.row, code) } else e) })
	Load(seed, count) => { ..t, rows: entries(seed, count), rewritten: True }
	All(code) => { ..t, rows: t.rows.map(|e| { key: e.key, row: bumped(e.row, code) }), rewritten: True }
	Undo => if (t.rewritten) t else { ..t, rows: t.began }
}

## The model after a decision fired from `control`.
decided : Model, [Plain, Copy, Local], Decision -> Model
decided = |m, control, d| {
	has_reading = match control {
		Copy => True
		_ => False
	}
	replaced = match d.head {
		Fresh(seed, count) => Ok(entries(seed, count))
		Reset => Ok(described)
		Restore => if (has_reading) Ok(m.saved) else Err(Kept)
		Borrow => if (has_reading) Ok(m.spare) else Err(Kept)
		Keep => Err(Kept)
	}
	began = match replaced {
		Ok(rows) => { rows, began: m.rows, rewritten: True }
		Err(Kept) => { rows: m.rows, began: m.rows, rewritten: False }
	}
	spare = match d.spare {
		Wrote(op) => model_op({ rows: m.spare, began: m.spare, rewritten: False }, op).rows
		Untouched => m.spare
	}
	serial = match d.head {
		Reset => 0
		_ => m.serial
	}
	{
		..m,
		rows: d.ops.fold(began, model_op).rows,
		spare,
		saved: if (d.save and has_reading) m.rows else m.saved,
		serial: if (d.tick) serial + 1 else serial,
		listing: match d.listing {
			To(l) => l
			Same => m.listing
		},
		window: match d.window {
			To(win) => win
			Same => m.window
		},
		local: match control {
			Local => local_after(m.local, d)
			_ => m.local
		},
		shown: if (d.flip) !m.shown else m.shown,
		lanes: match d.lanes {
			To(list) => list
			Same => m.lanes
		},
	}
}

## The length of a longest strictly increasing run of `values`, not
## necessarily adjacent.
longest_run : List(U64) -> U64
longest_run = |values| {
	var $runs = []
	var $i = 0.U64
	while $i < values.len() {
		value = values.get($i) ?? 0
		var $run = 1.U64
		var $j = 0.U64
		while $j < $i {
			if (values.get($j) ?? 0) < value and ($runs.get($j) ?? 0) + 1 > $run {
				$run = ($runs.get($j) ?? 0) + 1
			}
			$j = $j + 1
		}
		$runs = $runs.append($run)
		$i = $i + 1
	}
	$runs.fold(0, |best, run| if (run > best) run else best)
}

## What a turn asks of the rows drawn: how many are created and how many
## moved.
Work : { created : U64, moved : U64 }

## Taking a window from `old` to `new`: the rows that enter are created, and
## of the rows in both, those off a longest run that kept its order move.
window_work : List(U64), List(U64) -> Work
window_work = |old, new| {
	stayed = old.keep_if(|key| new.contains(key))
	places = stayed.map(|key| new.find_first_index(|k| k == key) ?? 0)
	{ created: new.count_if(|key| !old.contains(key)), moved: stayed.len() - longest_run(places) }
}

## What one event does to the model: the model as the event fires (a click
## on `mark` or `both` has counted by then) and the model its writes leave.
Course : { fired : Model, after : Model }

## The model once a turn is over, and the work the turn asks of the rows
## drawn. A row is one row for as long as its view's window holds it, so
## what counts is the window before the event and the window after it
## (design.md, "Observable lifetime rules"), whatever the event wrote on
## the way: a row in both keeps its marks, a row only in the second is
## created, and of the rows in both, those off a longest run that kept its
## order move. A view the turn mounted creates the rows it draws, and a
## lane its own row as well.
outcome : Course -> { model : Model, work : Work }
outcome = |{ fired, after }| {
	walked = all_views.fold(
		{ marks: [], created: 0, moved: 0 },
		|acc, view| {
			if is_mounted(after, view) and is_mounted(fired, view) {
				before = window_keys(fired, view)
				now = window_keys(after, view)
				work = window_work(before, now)
				kept = fired.marks.keep_if(|mark| mark.view == view and before.contains(mark.key) and now.contains(mark.key))
				{ marks: acc.marks.concat(kept), created: acc.created + work.created, moved: acc.moved + work.moved }
			} else if is_mounted(after, view) {
				own = match view {
					Lane(_) => 1
					_ => 0
				}
				{ ..acc, created: acc.created + window_keys(after, view).len() + own }
			} else {
				acc
			}
		},
	)
	{ model: { ..after, marks: walked.marks }, work: { created: walked.created, moved: walked.moved } }
}

# ------------------------------------------------------------------ session

## One step of a session: a decision fired from one of the three controls,
## or a click on a button of the row at a position of a view's window.
Step : [Decide([Plain, Copy, Local], Decision), Click(ViewId, U64, [Mark, Bump, Tint, Drop, Both])]

## The most steps one session takes.
max_steps : U64
max_steps = 96

## Decode bytes into a session. Any bytes are one: a click is four bytes,
## a decision two and then a byte for each of its words, and bytes missing
## at the end read as 0.
steps_of : List(U8) -> List(Step)
steps_of = |bytes| {
	byte = |at| (bytes.get(at) ?? 0).to_u64()
	var $steps = []
	var $at = 0.U64
	while $at < bytes.len() and $steps.len() < max_steps {
		kind = byte($at) % 8
		if kind >= 5 {
			view = all_views.get(byte($at + 1) % all_views.len()) ?? A
			button = match byte($at + 3) % 8 {
				0 | 1 => Mark
				2 | 3 => Bump
				4 => Tint
				5 => Drop
				_ => Both
			}
			$steps = $steps.append(Click(view, byte($at + 2), button))
			$at = $at + 4
		} else {
			control = if (kind == 3) Copy else if (kind == 4) Local else Plain
			len = header_len + (byte($at + 1) % (max_ops + 1)) * 4
			words = bytes.sublist({ start: $at + 2, len }).map(|b| b.to_u64() % 64)
			$steps = $steps.append(Decide(control, decision_of(words)))
			$at = $at + 2 + len
		}
	}
	$steps
}

## The bytes of a session written as steps: `steps_of` of them is the
## session.
bytes_of : List(Step) -> List(U8)
bytes_of = |steps| steps.fold(
	[],
	|acc, step| {
		numbers = match step {
			Decide(control, d) => {
				kind = match control {
					Plain => 0
					Copy => 3
					Local => 4
				}
				[kind, d.ops.len()].concat(words_of(d))
			}
			Click(view, at, button) => {
				pressed = match button {
					Mark => 0
					Bump => 2
					Tint => 4
					Drop => 5
					Both => 6
				}
				[5, all_views.find_first_index(|v| v == view) ?? 0, at, pressed]
			}
		}
		acc.concat(numbers.map(|n| n.to_u8_wrap()))
	},
)

## The engine, the oracle's DOM and the model.
S : { eng : Core.App, dom : Dom.Model, model : Model }

## Mount the app through its program's driver, as a host does.
mount : {} -> S
mount = |{}| {
	program = Engine.program_store({ storage_keys: [], max_inflight: 8 }, |_| started({}), |_| page({}))
	(eng, cmds, _) = (Core.driver(program).init)([])
	{ eng, dom: Dom.apply(Dom.new({}), cmds), model: model_start }
}

## The node with test id `name`.
named : Dom.Model, Str -> Try(U64, [NotFound])
named = |dom, name| Dom.by_attr(dom, "data-testid", name)

## The rows of the list at node `list`, in order.
rows_in : Dom.Model, U64 -> List(U64)
rows_in = |dom, list| Dom.node(dom, list).kids.keep_if(|kid| Dom.node(dom, kid).tag == "li")

## Deliver `event` with `payload` to the node at index `at`, as one turn,
## and apply its commands to the oracle. Answers the batch's opcodes too.
fire : S, U64, Str, Str -> (S, List(U8))
fire = |s, at, event, payload| match Dom.target(s.dom, at, event, Bool.True) {
	Ok(target) => {
		(eng, cmds) = Core.take_cmds(Core.event(s.eng, target.node, target.handler, payload), [])
		(dom, ops) = Dom.apply_ops(s.dom, cmds)
		if (Core.work_counters(eng).get(45) ?? 0) != dom.transitions.count {
			crash "table-view: engine transition count differs from the independent oracle"
		}
		({ eng, dom, model: s.model }, ops)
	}
	Err(NoHandler) => crash "table-view: node ${at.to_str()} has no ${event} handler"
}

## What a step does to the model, or `Idle` for a click where no row is
## drawn: on a view that is not mounted or whose window is empty.
course : Model, Step -> [Idle, Turn(Course)]
course = |m, step| match step {
	Decide(control, d) => Turn({ fired: m, after: decided(m, control, d) })
	Click(view, position, button) => {
		keys = if (is_mounted(m, view)) window_keys(m, view) else []
		match keys.get(position % keys.len().max(1)) {
			Err(_) => Idle
			Ok(key) => {
				write = |held, op| match view {
					D => { ..held, spare: model_op({ rows: held.spare, began: held.spare, rewritten: False }, op).rows }
					_ => { ..held, rows: model_op({ rows: held.rows, began: held.rows, rewritten: False }, op).rows }
				}
				match button {
					Mark => {
						counted = marked(m, view, key)
						Turn({ fired: counted, after: counted })
					}
					Bump => Turn({ fired: m, after: write(m, Update(key, 1)) })
					Tint => Turn({ fired: m, after: write(m, Update(key, 2)) })
					Drop => Turn({ fired: m, after: write(m, Remove(key)) })
					Both => {
						counted = marked(m, view, key)
						Turn({ fired: counted, after: write(counted, Update(key, 0)) })
					}
				}
			}
		}
	}
}

## The node a step's event goes to, with the event's name and payload.
aim : Dom.Model, Model, Step -> { at : U64, event : Str, payload : Str }
aim = |dom, m, step| match step {
	Decide(control, d) => {
		control_name = match control {
			Plain => "plain"
			Copy => "copy"
			Local => "local"
		}
		{ at: named(dom, control_name) ?? crash "table-view: the control ${control_name} is not drawn", event: "input", payload: payload_of(d) }
	}
	Click(view, position, button) => {
		list = named(dom, name_of(view)) ?? crash "table-view: the view ${name_of(view)} is not drawn"
		row = rows_in(dom, list).get(position % window_keys(m, view).len().max(1)) ?? crash "table-view: the view ${name_of(view)} draws fewer rows than the model"
		pressed = match button {
			Mark => "mark"
			Bump => "bump"
			Tint => "tint"
			Drop => "drop"
			Both => "both"
		}
		{ at: Dom.find(dom, row, |n| Dom.attr_of(n, "data-do") == pressed) ?? crash "table-view: a row has no ${pressed} button", event: "click", payload: "" }
	}
}

## Take one step in the engine and in the model. Answers the batch's
## opcodes and the work the model expects of the rows drawn; `moved` is
## `Unchecked` when the lanes changed, whose rows an `each` site moves by
## its own plan. A step that fires nothing leaves both as they were.
advance : S, Step -> { s : S, ops : List(U8), created : U64, moved : [Exactly(U64), Unchecked] }
advance = |s, step| {
	match course(s.model, step) {
		Idle => { s, ops: [], created: 0, moved: Exactly(0) }
		Turn(taken) => {
			{ at, event, payload } = aim(s.dom, s.model, step)
			(fired, ops) = fire(s, at, event, payload)
			{ model, work } = outcome(taken)
			{ s: { ..fired, model }, ops, created: work.created, moved: if (model.lanes == s.model.lanes) Exactly(work.moved) else Unchecked }
		}
	}
}

## What is wrong after a step, if anything: a stale reader or a view that
## is not its table's, a view that draws other rows than the model's, a
## reader that shows another value, or rows created or moved that the
## windows' changes do not account for.
problem : S, List(U8), U64, [Exactly(U64), Unchecked] -> Try({}, Str)
problem = |s, ops, created, moved| {
	match Core.settled(s.eng) {
		Ok(_) => {}
		Err({ cmds, note }) => Err("the engine is not settled: a pass over every layer emitted ${Dom.describe(Dom.apply_ops(s.dom, cmds).1)} ${note}")?
	}
	for view in all_views {
		name = name_of(view)
		match (named(s.dom, name), is_mounted(s.model, view)) {
			(Ok(list), True) => {
				got = rows_in(s.dom, list).map(|row| Dom.text_of(s.dom, row))
				want = window_keys(s.model, view).map(|key| row_text(s.model, view, key))
				if got != want {
					Err("view ${name} draws ${Str.inspect(got)}, the model ${Str.inspect(want)}")?
				}
			}
			(Err(NotFound), False) => {}
			(Ok(_), False) => Err("view ${name} is drawn, and the model has it unmounted")?
			(Err(NotFound), True) => Err("view ${name} is not drawn, and the model has it mounted")?
		}
	}
	lanes = match named(s.dom, "lanes") {
		Ok(list) => rows_in(s.dom, list).map(|row| Dom.attr_of(Dom.node(s.dom, Dom.node(s.dom, row).kids.first() ?? 0), "data-testid"))
		Err(NotFound) => []
	}
	if lanes != s.model.lanes.map(|shade| name_of(Lane(shade))) {
		Err("the lanes are ${Str.inspect(lanes)}, the model's ${Str.inspect(s.model.lanes)}")?
	}
	shows = |name| match named(s.dom, name) {
		Ok(node) => Dom.text_of(s.dom, node)
		Err(NotFound) => "nothing"
	}
	if shows("count") != s.model.rows.len().to_str() {
		Err("the row count reads ${shows("count")}, the model has ${s.model.rows.len().to_str()} rows")?
	}
	if shows("serial") != s.model.serial.to_str() {
		Err("the serial reads ${shows("serial")}, the model's is ${s.model.serial.to_str()}")?
	}
	insts = ops.count_if(|op| op == 1)
	if insts != created {
		Err("${insts.to_str()} rows were created, and ${created.to_str()} entered a window")?
	}
	moves = ops.count_if(|op| op == 4)
	match moved {
		Exactly(count) =>
			if moves != count {
				Err("${moves.to_str()} rows were moved, and ${count.to_str()} left their place in a window")?
			}
		Unchecked => {}
	}
	Ok({})
}

## Run a session, checking after the mount and after every step.
run : List(Step) -> {}
run = |steps| {
	var $s = mount({})
	match problem($s, [], 0, Unchecked) {
		Ok(_) => {}
		Err(why) => crash "mount: ${why}"
	}
	var $n = 0.U64
	for step in steps {
		next = advance($s, step)
		match problem(next.s, next.ops, next.created, next.moved) {
			Ok(_) => {}
			Err(why) => crash "step ${$n.to_str()} (${Str.inspect(step)}): ${why}"
		}
		$s = next.s
		$n = $n + 1
	}
	{}
}

## `len` bytes from `seed`, by a linear congruential generator.
seeded : U64, U64 -> List(U8)
seeded = |seed, len| {
	var $x = seed
	var $out = List.with_capacity(len)
	while $out.len() < len {
		$x = $x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
		$out = $out.append($x.shr_zf_wrap(40).to_u8_wrap())
	}
	$out
}

## Mode 1: a seeded series of generated sessions.
series : U64, U64 -> {}
series = |seed, count| {
	var $k = 0.U64
	while $k < count {
		run(steps_of(seeded(seed + $k * 7919, 600)))
		$k = $k + 1
	}
	{}
}

## `events` are a session's bytes. Mode 0 runs the session, as every
## generated input does; mode 1 runs a seeded series of sessions instead.
Input : { mode : U8, events : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, events }| {
	if mode == 1 {
		Fuzz.expect_no_leaks!(|| series(17 + events.len().to_u64(), 160))
	} else {
		Fuzz.expect_no_leaks!(|| run(steps_of(events)))
	}
	Fuzz.keep
}

# ----------------------------------------------------------------- examples

## A decision fired from the control that only decides, from the one whose
## decision reads the tables, and from `b`'s, which writes its state too.
plain : Decision -> Step
plain = |d| Decide(Plain, d)

reads : Decision -> Step
reads = |d| Decide(Copy, d)

both : Decision -> Step
both = |d| Decide(Local, d)

## One write of `rows` as one event.
wrote : Op -> Step
wrote = |op| Decide(Plain, { ..quiet, ops: [op] })

## A row of a rank and a shade.
ranked : U64, U64 -> Item
ranked = |rank, shade| { rank, shade }

## Every kind of keyed write, one to an event. `rows` starts as keys 0, 3,
## 4, 5, 8, 9, 10, 13, 14 and 15, and `a` draws 0, 8, 15 and 14, the four
## lowest ranks.
keyed_steps : List(Step)
keyed_steps = [
	# A row enters `a`'s window and pushes its last row out; then its rank
	# rises and it leaves again.
	wrote(Insert(1, ranked(0, 1))),
	wrote(Update(1, 1)),
	# A row moves inside the window, and one moves out of it past its end.
	wrote(Replace(14, ranked(0, 2))),
	wrote(Put(8, ranked(7, 0))),
	# The first row of every order by rank goes: each window shifts up.
	wrote(Remove(0)),
	# A row changes its shade and enters the lane that filters on it.
	wrote(Update(15, 2)),
	# Writes that change nothing: an equal row, an insert of a key that is
	# held, and a replace, an update and a remove of one that is not.
	wrote(Update(9, 3)),
	wrote(Insert(5, ranked(1, 1))),
	wrote(Replace(7, ranked(1, 1))),
	wrote(Update(7, 0)),
	wrote(Remove(7)),
	# A put of a new key, and of a held one with its own row.
	wrote(Put(7, ranked(1, 2))),
	wrote(Put(7, ranked(1, 2))),
]

## Several writes in one event, as one `update` and as one for each.
batch_steps : List(Step)
batch_steps = [
	# A row inserted and removed in one event was never there.
	plain({ ..quiet, ops: [Insert(1, ranked(0, 1)), Remove(1)] }),
	# A row removed and inserted again is one changed row.
	plain({ ..quiet, ops: [Remove(0), Insert(0, ranked(2, 0))], split: True }),
	# One key written three times, between writes of others.
	plain({ ..quiet, ops: [Update(5, 1), Put(2, ranked(1, 0)), Update(5, 1), Remove(15), Update(5, 2)] }),
	# Rows trade places across a window's edge in one event.
	plain({ ..quiet, ops: [Put(14, ranked(7, 2)), Put(9, ranked(0, 1)), Put(10, ranked(0, 0)), Put(8, ranked(6, 0))], split: True }),
	# An undo of the turn so far, alone and then followed by another write.
	plain({ ..quiet, ops: [Put(6, ranked(0, 2)), Remove(8), Update(9, 1), Undo] }),
	plain({ ..quiet, ops: [Remove(0), Remove(2), Undo, Update(0, 1), Undo, Remove(13)], split: True }),
	# A decision that writes nothing at all.
	plain(quiet),
]

## Runs of writes around the size at which a view rebuilds instead of
## absorbing the changes: more than an eighth of its rows plus eight. One
## event's changes are then absorbed by the larger views; the smaller ones
## rebuild from the table.
many_steps : List(Step)
many_steps = [
	wrote(Fill(0, 8, 5)),
	wrote(Fill(4, 9, 17)),
	wrote(Fill(11, 10, 2)),
	wrote(Sweep(0, 16, 2)),
	wrote(Fill(2, 11, 9)),
	plain({ ..quiet, ops: [Sweep(3, 9, 1), Remove(4), Sweep(8, 8, 2)] }),
	wrote(Fill(0, 16, 40)),
	plain({ ..quiet, ops: [Remove(1), Remove(3), Remove(5), Remove(7), Remove(9), Remove(11), Remove(13), Remove(15)] }),
	plain({ ..quiet, ops: [Sweep(0, 16, 0), Sweep(0, 16, 1)], split: True }),
	wrote(Fill(1, 15, 3)),
]

## Whole rewrites of the table: by `load` and `update_all` among keyed
## writes, by setting a new table, and by the reset of the table's group.
rewrite_steps : List(Step)
rewrite_steps = [
	# Keyed writes before and after a load in one event.
	plain({ ..quiet, ops: [Put(1, ranked(0, 1)), Load(7, 9), Update(12, 1), Remove(1)] }),
	# Every row changes shade; then every row is written and left equal.
	wrote(All(2)),
	wrote(All(3)),
	# A new table put in the cell, then refined by keyed writes.
	plain({ ..quiet, head: Fresh(4, 12), ops: [Remove(4), Insert(4, ranked(0, 0))] }),
	# After a rewrite an undo has nothing to go by.
	plain({ ..quiet, ops: [All(0), Undo, Put(3, ranked(0, 2))], split: True }),
	# An empty table, and rows into it.
	wrote(Load(0, 0)),
	plain({ ..quiet, ops: [Insert(6, ranked(3, 0)), Insert(2, ranked(3, 2))] }),
	# The group's reset puts back the rows the table was described with,
	# not the ones it started with, and the serial with them.
	plain({ ..quiet, tick: True }),
	plain({ ..quiet, tick: True }),
	plain({ ..quiet, head: Reset }),
	# "Start again, but with this": the reset, then writes of its cells.
	plain({ ..quiet, head: Reset, ops: [Put(8, ranked(0, 0)), Remove(3)], tick: True }),
	plain({ ..quiet, head: Fresh(9, 0) }),
	plain({ ..quiet, head: Reset, ops: [Remove(2), Remove(7), Undo], split: True }),
]

## Changes of a view's listing and of its window, alone and in the event
## that writes the table.
window_steps : List(Step)
window_steps = [
	# Scroll by one, by a page, to the last rows, past the end, and back.
	plain({ ..quiet, window: To({ start: 1, count: 4 }) }),
	plain({ ..quiet, window: To({ start: 5, count: 4 }) }),
	plain({ ..quiet, window: To({ start: 8, count: 4 }) }),
	plain({ ..quiet, window: To({ start: 19, count: 6 }) }),
	plain({ ..quiet, window: To({ start: 2, count: 0 }) }),
	plain({ ..quiet, window: To({ start: 0, count: 5 }) }),
	# The same window again changes nothing.
	plain({ ..quiet, window: To({ start: 0, count: 5 }) }),
	# The first row goes in the event that makes the window longer, and the
	# last row in the one that scrolls down.
	plain({ ..quiet, ops: [Remove(0)], window: To({ start: 0, count: 6 }) }),
	plain({ ..quiet, ops: [Remove(9)], window: To({ start: 3, count: 3 }) }),
	# A filter, an order, and the same listing again.
	plain({ ..quiet, listing: To({ show: Only(0), order: ByRank }) }),
	plain({ ..quiet, listing: To({ show: Only(0), order: ByKeyDown }) }),
	plain({ ..quiet, listing: To({ show: Only(0), order: ByKeyDown }) }),
	# The listing, the window and the table in one event, with `c` mounted
	# by it: `c` shows `a`'s listing in the opposite order.
	plain({ ..quiet, flip: True, listing: To({ show: All, order: ByKey }), window: To({ start: 3, count: 6 }), ops: [Insert(1, ranked(2, 1))] }),
	# Every row's shade changes in the event that changes the order.
	plain({ ..quiet, listing: To({ show: All, order: ByRank }), ops: [Sweep(0, 16, 2)] }),
	# A whole rewrite under a window in the middle of the order, then a
	# scroll to the end of the new rows.
	wrote(Load(2, 13)),
	plain({ ..quiet, window: To({ start: 9, count: 6 }) }),
]

## A view mounted and unmounted by a branch, and views in the rows of a
## list, while the table changes.
mount_steps : List(Step)
mount_steps = [
	# `c` mounts in the event that writes rows it draws, takes writes while
	# mounted, and unmounts in an event that writes more.
	plain({ ..quiet, flip: True, ops: [Put(9, ranked(7, 2)), Remove(10)] }),
	wrote(Update(3, 1)),
	Click(C, 0, Mark),
	plain({ ..quiet, flip: True, ops: [Remove(9)] }),
	plain({ ..quiet, flip: True }),
	# The lanes trade places, with a row marked in one: it moves with its
	# lane. Then a lane is added between them in an event that fills it.
	Click(Lane(2), 0, Mark),
	plain({ ..quiet, lanes: To([2, 0]) }),
	plain({ ..quiet, lanes: To([2, 1, 0]), ops: [Put(1, ranked(2, 1)), Update(14, 2)] }),
	# A lane goes while its rows are written, and all go and come back.
	plain({ ..quiet, lanes: To([1, 0]), ops: [Sweep(0, 16, 2)] }),
	plain({ ..quiet, lanes: To([]), flip: True }),
	plain({ ..quiet, lanes: To([0, 1, 2]), ops: [Load(5, 16)] }),
	Click(Lane(1), 1, Drop),
	Click(Lane(0), 2, Tint),
]

## `b` holds its listing and its window in a state of its own, written in
## the event that writes the table. One pass settles both, from the root:
## the state joins it at its own site, above `b` and `e`, so each of them
## meets the table, its listing and its window together.
local_steps : List(Step)
local_steps = [
	# The window alone, then the window in the event that removes rows it
	# drew.
	both({ ..quiet, local_window: To({ start: 0, count: 5 }) }),
	both({ ..quiet, local_window: To({ start: 2, count: 2 }), ops: [Remove(15), Remove(14)] }),
	# The listing in the event that writes a row only the new listing keeps.
	both({ ..quiet, local_listing: To({ show: All, order: ByRank }), ops: [Update(0, 1)] }),
	# The listing, the window and the table, as one `update` for each write.
	both({ ..quiet, local_listing: To({ show: Only(1), order: ByKey }), local_window: To({ start: 0, count: 6 }), ops: [Update(10, 2), Put(12, ranked(7, 1))], split: True }),
	# Every view's listing and window, the lanes and the table in one event.
	both({ ..quiet, local_listing: To({ show: Except(0), order: ByKey }), local_window: To({ start: 0, count: 6 }), listing: To({ show: Only(1), order: ByRank }), window: To({ start: 0, count: 6 }), flip: True, lanes: To([1, 2]), ops: [Put(2, ranked(5, 2)), Remove(8)], tick: True }),
	# From the other controls `b`'s state stays as it is.
	plain({ ..quiet, local_window: To({ start: 0, count: 1 }), ops: [All(1)] }),
	both(quiet),
]

## A row's own state: its marks stay while the row is drawn, through a
## move and a rebuild, and start again once it has left the window.
marks_steps : List(Step)
marks_steps = [
	Click(A, 3, Mark),
	Click(A, 3, Mark),
	Click(A, 0, Mark),
	# The first row, marked once, moves down two places past rows that stay.
	wrote(Replace(0, ranked(2, 0))),
	# A whole rewrite that leaves every row equal keeps the rows drawn.
	wrote(All(3)),
	# `both` marks a row and raises its rank in one event: the row stays
	# first, then moves down the window with its marks, then leaves it.
	Click(A, 0, Both),
	Click(A, 0, Both),
	Click(A, 2, Both),
	# `bump` and `tint` write a row through its `State`, and `drop` removes
	# one through the table's cell.
	Click(A, 2, Bump),
	Click(B, 0, Tint),
	Click(Lane(0), 0, Mark),
	Click(Lane(0), 0, Drop),
	# The other table's rows have marks and buttons of their own.
	Click(D, 1, Mark),
	Click(D, 1, Bump),
	Click(D, 0, Drop),
	# A scroll away and back: the rows return without their marks.
	Click(A, 1, Mark),
	plain({ ..quiet, window: To({ start: 4, count: 4 }) }),
	plain({ ..quiet, window: To({ start: 0, count: 4 }) }),
]

## One event that writes two of a view's table, listing and window changes
## the rows the view draws once, from the window it had to the window it
## ends with: a row both windows hold is one row throughout and keeps its
## marks (design.md, "Observable lifetime rules"), and no row is created
## that the event does not leave drawn. A site that took the three one
## after another would dispose a row the event keeps, or create one it
## never shows.
once_steps : List(Step)
once_steps = [
	# `a` draws keys 0, 8, 15 and 14, and 14 is marked. One event inserts
	# key 1 above them and moves the window down by one: the window holds
	# 8, 15 and 14 before and after, 0 leaves and 1 enters.
	Click(A, 3, Mark),
	plain({ ..quiet, ops: [Insert(1, ranked(0, 0))], window: To({ start: 1, count: 4 }) }),
	# The order turned round and the window moved to its other end: the
	# four rows drawn stay, in another order, and one more enters.
	plain({ ..quiet, listing: To({ show: All, order: ByRankDown }), window: To({ start: 6, count: 5 }) }),
	# The listing, the window and the table in one event.
	plain({ ..quiet, listing: To({ show: Except(0), order: ByKey }), window: To({ start: 0, count: 4 }), ops: [Remove(0), Put(2, ranked(1, 2))], split: True }),
	# `b` draws 14, 9 and 4, and 14 is marked. Its listing and window are
	# a state of its own, written with the table. The row above its
	# window goes while the window moves up by one, and the same three
	# rows stay. `e` reads that state through a `derive`, in the opposite
	# order: a marked row of it stays too.
	Click(B, 0, Mark),
	Click(E, 1, Mark),
	both({ ..quiet, local_window: To({ start: 0, count: 3 }), ops: [Remove(15)] }),
	# Its order turns round and its window moves in the event that puts a
	# row between two it keeps.
	both({ ..quiet, local_listing: To({ show: Except(0), order: ByKey }), local_window: To({ start: 2, count: 3 }), ops: [Put(6, ranked(2, 1))] }),
	# `c` shows `a`'s listing the other way round: mounted, it takes a
	# change of that listing in the event that writes rows it draws.
	plain({ ..quiet, flip: True }),
	Click(C, 1, Mark),
	plain({ ..quiet, listing: To({ show: All, order: ByRank }), ops: [Update(8, 1), Remove(1)] }),
	# The lanes trade places in the event that changes every row's shade.
	Click(Lane(2), 0, Mark),
	plain({ ..quiet, lanes: To([2, 0, 1]), ops: [Sweep(0, 16, 2)] }),
	# Every view's listing and window and the table, from `b`'s control.
	both({ ..quiet, local_listing: To({ show: All, order: ByRankDown }), local_window: To({ start: 1, count: 4 }), listing: To({ show: Only(1), order: ByKeyDown }), window: To({ start: 1, count: 3 }), ops: [Fill(3, 6, 11), Remove(14)], split: True }),
]

## Copies of a table: one saved and put back while it is still the cell's
## own table and after the table has moved on, and the other table's put in
## this one's cell. Writes of the other table, which `d` alone draws.
copy_steps : List(Step)
copy_steps = [
	# Saved, then put back at once and written: the copy is the cell's own
	# table still, and the writes after it are keyed.
	reads({ ..quiet, save: True }),
	reads({ ..quiet, head: Restore, ops: [Put(1, ranked(0, 1)), Remove(0)] }),
	# Put back after those writes: a whole rewrite to the rows saved.
	reads({ ..quiet, head: Restore }),
	# Saved in the event that writes the table three times: the copy is the
	# table as it was before the event. Put back in an event that writes it
	# three times again: the table has then taken as many writes as its
	# views last saw, and is still another table.
	reads({ ..quiet, save: True, ops: [Remove(8), Remove(15), Update(5, 2)] }),
	reads({ ..quiet, head: Restore, ops: [Update(8, 1), Update(15, 1), Update(5, 1)], split: True }),
	# Without a reading there is nothing to put back.
	plain({ ..quiet, head: Restore, save: True }),
	# The other table's rows, then writes of each table in one event.
	reads({ ..quiet, head: Borrow, ops: [Remove(9)] }),
	plain({ ..quiet, spare: Wrote(Put(0, ranked(7, 0))), ops: [Put(0, ranked(0, 0))] }),
	plain({ ..quiet, spare: Wrote(Remove(3)) }),
	plain({ ..quiet, spare: Wrote(Fill(0, 12, 6)) }),
	plain({ ..quiet, spare: Wrote(All(1)) }),
	reads({ ..quiet, head: Borrow, save: True, spare: Wrote(Sweep(0, 16, 2)) }),
	reads({ ..quiet, head: Restore }),
]

## A session written as steps. Its bytes must decode to the steps it was
## written as, so an example cannot quietly stop meaning what it says.
ex : Str, List(Step) -> Fuzz.Example(Input)
ex = |name, steps| Fuzz.example({
	name,
	revision: "1",
	make: || {
		events = bytes_of(steps)
		if steps_of(events) != steps {
			crash "table-view: the example ${name} does not decode to the steps it is written as"
		} else {
			{ mode: 0, events }
		}
	},
})

target = Fuzz.target_with!({
	name: "table-view",
	examples: [
		ex("keyed", keyed_steps),
		ex("batch", batch_steps),
		ex("many", many_steps),
		ex("rewrite", rewrite_steps),
		ex("window", window_steps),
		ex("mount", mount_steps),
		ex("local", local_steps),
		ex("marks", marks_steps),
		ex("copies", copy_steps),
		ex("one-change", once_steps),
		Fuzz.example({ name: "series", revision: "1", make: || { mode: 1, events: [] } }),
	],
	generator: { mode: Fuzz.constant(0), events: Fuzz.list(Fuzz.u8, 640) }.Fuzz,
	test!,
	show: |{ mode, events }| if (mode == 1) "a seeded series" else Str.inspect(steps_of(events)),
})
