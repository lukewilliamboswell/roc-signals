+++
title = "Tutorial"
description = "Build a to-do list on a store, a table and a view of it, with one decision, local storage and a passing test suite."
weight = 4
template = "page.html"
+++

# Tutorial

This tutorial builds a to-do list. It uses each of the three places state
lives ([Thinking in Signals](@/docs/thinking-in-signals.md#where-state-lives)):
a table of to-dos and two cells in the app's store, and one piece of local
state. Along the way it writes a decision and tests it, draws a view of the
table, saves the list to local storage, and checks all of it with specs. The
finished app is in `www/samples/todos/`; its entry points are the same as
the counter's in [Getting Started](@/docs/getting-started.md).

Each step is explained in a sentence or two here. The topic guides that
follow teach each idea in full.

## The store

Start with the data. A to-do has a title and is open or done. The app holds
its to-dos, the key the next one takes, and the title being typed:

{{ sample(file="todos/Todos.roc", region="store") }}

- The store is the app's shared state, described once. Each field is a
  *cell*, and `Todos.h` holds a handle on each, which the rest of the app
  reads and writes through.
- The to-dos are a *table*: a cell that holds rows by key. The user changes
  them one at a time (checks one off, removes one), and a table's writes say
  which row they touch, so the list on the page follows a change by touching
  that row, however long the list is.
- The key is a number the app hands out, not the title. `next` is the number
  the next to-do gets.

## Adding a to-do: one decision

Submitting the form changes three things that must agree: the table gains a
row, the next key moves on, and the draft is cleared. Or it changes nothing,
when the title is blank or the list has it already. One pure function
decides which, and returns every write:

{{ sample(file="todos/Todos.roc", region="add") }}

- `added` is a *decision*: a function from a reading to a list of writes.
  `cell.put(value)` and `cell.change(f)` are values that say what to write;
  the engine applies the list when the form is submitted.
- `adding` is the reading. Three values are combined into one with Roc's
  record builder (`{ ... }.Val`), and mapped down to the three small things
  the decision needs. It is read once, when the form is submitted and before
  anything is written. The decision is handed whether the title is listed,
  not the table, so it holds nothing large while it decides.
- The table is changed with `change` and one of its own operations,
  `insert`. That is how the table knows which row was written.
- The draft is a cell, not local state of the form, because this decision
  must clear it or keep it from the same reading that decides the rest.

Because a decision is an ordinary function, it is tested with no engine and
no browser. `store.after(writes)` applies a list to the store, and `read`
reads a cell of the result:

{{ sample(file="todos/Todos.roc", region="expects") }}

Run them with `roc test` in the app's directory.

## The list: a view of the table

A table has no order of its own. A *view* draws the rows a query keeps, in
the query's order. The query is plain data, here which to-dos to show, and
`plan` turns it into the three functions a view needs:

{{ sample(file="todos/Todos.roc", region="plan") }}

`keep` chooses the rows, `sort` gives the value a row is ordered by, and
`compare` orders two of those values (`by_key` answers `Before`, `Same` or
`After` for two keys, the smaller first). Keys are handed out in order, so
sorting by key is the order the to-dos were added in.

{{ sample(file="todos/Todos.roc", region="list") }}

- `Engine.each_view` draws the view. When a row of the table is written, the
  view places that row again and touches only it on the page.
- `showing` is *local state*: `Engine.state(All, ...)` creates it for this
  piece of the view. Nothing else in the app reads which to-dos the list
  shows, so it does not belong in the store. Its buttons write it with a
  reducer, `showing.update(...)`.
- A view draws a window of its rows. A to-do list is short, so it draws
  every row: `Engine.every_row`.

## One row

The row template runs once for the whole view, not once per row. It is
handed the row's key and a `State` of the row:

{{ sample(file="todos/Todos.roc", region="row") }}

The checkbox reads and writes its own row through `todo`: it cannot touch
another row. Removing a row changes the table itself, so the button's
handler is a decision over the table's cell, given the row's key when it is
pressed. Each control's accessible name includes the title, which is how
assistive technology, and the specs, tell the rows apart.

## The page

{{ sample(file="todos/Todos.roc", region="view") }}

Going through it:

- The form's `submit` runs the decision. `Engine.handle_by(reading, decide)`
  makes a handler of it. The runtime prevents the browser's default for
  every form, so submitting never reloads the page.
- The text box shows the draft, and each keystroke puts the box's new text
  in the draft's cell. `Engine.handle` gives a decision the event's payload.
- `todos` is the table's value, read here without a view by the empty note,
  the counter and the storage effect. Such a reader is evaluated on every
  write to the table, which is fine for a count.
- `Engine.when` shows "Nothing to do." only while the table is empty.
- Nothing is passed down to `Todos.list` or to a row. Every part of the view
  reaches the store's cells directly.

## Saving to local storage

Two pieces make the list survive a reload. The program declares the storage
key it reads at startup and starts the store from it, and the view saves the
list whenever it changes:

{{ sample(file="todos/Todos.roc", region="storage") }}

`Engine.program_store` is the program of an app with a store. The runtime
reads each declared key before mounting and passes the values in `Boot`, and
`store.with_initial(cell, value)` starts a cell at a value that depends on
them. The saving half is the last child of the view:

{{ sample(file="todos/Todos.roc", region="persist") }}

`on_change` issues its requests each time the watched value changes after
mount. `StorageSet` is a command, so there is no result to react to and the
reaction is `Engine.ignore`. [Effects and the Browser](@/docs/effects-and-browser.md)
covers requests that do return results.

The format is a pair of pure functions, so one more `expect` pins it:

{{ sample(file="todos/Todos.roc", region="storage-expect") }}

## Specs

The `expect`s test the logic. Specs test what a user sees and does. The
first walks through the main path:

{{ sample(file="todos/specs/add-toggle-remove.scm", syntax="scheme") }}

Two details are worth noticing. The box keeps the text the user typed while it
has focus, even after the decision clears the draft: the runtime never
overwrites a focused control, so a value written while the user is typing
cannot move their caret. The `blur` step lets the cleared draft through. And
`expect-local-storage` checks the exact text the effect saved.

The duplicate rule and the restore path get their own specs:

{{ sample(file="todos/specs/duplicate-titles.scm", syntax="scheme") }}

{{ sample(file="todos/specs/restore.scm", syntax="scheme") }}

The last one checks the view, and how much work a change does: checking a
to-do off while only open ones are shown removes one row and builds none.

{{ sample(file="todos/specs/show-open-and-done.scm", syntax="scheme") }}

`blueprint run check` builds this sample and runs these specs natively and in
Chrome, so the code on this page is known to work.

## Where to go next

- [Local State, Events, and Forms](@/docs/state-and-events.md) for handlers,
  validation and derived values.
- [Shared State](@/docs/shared-state.md) for the store, decisions and resets.
- [Tables and Views](@/docs/tables-and-views.md) for queries, windows and
  what a write costs.
- [Testing](@/docs/testing.md) for every spec step.
