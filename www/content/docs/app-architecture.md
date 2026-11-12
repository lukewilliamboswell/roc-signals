+++
title = "Structuring an App"
description = "Lay out modules, decide where each piece of state lives, name transitions, and keep updates local."
weight = 11
template = "page.html"
+++

# Structuring an App

Two kinds of boundary shape an app. Module boundaries help people find code.
State boundaries decide how much work an update does and how long things
live. This page is about choosing both. [Conduit](@/examples/conduit.md)
is the largest example and worth reading alongside it.

## Modules

| File | Contents |
|---|---|
| `<Domain>.roc` | Pure domain types and functions: parsing, validation, formats. No platform imports, tested with `expect`. |
| `<Component>.roc` | A component: a type, its pure operations, and a view that is handed the cells it uses ([Components](@/docs/components.md)). It may describe the cells it needs. It never imports the store. |
| `AppStore.roc` | The store: its description, its handles, and the transitions that span features, each a function returning its writes, with `expect`s. It imports the components whose types it holds. |
| `<Page>.roc` | A module that composes: it imports the store and the components and hands each its cells. |
| `<Name>App.roc` | The root: the view, the effect sites that belong to the whole app, and `program`. In a small app it is also the store and the only composing module. |
| `main.roc` | The one entry point: `main = <Name>App.program`. Built for `wasm32` it is the browser module; for `x64musl`, `arm64mac`, `x64mac` or `x64win`, the native spec runner. |
| `fuzz-<subject>.roc` | Optional roc-fuzz target of the app's own pure logic, named for what it checks: it imports the domain modules and nothing of the platform ([Testing](@/docs/testing.md#fuzzing-your-own-logic)). |
| `specs/*.scm` | Specs, run natively and in Chrome. |

The imports go one way. Components know nothing of the app. The store knows
the components' types. Pages know both. The more of the app that is plain
Roc data and functions, the less of it depends on the engine, and the easier
it is to test.

## Decide where each piece of state lives

Ask who cares about it and how long it must live:

| The state | Its home |
|---|---|
| More than one part of the app reads or writes it, or it must survive a change of page | A cell of the store ([Shared State](@/docs/shared-state.md)) |
| Rows the user edits by key; anything shown sorted, filtered or long | A table in the store, drawn through a view ([Tables and Views](@/docs/tables-and-views.md)) |
| One piece of the view cares about it, and it should go when that piece goes | Local state ([Local State, Events, and Forms](@/docs/state-and-events.md)) |
| One row on the page cares about it, and it need not survive the row leaving the page | Local state inside the row template |
| It follows from other state | No state at all: a `map`, or a `derive` when it is expensive or widely read |

Start local and promote when a second reader appears. Going the other way is
a mistake that is easy to make: a menu's open flag in the store is a global,
and every state in the store that should start fresh needs a reset someone
must remember.

## Name your transitions

A decision that spans cells is a named function that returns its writes, kept
beside the store with an `expect`. Conduit's `moved` is every write a
navigation makes: the location, the page's models, and the reset of the page
being left. A view then attaches a transition where it happens and decides
nothing itself.

Three habits follow:

- **One transition, one function.** Cells that must agree are written by one
  decision from one reading. Do not split a transition across two handlers
  or two reactions that each write a part.
- **Let features start themselves again.** A feature's description hands out
  its reset, and the transition that leaves the feature includes it. The
  transition names none of the feature's cells.
- **Test the transition, not the click.** `store.after(writes).read(cell)`
  needs no engine. Specs then check that the right button runs it.

## Keep updates local

The engine wakes the readers of what was written, so the shape of your state
is the shape of your update cost:

- **Separate concerns, separate cells.** A filter box, a selection and the
  data they act on change independently. As fields of one record in one
  cell, every keystroke in the filter re-evaluates everything that reads the
  record. As three cells, it re-evaluates only what reads the filter.
- **Rows in a table.** A row's write then wakes that row in each view, not
  every reader of a list.
- **Compute once with `derive`.** A value that many holes read, such as a
  summary over a data set, should be a `derive` layer. Its readers do no
  work when it comes out equal.
- **Row-local state lives in the row.** An "expanded" flag per row belongs
  in a `state` inside the row template, not in the row's record or in a map
  beside it, unless it must survive the row leaving the page.
- **Keyed selection for "the selected one".** In an `each` list, use `keyed`
  and `row.select`, so moving the selection touches two rows.
- **`change` for large values.** A function of the value updates it in
  place. A `put` of a value built from a reading of the same cell copies it.

The work counters make this measurable: a spec can assert how many elements,
text updates and evaluations an event caused. See
[Testing](@/docs/testing.md#work-budgets).

## Lifetimes

Ask how long each piece of state must live, and give it the home that lives
exactly that long:

- State in the store lives as long as the app. It survives page changes
  without any help, and state that should not is started again by the
  transition that leaves its page, with a generated reset.
- Local state inside a page's `switch` branch goes when the reader leaves
  the page.
- Local state under a `remount_on` starts again when the key changes: a
  draft that belongs to the open message.
- Local state in a row goes with the row.

The engine never keeps a disposed scope alive for you, and never starts a
cell again for you.

## Effects belong to the state they change

Put an effect site next to the state its reaction writes, and watch the
smallest value that should trigger it. Conduit keeps its routing effects
(popstate, history push, title) at the root, and each page's loads inside the
page, so leaving a page cancels its subscriptions while requests in flight
still deliver to the root. A reaction that writes cells is a decision
(`Engine.react`), so an answer that arrives after its page has gone still
writes the store as it would have. A request that must be sent again for an
equal value is posted to an outbox
([Effects and the Browser](@/docs/effects-and-browser.md#sending-when-the-user-acts)).

## Code size

A view that is generic over its scope is compiled for each kind of scope it
is drawn under, and a generic helper for each type it is used at. When a
large app's Wasm grows, look for a large view drawn under several different
scopes.
