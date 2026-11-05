+++
title = "Guide"
description = "What Roc Signals is, and where to start reading."
weight = 1
template = "page.html"
+++

# Roc Signals

Roc Signals is a Roc platform for interactive browser applications. You write
the whole UI in pure Roc: elements, the state they read, the handlers that
change it, and the effects it asks for. The platform compiles your app and its
reactive engine to WebAssembly. A small JavaScript runtime applies the DOM
commands the engine emits and performs the effects it requests.

There is no virtual DOM. When an event changes a piece of state, the engine
re-evaluates only the text, attributes and structure that read that state, and
skips any value that comes out equal to what is already on the page.

Every behaviour you care about can be tested without a browser. Specs written
in a small `.scm` language run natively against the same engine in
milliseconds, and the same specs replay in headless Chrome.

Use ordinary HTML and CSS. The examples on this site use Tailwind classes, but
the platform does not depend on any CSS framework.

## Where to start

- **[Getting Started](@/docs/getting-started.md)** sets up the tools, builds a
  counter, tests it and runs it in a browser.
- **[Thinking in Signals](@/docs/thinking-in-signals.md)** explains the model:
  sites, values, layers and turns. Read it before the topic guides.
- **[Tutorial](@/docs/tutorial.md)** builds a todo list with a keyed list, a
  form and local storage, and tests it.

## Topic guides

- [State, Events, and Forms](@/docs/state-and-events.md): state, handlers,
  controlled inputs, derived values.
- [Lists, Conditionals, and Components](@/docs/dynamic-structure.md): `when`,
  `switch`, `each`, row identity and components.
- [Effects and the Browser](@/docs/effects-and-browser.md): HTTP, storage,
  timers, navigation, focus and cleanup.
- [Structuring an App](@/docs/app-architecture.md): modules, context types and
  keeping updates local.
- [Testing](@/docs/testing.md): the spec language and its two runners.
- [Reference](@/docs/reference.md): the API at a glance and the platform's
  limits.
- [Under the Hood](@/docs/under-the-hood.md): how an event becomes DOM commands.
- [Contributing](@/docs/contributing.md): working on the platform itself.

The [examples](@/examples/_index.md) are complete apps, each with its specs.
The code assumes you know Roc functions, records and tag unions; the
[Roc tutorial](https://www.roc-lang.org/tutorial) covers the language.
