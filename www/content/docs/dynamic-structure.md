+++
title = "Lists, Conditionals, and Components"
description = "Conditional branches, keyed lists, row state, keyed selection and components, and the identity rules behind them."
weight = 6
template = "page.html"
+++

# Lists, Conditionals, and Components

Dynamic structure is UI that appears, disappears or repeats. Each mechanism on
this page creates *scopes*: a branch, a row or a component owns everything
mounted inside it and releases it when it goes. The snippets come from
`www/samples/structure.roc`, a small mail view:

{{ sample(file="structure.roc", region="model") }}

## Conditionals

`Engine.when` takes a `Val(ctx, Bool)` and two functions, and builds only the
branch that is selected:

{{ sample(file="structure.roc", region="when") }}

When the condition flips, the departing branch is disposed (its nodes removed,
its state released, its timers cancelled) and the other branch is built. Use
`Engine.text("")` for "nothing".

`Engine.switch` selects among several branches by value. It takes the list of
every case, so it knows what all of its branches read:

{{ sample(file="structure.roc", region="switch") }}

A value that is not in the case list is a contract error. Because unselected
branches are never built, a branch may contain the same function again:
recursive UI, such as a tree, needs no special support.

## Keyed lists

`Engine.each(items, key, template)` shows one row per item:

{{ sample(file="structure.roc", region="each") }}

The key function gives each row its identity. Keys are compared as exact
strings, and two items with the same key in one list are a contract error
naming the key, never a silent merge. Choose a key from the domain (an id),
not from the position.

The template runs once per list and receives a `RowRef` rather than an item:

{{ sample(file="structure.roc", region="row") }}

- `row.key()` and `row.field(f)` are values in the row's context. A hole that
  reads `row.field(...)` is re-evaluated only for rows whose item changed.
- Handlers read the row they fired in: `update_by(id, f)` passes the clicked
  row's key.
- Outer values and states are brought in with `lift_row`.
- A row template must produce a single element, and may not declare a focus
  reference.

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
| Hide with a class or attribute | Everything stays live | Nodes stay |

State that must outlive a branch or a row — a draft that should survive
switching tabs, say — belongs in a state above it, keyed by your own ids.

## Components

`Engine.component(prop, sink, body)` makes a reusable piece of UI with typed
inputs and outputs:

{{ sample(file="structure.roc", region="component") }}

- **The prop** is a value from the caller. The body sees it as
  `Val(Comp(p, a), p)` and cannot read anything else of the caller's.
- **Actions** go outward. The body gets a handle on its action list and appends
  to it with `push`, `push_by` or `push_value_by`.
- **The sink** turns each action into a write of a caller state, in the same
  turn. `Engine.sink(state, reducer)` writes one state; `Engine.split` routes
  actions to two sinks.

Because the body is typed only by its prop and action types, it is compiled
once however many times and places it is used. That makes components the main
tool for keeping code size in check as an app grows. A disposed component's
requests in flight are delivered to its caller, and their actions still reach
the sink.
