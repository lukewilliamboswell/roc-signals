+++
title = "Thinking in Signals"
description = "The model behind every Roc Signals app: a view that runs once, state in three places, writes that say what they touched, and turns."
weight = 3
template = "page.html"
+++

# Thinking in Signals

A Roc Signals app is a description. Your Roc code builds a tree of elements
once, at mount, and the engine keeps that tree alive and up to date. This page
explains the handful of ideas that description is made of. Each has a guide of
its own; this page is how they fit together.

## The view runs once

Most of a UI never changes: a heading, a form's layout, a button's label.
`Engine.element`, `Engine.text` and the `Html` helpers describe that structure,
and the engine creates it once.

The parts that can change are *sites*. A site is one of:

- a **local state** (`Engine.state`), which holds a value for the piece of
  the view inside it;
- a **derived value** (`Engine.derive`), which holds a value computed from
  others;
- a **conditional** (`Engine.when`, `Engine.switch`), which shows one branch,
  or a **remount** (`Engine.remount_on`), which builds its body again when a
  key changes;
- a **keyed list** (`Engine.each`), which shows one drawn row per item of a list;
- a **table view** (`Engine.table_view`), which shows a sorted, filtered
  window of a table's rows;
- an **effect** (`Engine.watch`, `Engine.watch_changes`, `Engine.on_cleanup`),
  which asks the outside world to do something.

Between them sit *holes*: text, attributes and element properties whose content comes from a signal.

Attribute text can be empty without being absent. `attr_s` always sets a
present value; `attr_presence` takes a signal of `Absent` or `Present(text)`
when the attribute should come and go. The hole compares both presence and
text, so changing between absent and empty is an update, while repeating
either is pruned.

Your view function is not called again after mount. There is no second tree
to compare with the first: the engine knows, from how the description was
built, which holes and sites read which state, and an event goes straight to
them.

## Every write says what it touched

One rule shapes how state is held: **every write says what it touched.** The
engine never finds a change by comparing a large value with an earlier copy
of it.

The reason is how Roc updates values. Roc has no mutable variables, but when
a value has exactly one holder the compiler updates it where it sits and
copies nothing. A long list can be edited in place as long as nobody else is
holding it. An engine that kept the previous value to compare with the new
one would be a second holder: every write would copy what it changes, and the
comparison would cost the size of the value on top.

So the engine keeps one holder for each piece of state and learns what
changed from the write itself, at two grains: which pieces of state an event
wrote and, inside a table, which rows.

For an app this means two things. State is changed through something that
knows what it writes (a reducer on one state, a write to one cell, a table's
operation on one key), never by handing the engine a whole new model to work
out the difference. And the shape of your state decides the cost of an
update, because the engine wakes the readers of the piece that was written.

## Where state lives

State lives in three places. Two are shared and belong to the whole app. The
third belongs to one piece of the view.

| Place | Use it for | Lives | Written by |
|---|---|---|---|
| A **cell** of the store | State more than one part of the app cares about: the session, the current location, a page's loaded data | As long as the app | Decisions: pure functions that return a list of writes |
| A **table**, a cell that holds rows by key | Rows the user edits, and anything drawn sorted, filtered or long | As long as the app | The table's operations on a key, in a decision or through the row a table view hands out |
| **Local state** | What one piece of the view cares about: whether a menu is open, the text of a draft | As long as that piece is mounted | Reducers on the state |

- The **store** is described once, at the root of the app. Every part of the
  view reads its cells directly, however deep it sits, so nothing is passed
  down through the levels between a writer and a reader.
  [Shared State](@/docs/shared-state.md) covers it.
- A **table** is what a list of records becomes once the user edits its rows.
  Each write names the row it touches, and a *table view* draws the rows a query
  keeps, in the query's order, inside a window.
  [Tables and Table Views](@/docs/tables-and-views.md) covers both.
- **Local state** needs no entry in the store, cannot be reached by code that
  has no business with it, and goes by itself when its piece of the view
  goes. [Local State, Events, and Forms](@/docs/state-and-events.md) covers
  it.

When in doubt, start local. Move a piece of state to the store when a second
part of the app needs it, or when it must outlive the piece of the view that
shows it.

## Signals declare what they read

A *signal* is a read-only value that changes over time. `Signal(ctx, a)` is
a signal of type `a` in the context `ctx`. You get one from local state
(`count.signal()`), from a store cell (`cell.signal()`), from a drawn row
(`row.field(...)`) or from a constant (`Engine.const(...)`), and you build
new ones with `map` and `map2`:

{{ sample(file="state.roc", region="map2") }}

Three or more signals combine with Roc's record builder: a record of signals
followed by `.Engine.Signal` is one signal of the record, and reads what each
field reads. The [Tutorial](@/docs/tutorial.md#adding-a-to-do-one-decision)
reads three cells that way.

A signal carries the set of states and cells it reads, fixed by how it was
built. The engine never runs your code to discover its dependencies. When
something is written, the engine re-evaluates exactly the holes and sites whose
signals read it.

That knowledge is conservative. A signal built from `map2(a, b, ...)` reads both
`a` and `b`, even if your function only looks at `b` when `a` is true. The cost
is an extra evaluation, never a wrong answer.

## Equal values stop the work

Every hole remembers the last value it put on the page. If a re-evaluation
produces an equal value, nothing is emitted and nothing below it runs. The same
holds for a row whose item did not change, a derived value that came out equal,
a conditional whose branch did not change, and an effect whose watched value
did not change.

So a keystroke that changes a name re-evaluates the holes that read the name,
and the page sees one text update. Everything else stays untouched.

Comparison happens where values are small, at the readers. The state itself
is never compared with what it held before: that is the rule above.

## Handlers and turns

A handler says what an event writes. For local state it is a reducer over
that state, attached to an event:

{{ sample(file="counter/Counter.roc", region="view") }}

For the store it is a *decision*: a pure function that returns a list of
writes, one for each cell the event changes. Either way, when the user clicks,
the engine runs one *turn*:

1. It finds the handler from the clicked element, without searching.
2. It runs the handler. A reducer is applied to the state's current value. A
   decision returns its writes, and they are applied to the store in order.
3. It refreshes every hole and site that reads something the event wrote,
   from the outside in, and visits nothing else. A table view looks at
   the rows that were written, not at the table.
4. It returns one batch of DOM commands, which the runtime applies.

All writes of a turn happen before anything observes them, so no text ever
shows a half-updated state. An effect result, such as an HTTP response, enters
the same way: it is one turn, running the reaction you gave the request.

## Contexts

A *context* is a type: what a place in the tree can read. Every signal,
handler and element is typed by its context. The top
of an app is `Root`, or `StoreRoot(_)` for an app with a store. A local state
of type `s` introduces the context `In(outer, s)`, and a drawn row of a list or of
a table view introduces `Row(outer, item)`.

{{ sample(file="state.roc", region="contexts") }}

A value from an outer context is brought inward with `lift` (or `lift_row`
inside a row). Naming contexts with type aliases, as above, keeps annotations
short. Contexts are why a local value can only be read where it exists, and
why the engine can route an event to its state without searching.

The store needs none of this. A cell is read and written in any context with
no `lift`, and a function that uses the store stays generic over its context,
asking only that the context reaches a store:
`where [ctx.store : () -> Engine.Reach(ctx, _)]`.

## Scopes

A conditional's branch, a remounted body and a drawn row of a list or of a table
view are *scopes*: lifetimes that end together. Everything mounted inside one —
its local state, its rows, its timers and subscriptions — lives exactly as long
as the scope. When a branch switches or a row leaves, the engine removes its DOM
nodes, releases its state and cancels its subscriptions, timers and worker jobs.
Requests already in flight that may have an effect worth keeping, such as HTTP
requests, storage reads and the jobs of a task that says so, are not lost: their
results go to the nearest surviving scope. [Conditionals and
Lists](@/docs/dynamic-structure.md) covers identity and lifetime in detail.

The store is not a scope. A cell lives as long as the app and starts again
only when something writes it, so state in the store that should start fresh
is started again on purpose (see
[Shared State](@/docs/shared-state.md#starting-again)).

## Keep separate concerns separate

Because reads are declared per state and per cell, the shape of your state
decides how much work an update does. One big record read by every hole
re-evaluates every hole on every change. Put independently changing concerns
in independent cells or states, hold rows the user edits in a table, compute
expensive values once with `derive`, and keep a row's private state inside
the row. [Structuring an App](@/docs/app-architecture.md) shows the pattern.
