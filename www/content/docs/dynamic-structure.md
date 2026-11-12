+++
title = "Conditionals and Lists"
description = "Conditional branches, keyed lists of plain values, row state and keyed selection, and the identity and lifetime rules behind them."
weight = 8
template = "page.html"
+++

# Conditionals and Lists

Dynamic structure is UI that appears, disappears or repeats. Each mechanism on
this page creates *scopes*: a branch or a row owns everything mounted inside
it and releases it when it goes. The snippets come from
`www/samples/structure.roc`, a small mail view:

{{ sample(file="structure.roc", region="model") }}

## Conditionals

`Engine.when` takes a `Signal(ctx, Bool)` and two functions, and builds only the
branch that is selected:

{{ sample(file="structure.roc", region="when") }}

When the condition flips, the departing branch is disposed (its nodes removed,
its local state released, its timers cancelled) and the other branch is
built. Use `Engine.text("")` for "nothing".

`Engine.switch` selects among several branches by value. It takes the list of
every case, so it knows what all of its branches read:

{{ sample(file="structure.roc", region="switch") }}

A value that is not in the case list is a contract error. Because unselected
branches are never built, a branch may contain the same function again:
recursive UI, such as a tree, needs no special support.

`Engine.remount_on(key, body)` is the third of the family: one body, built
again whenever its key changes. It is how local state that belongs to one
key starts again, and
[Local State, Events, and Forms](@/docs/state-and-events.md#starting-again)
shows it.

## Keyed lists

`Engine.each(items, key, template)` shows one row per item of a list that is
a plain value:

{{ sample(file="structure.roc", region="each") }}

The key function gives each row its identity. Keys are compared as exact
strings, and two items with the same key in one list are a contract error
naming the key, never a silent merge. Choose a key from the domain (an id),
not from the position.

The template runs once per list and receives a `RowRef` rather than an item:

{{ sample(file="structure.roc", region="row") }}

- `row.key()` and `row.field(f)` are values in the row's context. A hole that
  reads `row.field(...)` is re-evaluated only for rows whose item changed.
  `row.item()` is the whole item, for a handler that takes it as its
  reading: `Engine.handle_by(row.item(), ...)`.
- Handlers read the row they fired in: `update_by(id, f)` passes the clicked
  row's key.
- Outer values and local states are brought in with `lift_row`. Cells of the
  store need no lift.
- A row template must produce a single element, and may not declare a focus
  reference.

When the list changes, `each` compares the new list with the rows it drew:
surviving rows keep their nodes and move if they must, and only added,
removed or changed rows cost work on the page. The comparison itself is
linear in the list. That suits a list that is small or computed, such as the
options of a select, the items of an answer, or a few rows in local state as
here. Rows the user edits by key, and anything sorted, filtered or long,
belong in a table drawn through a table view, where a write names its row and
nothing is compared: see [Tables and Table Views](@/docs/tables-and-views.md).

### Keyed selection

"Is this row the selected one?" read naively from the model would re-evaluate
every row whenever the selection changes. `Engine.keyed(selected, yes, no)` and
`row.select(...)` express it so the engine re-evaluates only the previously
selected row and the newly selected one.

### Row state

State created inside a row template belongs to that row:

{{ sample(file="structure.roc", region="row-state") }}

It survives reordering, filtering that keeps the key, and changes to the
row's item. It is released when the key leaves the list. Reinserting the key
later starts a fresh row.

## Lifetime rules

| Change | State and effects | DOM |
|---|---|---|
| Reorder a surviving key | Kept | Existing nodes move |
| Insert or remove another key | Unaffected rows kept | Only affected rows change |
| Change a row's item, same key | Row kept; holes reading the item re-evaluate | Only changed holes update |
| Remove a key | Row disposed; subscriptions and timers stop; requests in flight report to the list | Row removed |
| Reinsert a removed key | A new row | New nodes |
| Change an item's key | The old row ends, a new one starts | Remove and insert |
| Flip a `when` or `switch` | The departing branch is disposed | The new branch is built |
| Change the key of a `remount_on` | The body is disposed; local state inside starts again | The body is built again |
| Hide with a class or attribute | Everything stays live | Nodes stay |
| Write a cell of the store | The cell and everything mounted survive; its readers refresh | Only changed holes update |

The rows of a table view follow the same rules, with one more way to
go: leaving the table view's window
([Tables and Table Views](@/docs/tables-and-views.md#row-state)).

State that must outlive a branch or a row — a draft that should survive
switching tabs, say — belongs in the store: a cell, or a field of a table's
row. The engine never keeps a disposed scope alive for you.
