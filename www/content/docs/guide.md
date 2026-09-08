+++
title = "Guide"
description = "Learn the model, build an app, or find help with a specific task."
weight = 1
template = "page.html"
+++

# Roc Signals

Roc Signals is a Roc platform for building interactive browser interfaces.
You describe elements, state, and the computations that connect them. The
runtime stores the current values and updates the affected parts of the page
when an event changes state.

You can use ordinary HTML and CSS, including your existing stylesheets. The
examples on this site use Tailwind classes, but the platform does not require
Tailwind or a component library.

## Start here

If you want to run an app first, follow [Getting Started](@/docs/getting-started.md).
It covers the compiler, platform, native tests, and browser setup.

If signals are new to you, [Thinking in Signals](@/docs/thinking-in-signals.md)
explains how state and derived values fit together. It introduces the terms used
throughout these guides; experience with another UI framework is not required.

The [Tutorial](@/docs/tutorial.md) builds a reading list with inputs, filtering,
keyed rows, and tests. Use it when you want to see those pieces in one app.
The code assumes some familiarity with Roc functions, records, and tag unions;
the [Roc tutorial](https://www.roc-lang.org/tutorial) covers the language itself.

## A small example

Inside a checkout of this repository, save this as `examples/hello/main.roc`:

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

            Html.section(
                "Counter",
                [],
                [
                    Html.paragraph_s_attrs(label, [Html.test_id("count")]),
                    Html.button("Increment", count.on_unit(|n| n + 1)),
                ],
            )
        },
    )
```

`Ui.state` declares a state value starting at zero. `count.signal()` refers to
its current value, and `map` describes how to turn that value into display text.
The button's reducer, `|n| n + 1`, computes the next count.

On a click, the runtime calls the reducer, evaluates the dependent text
transform, and updates the paragraph. It does not call `main` again. If a
recomputed value compares equal to its previous value, propagation stops at
that edge. New conditional branches and list rows can still call builders to
create their UI when they become live.

[Getting Started](@/docs/getting-started.md) has the commands to check, test,
and run this kind of app. A standalone app can use a released platform archive
instead of the checkout-relative path shown here.

## Find a topic

| I want to… | Read |
| --- | --- |
| Handle input, validate a form, or coordinate state changes | [State, Events, and Forms](@/docs/state-and-events.md) |
| Render lists, choose branches, or reuse a component | [Lists, Conditionals, and Components](@/docs/dynamic-structure.md) |
| Make HTTP requests, use timers, navigate, or store a draft | [Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) |
| Split an app into modules and decide where state belongs | [Structuring an App](@/docs/app-architecture.md) |
| Test interactions, task results, cleanup, and update work | [Testing](@/docs/testing.md) |
| Understand runtime ownership and update costs | [Under the Hood](@/docs/under-the-hood.md) |
| Look up a function or supported browser feature | [Reference](@/docs/reference.md) |
| Change or test the platform itself | [Contributing](@/docs/contributing.md) |

The [examples](@/examples/_index.md) include browser apps, Roc source, and native
specs. Pick one with a similar problem to yours: a form, a routed app, an editor,
or a table.

## Before choosing it for a project

Roc Signals and Roc are still evolving. Use the compiler version named by your
platform release, keep the browser runtime and platform compatible, and read the
[release notes](https://github.com/lukewilliamboswell/roc-signals/releases)
when upgrading.

The platform runs on the client. It does not provide server rendering or
hydration. Routing is application code over `Browser.location()`. HTML and SVG
are supported, while some browser capabilities require a JavaScript behaviour
or are unavailable through the current API. Check the
[browser limits](@/docs/reference.md#deliberately-absent) before depending on one.

Native specs exercise the same reactive engine as the browser build. They are
useful for state, ordering, and lifecycle tests, but they do not establish CSS
layout, real keyboard behaviour, or accessibility in a browser. Test those
interactions in a browser as well.
