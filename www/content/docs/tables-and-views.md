+++
title = "Tables and Table Views"
description = "Rows held by key in the store, and a sorted, filtered window of them that follows each write at the cost of the rows written."
weight = 7
template = "page.html"
+++

# Tables and Table Views

A list the user edits is the place where "compare the old value with the new
one" costs most: one changed row would mean looking at every row. So rows
that are edited by key, and anything drawn sorted, filtered or long, are held
in a *table*. Every write to a table names the rows it touches, and a *table view*
draws part of the table from its changes, without ever comparing two lists.

The snippets on this page come from a league table, `www/samples/scores/`.

## A table is a cell

`Engine.table(rows)` describes a cell of the store that holds rows by key:

{{ sample(file="scores/Scores.roc", region="table") }}

- The key is a typed value of your choosing, here a `U64`. A table finds a
  row through the key's own equality and hash, and a key occurs once: two
  rows with one key are a contract error.
- A table has no order of its own. An order the user sees is worked out by a
  table view, from the rows' fields.
- The table is held in an ordinary cell, `Scores.cells.league.players`, read with
  `signal()` and written with `update`, like any other
  ([Shared State](@/docs/shared-state.md)).

The value in the cell is a `Table(k, v)`, from the `Table` module. It
changes only through its own operations, and that is how each write says
which rows it touched:

| Operation | What it writes |
|---|---|
| `table.insert(key, row)` | A row under a new key. A key already present is a contract error |
| `table.put(key, row)` | The row at `key`, inserted or replaced |
| `table.update(key, f)`, `table.replace(key, row)` | The row at `key`. A key the table does not hold leaves it unchanged |
| `table.remove(key)` | Removes the row at `key`. A missing key leaves the table unchanged |
| `table.update_all(f)`, `table.load(rows)` | Every row: a whole rewrite |
| `table.get(key)`, `table.contains(key)`, `table.len()` | Nothing: they read |
| `table.fold(start, f)`, `table.to_list()` | Nothing: they read every row, in no particular order. `to_list` gives each row with its key; sort the list before showing or comparing it |

## Draw a table view

A table view draws the rows a query keeps, in the query's order, and of those only
the rows inside a window. `Engine.table_view(table, { query, plan, window },
template)` is its site:

{{ sample(file="scores/Scores.roc", region="board") }}

The table view keeps the place of every row the query keeps. When a row is
written, it works out that row's place again and touches only that row on
the page: its text changes, it moves, or it enters or leaves the window.
What a write costs depends on the rows written, not on the size of the table.

### The query is data

`query` is a value the site can compare: the filter and the order the user
chose, the kind of thing a URL or a saved setting holds. `plan` turns it
into a `QueryPlan(k, v, s)`, the three functions a table view needs:

{{ sample(file="scores/Scores.roc", region="plan") }}

- `keep` says whether a row is in the table view.
- `sort` gives the value the row is ordered by.
- `compare` orders two sort values, answering `Before`, `Same` or `After`.

The order must be total: `compare` may answer `Same` only for a row's own
sort value, and two rows that compare `Same` are a contract error. End the
sort value with the key, as `Place` does, whatever the sorted field. A field
that never ties before or after an event can still tie during one: when one
event swaps two rows' places, the table view takes its writes one key at a time,
and after the first both rows hold the same place.

The query is data rather than the functions themselves because functions
cannot be compared: given a record of functions, the site could not tell a
new query from the same one. When the query changes to an unequal value the
table view builds itself again, with a pass over the table.

### The window

`window` is `{ start, count }`: the table view creates rows on the page only for
the `count` rows from position `start` of its order. Scrolling or paging is
a write of the window, and costs the rows that leave and enter. A window
that reaches past the last row draws the rows there are.

`Engine.every_row` is the window that draws every row the query keeps,
however many they come to: `window: Engine.const(Engine.every_row)`. Use it
for a list that is short by nature, such as the cards of a column. A long
list wants a window of its own: with every row drawn, one row that enters,
leaves or moves costs a comparison across all of them.

Here the listing and the window are cells, so buttons change them. Either
could as well be local state or a constant: each is just a `Signal`.

### Following a scrollbar

A fixed-height list can write the same window from a scroll report instead
of a paging button:

{{ sample(file="scores/Scores.roc", region="scroll") }}

The scroller's CSS fixes its height, and every row uses the height the
window calculation assumes. A spacer keeps the full row count's height;
only the drawn rows change with the window. Set `overflow-anchor: none`
and keep the spacer independent of drawn rows, so a window write cannot
move the scrollbar and produce another scroll report. A size report can
also change the window's count as its container grows or shrinks. Both
writes use the ordinary turn and preserve rows kept by the final window.

This model assumes fixed-height rows. Measuring each row, page scrolling
and variable-height virtualization are outside the platform's layout
vocabulary. [Scrolling and layout](@/docs/effects-and-browser.md#scrolling-and-layout)
describes size/seen observations and their lifetimes.

## A drawn row is handed its row

The template runs once for the whole table view, not once per row. It receives the
row's key, fixed for the drawn row's lifetime, and a `State` of the row:

{{ sample(file="scores/Scores.roc", region="row") }}

- `player.signal()` reads the row at this key. `player.update(f)` and the other
  `State` reducers write that row and no other, so a row's own handlers
  cannot name the wrong row or the wrong table.
- Any other write (removing the row, inserting one, writing several) changes
  the table itself, so it is a decision over the table's cell.
- A function written over a `State` draws a table's row unchanged, as it
  draws a local state or a cell.
- The template must return a single element. Values from outside the row
  enter with `lift_row`; cells need no lift.

## Write the table

Writes to a table stand in a decision's list beside its other writes:

{{ sample(file="scores/Scores.roc", region="writes") }}

- `joined` writes two cells that must agree, the table and the next key, in
  one decision.
- `awarded` makes several keyed writes in one event. Every table view absorbs each
  of them from the table's changes.
- `shown` changes the query and puts the window back at the top: a change of
  what is shown is a transition like any other.

The toolbar attaches them, with the two kinds of whole rewrite:

{{ sample(file="scores/Scores.roc", region="toolbar") }}

Write a table with `update`, never with a `set` of a table built from a
reading of the cell: that copies the table.

### Whole rewrites

`update_all`, `load`, a `set` of a new table (`Table.from_list(rows)`) and a
generated reset replace every row. They do not record each key: every table view
of the table builds itself again, with a pass over the table and a sort.
Rows that are in the window before and after are kept, not created again.

The `league` group's reset puts the table back to the rows it was described
with. A table described as `Engine.table([])` and filled later, with
`with_initial` or a `load`, resets to empty.

## Several table views, and plain readers

Any number of table views can draw one table, each with its own query and window.
They all follow the same writes:

{{ sample(file="scores/Scores.roc", region="podium") }}

A value that reads the table's cell without a table view is an ordinary reader:

{{ sample(file="scores/Scores.roc", region="reader") }}

It is evaluated on every write to the table, and pruned if its result is
equal. That is fine for a count or one row by key. Only a row of a table view
wakes for its own row alone.

## A drawn row's own state {#row-state}

State declared inside the template belongs to the drawn row, not to the
table:

{{ sample(file="scores/Scores.roc", region="cheers") }}

It moves with the drawn row when the row's place changes. It goes when the
drawn row leaves the window, whether by a scroll, a change of query or a move past the
window's edge, and a drawn row that comes back starts fresh. State that must
outlive that is a field of the row in the table.

| Change | The drawn row | Its own state |
|---|---|---|
| Its row in the table is written | Kept; holes that read the row re-evaluate | Kept |
| Its place in the order changes, inside the window | Moved, with its nodes | Kept |
| It leaves the window, or its key is removed | Removed | Gone |
| It enters the window | Created | Starts fresh |
| The query changes, or the table is rewritten whole | Kept if it is in the window before and after | Kept with it |
| One event writes the table, the query and the window together | Kept if it is in the window before the event and after it | Kept with it |

An event changes the rows a table view draws once, from the window before it to
the window after it, whatever it wrote on the way. A decision that inserts a
row above the window and moves the window down by one leaves every row on
the page where it was. Rows that enter in one event are created from the
first to the last, as the rows of a new table view are, so a request each row
issues when it is created goes out in the table view's order.

## Testing

A transition over a table is tested like any decision, by reading the table
of the store it leaves:

{{ sample(file="scores/Scores.roc", region="expects") }}

The table of that store keeps the changes, so a test can also
ask which rows a transition wrote: `table.inverse()` is one write for each,
and `table.changes()` each written key with its row as it was.

A spec pins what a write does on the page, and how much:

{{ sample(file="scores/specs/a-point-moves-a-row.scm", syntax="scheme") }}

Four metrics say what a write did to the rows drawn: `rows_created`,
`rows_removed`, `rows_moved`, and `rows_updated`, the drawn rows a table view kept whose
row was written ([Testing](@/docs/testing.md#work-budgets)).

## A table or a list?

`Engine.each` ([Conditionals and Lists](@/docs/dynamic-structure.md)) draws
a list that is a plain value, by comparing the new list with the rows it
drew. That comparison is linear in the list, which is right for a list that
is small or computed: the options of a select, the items of an answer, a few
rows in local state. Reach for a table when rows are edited by key, when the
list is sorted or filtered on the page, or when it is long.

## Costs and limits

- A keyed write costs each table view of the table a search for the row's place,
  and each plain reader of the table one evaluation.
- A change of query, a whole rewrite and the mount of a table view each cost a
  pass over the table and a sort of the rows kept. So does an event that
  writes a large share of the table's rows by key, more than about an
  eighth of them: the table view builds itself again, since that then costs less
  than placing each row. How few rows the table view keeps does not matter: a
  table view of ten rows of a large table follows a write of all ten row by row.
- A move costs the rows the table view draws, so keep a window on a long list.
- An event that writes several of a table view's table, query and window
  settles them together. A query or window derived from local state follows
  that state before the table view reads it. The table view compares the
  drawn rows before the event with the final window once, preserving every
  drawn row that remains in it.
- A write to a key the table does not hold writes nothing and reports
  nothing: an earlier write of the same event may have removed the row.
- A row read after its key left the table in the same event is a contract
  error.
- `Table.changes` retains the last turn that wrote this table, including
  across unrelated turns. The next writing turn clears it before its first
  modifier runs; further writes in that event keep the first earlier row
  per key. A signal can read these changes like any other part of the cell.
- `Table.inverse` gives writes that undo those retained changes, and
  `Table.apply` applies them. A later event's decision can read the inverse
  before its writes begin and use it to undo the last writing turn. Inside
  a modifier the inverse describes that event's writes instead. Keep an
  inverse in a history cell if it must survive the next write of the table.
  Earlier rows are held until that next write or disposal of their holder;
  there is no time bound, and no earlier whole table is kept. The next
  writing turn pays for freeing those earlier rows, so a single keyed write
  can also pay cleanup proportional to the previous turn's recorded keys.

Three compiler defects touch tables today, each with its upstream issue:

- Many writes to a table in one event are a fold over the keys, as `awarded`
  is, not a `while` loop over a `var` that holds the table: the loop copies
  the table on every pass in an optimised build
  ([roc-lang/roc#12971](https://github.com/roc-lang/roc/issues/12971)).
- A row template that needs something from outside is a lambda that passes
  it on with the key and the row, `|key, row| template(extra, key, row)`,
  not a function returned from a helper, which `roc check` rejects
  ([roc-lang/roc#12970](https://github.com/roc-lang/roc/issues/12970)).
- An optimised build can still copy a large table on each write
  ([roc-lang/roc#13019](https://github.com/roc-lang/roc/issues/13019), also
  tracked by [roc-lang/roc#12957](https://github.com/roc-lang/roc/issues/12957)).
  The instance holds its store outside the site's boxed closure; a bounded
  development-Wasm guard checks sparse-write bytes at two table sizes.
  That development result does not establish flat shipping allocations. The
  platform is designed for the fix, and nothing in an app changes when it
  lands.
