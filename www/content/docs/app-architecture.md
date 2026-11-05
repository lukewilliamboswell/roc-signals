+++
title = "Structuring an App"
description = "Lay out modules, name contexts, keep updates local, and use components to bound code size."
weight = 8
template = "page.html"
+++

# Structuring an App

Two kinds of boundary shape an app. Module boundaries help people find code.
State and scope boundaries decide how much work an update does and how long
things live. This page is about choosing both. [Conduit](@/examples/conduit.md)
is the largest example and worth reading alongside it.

## Modules

Every example follows the same layout:

| File | Contents |
|---|---|
| `<Domain>.roc` | Pure domain types and functions: parsing, validation, reducers. No platform imports, tested with `expect`. |
| `<Name>App.roc` | The UI: context aliases, the view, effect sites and `program`. |
| `main.roc` | The one entry point: `main = <Name>App.program`. Built for `wasm32` it is the browser module; for `x64musl`, the native spec runner. |
| `main-fuzz.roc` | Optional fuzz and soak target for the app, on the repository's fuzz platform. |
| `specs/*.scm` | Specs, run natively and in Chrome. |

Conduit splits its domain further — `Api.roc` (wire formats), `Route.roc`
(URL parsing), `Markdown.roc`, `Format.roc` — but the rule is the same: the
more of the app that is plain Roc data and functions, the less of it depends
on the engine, and the easier it is to test.

## Name your contexts

Annotations get long without names. Give each state layer an alias once, at
the top of the UI module, and use the aliases everywhere:

{{ sample(file="state.roc", region="contexts") }}

A helper that works in any context can stay generic, as the `Html` helpers do:
`stat : Str, Val(ctx, Str) -> Elem(ctx)`.

## Keep updates local

The engine re-evaluates what reads a changed state, so the shape of your state
is the shape of your update cost:

- **Separate concerns, separate states.** A filter box, a selection and the
  data they act on change independently. As fields of one record, every
  keystroke in the filter re-evaluates everything that reads the record. As
  three states, it re-evaluates only what reads the filter.
- **One transition, one state.** Fields that one event must change together
  belong in one state, because a handler writes one state.
- **Compute once with `derive`.** A view that many holes read — the visible
  rows after filtering and sorting, a summary over the whole data set — should
  be a `derive` layer. Its readers do no work when it comes out equal.
- **Row-local state lives in the row.** An "editing" flag per row belongs in
  a `state` inside the row template, not in a map in the root model.
- **Keyed selection for "the selected one".** Use `keyed` and `row.select`, so
  moving the selection touches two rows.

The work counters make this measurable: a spec can assert how many elements,
text updates and evaluations an event caused. See
[Testing](@/docs/testing.md#work-budgets).

## Lifetimes

Ask how long each piece of state must live, and put it in the scope that
lives exactly that long:

- State that survives page changes (the session, a cache keyed by id) lives at
  the root.
- State that should reset when the user leaves a page lives inside that page's
  `switch` branch.
- State per item lives in the row.

When a page needs to keep a draft across navigation, store it above the page,
keyed by the page's own identity; the engine never keeps a disposed scope
alive for you.

## Components and code size

Every distinct context type a piece of UI is used in compiles another copy of
it. A component's body is typed only by its prop and action types, so it
compiles once however many places use it. When the same panel, card or form
appears in several places, or a large app's Wasm grows, make it a component
and pass it what it needs as its prop.
[Lists, Conditionals, and Components](@/docs/dynamic-structure.md#components)
shows the API.

## Effects belong to the state they change

Put an effect site next to the state its reaction writes, and watch the
smallest value that should trigger it. Conduit keeps its routing effects
(popstate, history push, title) at the root, and each page's loads inside the
page, so leaving a page cancels its subscriptions while requests in flight
still deliver to the root. A request that must be repeatable for an equal
value carries a counter in the watched value.
