+++
title = "Tutorial"
description = "Build a to-do list on a store, a table and a table view, with one decision, local storage and a passing test suite."
weight = 4
template = "page.html"
+++

# Tutorial

This tutorial builds a to-do list. It uses each of the three places state lives
([Thinking in Signals](@/docs/thinking-in-signals.md#where-state-lives)): a
table of to-dos and two cells in the app's store, and one piece of local state.
Along the way it writes a decision and tests it, draws a table view, saves the
list to local storage, and checks all of it with specs. The first checkpoint is
a working app in a new directory, using the tool and platform matching these
docs. Then you
will explore its files, try each behavior and connect it to the code. The later
snippets are named parts of that complete app; they are not separate programs to
paste into an empty file.

You need the tools from [Getting Started](@/docs/getting-started.md), but no
repository checkout. The topic guides that follow teach each idea in full.

## Create and run the app

If the Getting Started server is still running, stop it with Ctrl+C or open
another terminal. Start in a working directory where you want a new
`my-todos` app. Download the tool matching these docs and let it create the
page, platform declaration and spec directory:

```sh
curl -fLO "{{ signals_tool_url() }}"
roc signals.roc init my-todos
cd my-todos
```

Add the complete {{ sample_download(file="todos/Todos.roc", label="Todos.roc module") }}
and its four specs. These commands fetch the same checked files this page shows:

```sh
todo_samples={{ sample_url(file="todos") }}
curl -fL "$todo_samples/Todos.roc" -o Todos.roc
curl -fL "$todo_samples/specs/add-toggle-remove.scm" -o specs/add-toggle-remove.scm
curl -fL "$todo_samples/specs/duplicate-titles.scm" -o specs/duplicate-titles.scm
curl -fL "$todo_samples/specs/restore.scm" -o specs/restore.scm
curl -fL "$todo_samples/specs/show-open-and-done.scm" -o specs/show-open-and-done.scm
rm Counter.roc specs/counter.scm
```

The last command removes only the counter module and spec that `init` just
wrote in this new app. Keep the generated `signals.roc` and `index.html`.

Open `main.roc`. Keep its complete first `app [main]` declaration, including
its generated platform URL and the `pf` name. Replace the imports and
`main` definition below that declaration with:

{{ sample(file="todos/main.roc", region="entry") }}

`main.roc` now imports the `Todos.roc` beside it and hands `Todos.program` to
the platform. Keep the platform URL that `init` generated: the generic
`<package release URL here>` shown in documentation examples is a placeholder,
not a replacement for that URL.

Your app's files are now:

```text
my-todos/
  signals.roc
  main.roc              edited imports and main; generated platform URL kept
  index.html            generated browser page
  Todos.roc             downloaded module
  specs/
    add-toggle-remove.scm
    duplicate-titles.scm
    restore.scm
    show-open-and-done.scm
```

Run the module's pure tests, the app's four specs, and the development server:

```sh
roc test main.roc
roc signals.roc test
roc signals.roc serve --port 8080
```

Open the address the server prints, normally `http://127.0.0.1:8080/`. If
that port is busy, use the different address it prints. Add “Water the
plants” and “Buy milk”, mark one done, try the three filters and reload. The
list survives. This is the first runnable checkpoint: all four specs pass,
and the browser shows the to-do form and list.

As a first edit, change the page title in `index.html` from `Counter` to
`To-do List`. Save it and watch the development server reload the page. Keep
it running while you explore the module below; stop it with Ctrl+C when you
need that terminal again.

## Open the module

`Todos.roc` starts with these imports. They use the same `pf` platform name
that `main.roc` declares:

{{ sample(file="todos/Todos.roc", region="imports") }}

The definitions that follow belong inside one type module:

{{ sample(file="todos/Todos.roc", region="module") }}

Its closing brace is near the end of the file, before the top-level
`expect`s. `Todos.TodoList` is the module's tag; it gives this store its own
identity. Keep this module opening and the imports when editing the sections
below.

## The store

Start with the data. A to-do has a title and is open or done. The app holds
its to-dos, the key the next one takes, and the title being typed:

{{ sample(file="todos/Todos.roc", region="store") }}

- The store is the app's shared state, described once. Each field is a
  *cell*, and `Todos.cells` holds each cell, which the rest of the app
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
  `cell.set(value)` and `cell.update(f)` are values that say what to write;
  the engine applies the list when the form is submitted.
- `adding` is the reading. Three values are combined into one with Roc's
  record builder (`{ ... }.Signal`), and mapped down to the three small things
  the decision needs. It is read once, when the form is submitted and before
  anything is written. The decision is handed whether the title is listed,
  not the table, so it holds nothing large while it decides.
- The table is changed with `update` and one of its own operations,
  `insert`. That is how the table knows which row was written.
- The draft is a cell, not local state of the form, because this decision
  must clear it or keep it from the same reading that decides the rest.

Because a decision is an ordinary function, it is tested with no engine and
no browser. `store.after(writes)` applies a list to the store, and `read`
reads a cell of the result:

{{ sample(file="todos/Todos.roc", region="expects") }}

Run them with `roc test main.roc` in `my-todos/`. In the browser, try a blank
title and then add the same title twice. The second submission keeps the
draft and adds no row, just as the decision says.

## The list: a table view

A table has no order of its own. A *table view* draws the rows a query keeps, in
the query's order. The query is plain data, here which to-dos to show, and
`plan` turns it into the three functions a table view needs:

{{ sample(file="todos/Todos.roc", region="plan") }}

`keep` chooses the rows, `sort` gives the value a row is ordered by, and
`compare` orders two of those values (`by_key` answers `Before`, `Same` or
`After` for two keys, the smaller first). Keys are handed out in order, so
sorting by key is the order the to-dos were added in.

{{ sample(file="todos/Todos.roc", region="list") }}

- `Engine.table_view` draws the table view. When a row of the table is written, the
  table view places that row again and touches only it on the page.
- `showing` is *local state*: `Engine.state(All, ...)` creates it for this
  piece of the view. Nothing else in the app reads which to-dos the list
  shows, so it does not belong in the store. Its buttons write it with a
  reducer, `showing.update(...)`.
- A table view draws a window of its rows. A to-do list is short, so it draws
  every row: `Engine.every_row`.

## One row

The row template runs once for the whole table view, not once per row. It is
handed the row's key and a `State` of the row:

{{ sample(file="todos/Todos.roc", region="row") }}

The checkbox delivers a Boolean checked state and reads and writes its own row through `todo`: it cannot touch
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
- `todos` is the table's value, read here without a table view by the empty note,
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

`watch_changes` issues its requests each time the watched value changes after
mount. `StorageSet` is a command, so there is no result to react to and the
reaction is `Engine.ignore`. [Effects and the Browser](@/docs/effects-and-browser.md)
covers requests that do return results.

The format is a pair of pure functions, so one more `expect` pins it:

{{ sample(file="todos/Todos.roc", region="storage-expect") }}

## Specs

The four files already downloaded into `my-todos/specs/` are also available
individually: {{ sample_download(file="todos/specs/add-toggle-remove.scm", label="add-toggle-remove.scm") }},
{{ sample_download(file="todos/specs/duplicate-titles.scm", label="duplicate-titles.scm") }},
{{ sample_download(file="todos/specs/restore.scm", label="restore.scm") }} and
{{ sample_download(file="todos/specs/show-open-and-done.scm", label="show-open-and-done.scm") }}.

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

## Check and build your app

After an edit, run both kinds of tests from `my-todos/`:

```sh
roc test main.roc
roc signals.roc test
roc signals.roc build
```

The first command checks the module's pure decisions and storage format; the
second checks all four `.scm` files against the app. `build` writes a deployable
`dist/` with the browser module, page and matching runtime. Serve that directory
over HTTP to deploy it; [Getting Started](@/docs/getting-started.md#build-it-for-deployment)
explains what to keep together. Check the tool's build output for the
optimization mode: a compiler workaround may explicitly select `--opt=dev`
instead of the usual `--opt=size`, as Getting Started explains.

You have a running app, its editable source and a test suite. As you make it
your own, use the specs to state what should stay true about adding, checking,
filtering and restoring a to-do.

## Where to go next

- [Local State, Events, and Forms](@/docs/state-and-events.md) for handlers,
  validation and derived values.
- [Shared State](@/docs/shared-state.md) for the store, decisions and resets.
- [Tables and Table Views](@/docs/tables-and-views.md) for queries, windows and
  what a write costs.
- [Testing](@/docs/testing.md) for every spec step.
