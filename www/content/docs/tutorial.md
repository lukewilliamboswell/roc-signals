+++
title = "Tutorial"
description = "Build a todo list with a form, a keyed list, a conditional, local storage and a passing test suite."
weight = 4
template = "page.html"
+++

# Tutorial

This tutorial builds a todo list. It covers one state record, a form, a keyed
list with row handlers, a conditional, a value saved to local storage, and
specs that check all of it. The finished app is in `www/samples/todos/`; its
entry points are the same as the counter's in
[Getting Started](@/docs/getting-started.md).

## The model

Start with the data. A todo has a title and a done flag; the model holds the
list and the text being typed:

{{ sample(file="todos/Todos.roc", region="model") }}

`Ctx` is the context inside the model's state. `Item` is the context inside one
row of the list, which the row template uses.

## Pure reducers

Every change the user can make is an ordinary function from the old model to
the new one. They need no platform API and are easy to test with `expect`:

{{ sample(file="todos/Todos.roc", region="reducers") }}

`add` refuses a blank title and a title that is already on the list. That is
not only tidiness: the list is keyed by title, and two rows with the same key
are a contract error that stops the app.

## The view

{{ sample(file="todos/Todos.roc", region="view") }}

Going through it:

- `items` is a value read from the state, shared by the list, the empty note,
  the counter and the storage effect.
- The text box shows `m.draft`, and its handler `set_value` receives the box's
  new text on every keystroke.
- The form's `submit` applies `add`. The runtime prevents the browser's
  default for every form, so submitting never reloads the page.
- `Engine.each(items, |t| t.title, ...)` shows one row per todo, keyed by
  title. When the list changes, surviving rows keep their DOM nodes; only
  added, removed or changed rows cost work.
- `Engine.when` shows "Nothing to do." only while the list is empty.

## One row

The row template runs once for the whole list, not once per row. It describes
a row in terms of a `RowRef`, which reads the current row when the engine needs
it:

{{ sample(file="todos/Todos.roc", region="row") }}

The model's state handle comes from outside the row, so it is lifted into the
row's context with `lift_row`. `update_by(title, Todos.toggle)` reads the
row's title when the click happens and passes it to the reducer, so one
handler serves every row. Each control's accessible name includes the title,
which is how assistive technology, and the specs, tell the rows apart.

## Saving to local storage

Two pieces make the list survive a reload. The program declares the storage
key it reads at startup, and the view saves the list whenever it changes:

{{ sample(file="todos/Todos.roc", region="storage") }}

`Engine.program_boot` is `Engine.program` with boot data: the runtime reads
each declared key before mounting and passes the values in `Boot`. The saving
half is the last child of the view:

{{ sample(file="todos/Todos.roc", region="persist") }}

`on_change` issues its requests each time the watched value changes after
mount. `StorageSet` is a command, so there is no result to react to and the
reaction is `Engine.ignore`. [Effects and the Browser](@/docs/effects-and-browser.md)
covers requests that do return results.

## Specs

The first spec walks through the main path:

{{ sample(file="todos/specs/add-toggle-remove.scm", syntax="scheme") }}

Two details are worth noticing. The box keeps the text the user typed while it
has focus, even after `add` clears the draft: the runtime never overwrites a
focused control, so a value written while the user is typing cannot move their
caret. The `blur` step lets the cleared draft through. And
`expect-local-storage` checks the exact text the effect saved.

The duplicate rule and the restore path get their own specs:

{{ sample(file="todos/specs/duplicate-titles.scm", syntax="scheme") }}

{{ sample(file="todos/specs/restore.scm", syntax="scheme") }}

`blueprint run check` builds this sample and runs these specs natively and in
Chrome, so the code on this page is known to work.

## Where to go next

- [State, Events, and Forms](@/docs/state-and-events.md) for validation,
  derived values and splitting state.
- [Lists, Conditionals, and Components](@/docs/dynamic-structure.md) for row
  state, keyed selection and components.
- [Testing](@/docs/testing.md) for every spec step.
