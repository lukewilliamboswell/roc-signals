+++
title = "Guide"
description = "What Roc Signals is, and where to start reading."
weight = 1
template = "page.html"
+++

# Roc Signals

Roc Signals is a Roc platform for interactive browser applications. You write
the whole UI in pure Roc: elements, the state they read, the decisions that
change it, and the effects it asks for. The platform compiles your app and its
reactive engine to WebAssembly. A small JavaScript runtime applies the DOM
commands the engine emits and performs the effects it requests.

There is no virtual DOM. Your view runs once, when the app starts. After
that, when an event writes a piece of state, the engine re-evaluates only the
text, attributes and structure that read that state, and skips any value that
comes out equal to what is already on the page. That holds for a list too: an
edit to one row of a long table touches that row.

State has three homes. What the whole app shares is in a store, read from any
depth of the view. Rows the user edits are in a table, drawn through a sorted,
filtered window. What one piece of the view cares about is local to it. Shared
state is changed by *decisions*: pure functions that return what they write,
which you test as functions.

What a user sees and does is tested without a browser too. Specs written in a
small `.scm` language run natively against the same engine in milliseconds,
and the same specs replay in headless Chrome.

Use ordinary HTML and CSS. The examples on this site use Tailwind classes, but
the platform does not depend on any CSS framework.

## Where to start

- **[Getting Started](@/docs/getting-started.md)** creates a counter with
  `signals.roc`, runs it in a browser, tests it and builds it for deployment.
- **[Thinking in Signals](@/docs/thinking-in-signals.md)** explains the model:
  what runs when, where state lives, and what a write wakes. Read it before
  the topic guides.
- **[Tutorial](@/docs/tutorial.md)** builds a to-do list on a store, a table
  and a view of it, with local storage, and tests it.

## Building an app

Read these in order; each builds on the one before.

- [Local State, Events, and Forms](@/docs/state-and-events.md): state that
  belongs to one piece of the view, handlers, controlled inputs, derived
  values, and starting state again.
- [Shared State](@/docs/shared-state.md): the store and its cells, writes as
  values, decisions and how to test them, and resets.
- [Tables and Views](@/docs/tables-and-views.md): rows held by key, and a
  sorted, filtered window of them that follows each write.
- [Conditionals and Lists](@/docs/dynamic-structure.md): `when`, `switch`,
  `each`, row identity and lifetimes.
- [Components](@/docs/components.md): a type, its operations and a view that
  is handed the cells it uses.
- [Effects and the Browser](@/docs/effects-and-browser.md): HTTP, storage,
  timers, navigation, focus and cleanup.
- [Structuring an App](@/docs/app-architecture.md): modules, where each piece
  of state goes, and keeping updates local.

## Beyond the page

- [Workers](@/docs/workers.md): running a task off the page's thread, from
  a slow pure calculation to a job that reads and builds files, and
  preparations several tasks share.
- [Files](@/docs/files.md): taking a file the user chooses, drops or pastes
  as a handle, acting on it where the browser keeps it, and reading it in a
  worker.
- [Files in Tasks](@/docs/files-in-tasks.md): what a task's job does with
  files: reading a chunk at a time, building new files, appending across
  jobs, downloading into a file, and saving.
- [Monitoring Workers](@/docs/worker-monitoring.md): where a worker job's time
  goes, how busy the pool is, and what workers cost.
- [Ports](@/docs/ports.md): reaching a browser service the platform does not
  model, through typed messages to JavaScript your page supplies.

## Testing and reference

- [Testing](@/docs/testing.md): decisions tested as functions, the spec
  language and its two runners, with every step for effects, workers, files
  and ports.
- [Reference](@/docs/reference.md): the API at a glance and the platform's
  limits.
- [Under the Hood](@/docs/under-the-hood.md): how an event becomes DOM commands.
- [Contributing](@/docs/contributing.md): working on the platform itself.

The [examples](@/examples/_index.md) are complete apps, each with its specs.
The code assumes you know Roc functions, records and tag unions; the
[Roc tutorial](https://www.roc-lang.org/tutorial) covers the language.
