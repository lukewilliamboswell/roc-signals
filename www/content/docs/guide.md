+++
title = "Guide"
description = "What Roc Signals is, the one idea behind it, and the order to read these docs in."
weight = 1
template = "page.html"
+++

# Roc Signals

Roc Signals is a **Roc platform for building browser interfaces**. You write an
app as a pure Roc function that returns a description of your UI. A host — Zig
compiled to WebAssembly, plus a small JavaScript runtime — keeps that
description alive, owns the mutable state, and patches the DOM.

This is a complete, working app:

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = ||
    Ui.state(
        0.I64,
        |count| {
            label = count.signal().map(|n| "Count: ${n.to_str()}")

            Html.section_c(
                "Counter",
                "grid gap-3",
                [
                    Html.paragraph_s(label),
                    Html.button("Increment", count.on_unit(|n| n + 1)),
                ],
            )
        },
    )
```

Click the button and the text updates. Nothing is re-run or diffed — the host
changes one text node, because that text node is the only thing in the app that
depends on `count`.

## The one idea

Most UI frameworks answer "what changed?" by **re-running your code and
comparing the result**. React calls your component again and diffs the returned
tree. Elm rebuilds the whole view and diffs. The work is proportional to the
size of what you re-rendered, and you spend real effort (`useMemo`, `React.memo`,
`shouldComponentUpdate`) narrowing that down.

Roc Signals answers "what changed?" by **knowing in advance**. Your app runs
once, and what it returns is not markup — it's a *graph*. `count` is a node.
`label` is a node with an edge from `count`. The paragraph's text is a node with
an edge from `label`. When `count` changes, the host walks exactly those edges
and touches exactly that text node. Work scales with what changed, not with how
big your app is.

That single difference is what the rest of these docs unpack. If you have never
used a signals-based framework — or you have used one and want to know why this
one looks different — read
[Thinking in Signals](@/docs/thinking-in-signals.md) first. It is the page that
makes everything else make sense.

## What you get

- **Fine-grained updates.** No virtual DOM, no diffing, no memoization API. A
  value change never re-runs your code beyond the one transform that depends on
  it. Structure that appears and disappears is still built and torn down — that
  is the only rebuilding there is, and it is bounded to the region that changed.
- **A real type system.** Roc is pure and statically typed with no `null` and no
  exceptions. A `Signal(Article)` cannot silently become a `Signal(Str)`.
- **Tests without a browser.** The same app compiles to a native binary that
  runs browser-style specs against roles, labels, and visible text — in
  milliseconds, deterministically, including async and timers.
- **A small, honest API.** Six modules, under 200 functions, and most of those
  are `Html` helpers. You can read the whole platform in an afternoon — it is
  about 2,400 lines of Roc.

## What this is not

Being straight about the boundaries, because they matter more than the pitch:

- **This is a young experiment, not a 1.0.** The project is weeks old, has
  essentially one author, and has no production users. There is no stability
  policy — the working assumption is that when evidence shows a better shape,
  the platform changes wholesale rather than accreting compatibility layers.
  Roc itself is pre-1.0 and its syntax still moves.
- **Browser debugging is thin.** Roc `crash` messages and `dbg` do not currently
  reach the browser, and wasm builds carry no symbols. The native test host is
  where debugging actually happens. See
  [Under the Hood](@/docs/under-the-hood.md#debugging-honestly).
- **There is no router, no SSR, no hydration, and no i18n.** Routing is app
  code over a `Browser.location()` signal — nine routes with deep links and
  guards costs Conduit about 270 lines in
  [`Route.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples/conduit/Route.roc).
- **There is no component library and no CSS-in-Roc.** Examples use Tailwind
  utility classes as plain strings.
- **The browser surface is deliberately narrow.** A defined list of events,
  form controls, storage, history, and `fetch` — not the whole DOM. No
  programmatic focus, no scroll control, no clock, no SVG, no file input, no
  WebSocket. The full list is
  [Deliberately absent](@/docs/reference.md#deliberately-absent) — read it
  before you plan around something.
- **JSON escape sequences are not supported yet.** Roc's builtin parser rejects
  `\n`, `\"`, and `\uXXXX` inside strings, which matters for any API with
  free-text fields.
- **One app instance per mount.** A page can host several, but each needs its
  own WebAssembly instance.
- **No editor tooling story.** No LSP, autocomplete, or formatter guidance
  today.

## Read in this order

**Learn the model**

1. [Thinking in Signals](@/docs/thinking-in-signals.md) — what a signal is, why
   this replaces re-rendering, and how it maps to React, Solid, Svelte, Vue, and
   Elm. Start here.
2. [Getting Started](@/docs/getting-started.md) — install, build, run in a
   browser, and run your first native test.
3. [Tutorial](@/docs/tutorial.md) — build a small app end to end, one concept at
   a time, finishing with a passing test.

**Build things**

4. [State, Events, and Forms](@/docs/state-and-events.md) — local state,
   reducers, every input control, validation.
5. [Lists, Conditionals, and Components](@/docs/dynamic-structure.md) — dynamic
   structure, keys, row-local state, reuse.
6. [Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) — tasks,
   `fetch`, timers, history, storage, cleanup.
7. [Structuring a Real App](@/docs/app-architecture.md) — how Conduit, a
   4,000-line RealWorld implementation, is organized.
8. [Testing](@/docs/testing.md) — the spec language, async control, and work
   budgets.

**Go deeper**

9. [Under the Hood](@/docs/under-the-hood.md) — what actually crosses the
   WebAssembly boundary, and the performance model that follows from it.
10. [Reference](@/docs/reference.md) — the complete API surface in tables.
11. [Contributing](@/docs/contributing.md) — for changing the platform itself.

## See it running

Every [example](@/examples/_index.md) on this site is a real WebAssembly build of
the Roc source linked beside it, with its native test spec. The largest,
[Conduit](@/examples/conduit.md), is a full
[RealWorld](https://docs.realworld.show/) implementation — feeds, auth,
profiles, markdown articles, comments, favorites, and follows — in about 4,000
lines of Roc.
