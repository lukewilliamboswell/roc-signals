+++
title = "Under the Hood"
description = "Follow an event through the runtime, the Wasm host and the engine, and see where work and failures happen."
weight = 20
template = "page.html"
+++

# Under the Hood

You do not need this page to write an app. It explains what happens between a
click and the DOM update, which helps when reading a work assertion, a fault
or a profile. The architecture and its rules are in
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).

## Three pieces

| Piece | File | Job |
|---|---|---|
| Engine | `platform/Core.roc`, with tables and their table views in `TableCore.roc`, `View.roc` and `Seq.roc`; `Engine.roc` is the API apps see | Everything reactive: sites, the store, propagation, lists and table views, effects, identity. Pure Roc. |
| Host | `platform/host/host.zig` | Allocates memory, keeps the engine state between calls, stages one payload, backs the handles of [files](@/docs/files.md) the app holds, classifies faults. In a worker it holds no engine state: it keeps at most one preparation's state between jobs, and during a job performs the task's file effects through the worker script. |
| Runtime | `platform/runtime.mjs` | Applies the engine's commands to the DOM, performs effects, delivers events. |
| Worker script | `platform/worker.mjs` | Runs [worker](@/docs/workers.md) tasks: a Web Worker instantiates the same `app.wasm`, never mounts it, calls its `work` entry (or `prepare` and `ask` for a preparation's task) for each job, and performs the job's file effects. |

Your app and the engine compile together into one `app.wasm`. The engine's
state between events is one opaque value the host holds; the host never looks
inside it. The runtime never decides anything: it does what the commands say.

## Mounting

1. The runtime checks the module's protocol version and refuses a mismatch.
2. It asks for the app's declared storage keys, reads them, and stages the
   boot bytes: the URL, those values, and the online, visibility and storage
   flags.
3. `init()` runs your `program`. The engine starts the store, if the app has
   one, from the boot data; runs the view, once; builds the static structure
   and mounts every site; and returns one batch of commands: create these
   elements, set these attributes, listen for these events, start these
   effects.
4. The runtime applies the batch to the mount root, then performs the effects.

## One event

1. Two delegated listeners per event type sit on the mount root, one
   capturing and one bubbling. A bubbling event walks from the target to
   the nearest handler; an event that does not bubble reaches only a
   handler on its target. The runtime then finds the nearest element with
   a routing node id. A reference inside a row has its own command id,
   while its events still route through the row.
2. The runtime stages the payload (for an `input`, the new text) and calls
   `event(node, handler)`.
3. The engine looks the node up in its routes table — one array index — and
   finds the path of the site that owns the handler, or the list row.
4. The event travels down that path. On the way the root moves the store
   into the environment, and each local state the event passes moves its
   value in. The handler runs there: a reducer is applied to its state; a
   decision takes its reading and returns its writes, which are applied to
   the store in order. The handler answers exactly what it wrote: which
   local states and which cells.
5. The environment travels back up, and each holder takes its value back.
6. What was written is refreshed in one pass, which starts at the outermost
   write: at the root if cells were written, otherwise at the outermost
   local state the event wrote. Each site carries a small signature of
   what it reads: a hole or a child whose signature misses the write is
   skipped with one test, and a command is emitted for each value that did
   change. A local state written below the start joins the pass where the
   pass reaches it, for its own subtree and nothing outside it, so a write
   to one state never visits the readers of a sibling, and a reader of two
   things one event wrote is evaluated once, with both in place and every
   `derive` above it recomputed. A table view reads the table's
   changes from this turn, then its query and its window, and
   changes the rows it draws once, from the window before the event to the
   window after it.
7. The tables the turn wrote are rearmed for their next writing turn without
   changing their recorded changes. Those changes are cleared before that
   next turn's first modifier runs. The reference names
   the turn mounted or renamed are checked for duplicates, focus requests
   are resolved, and the call returns the command batch and the work record. The
   runtime applies the DOM commands in order, then performs any effects.

A signature can only err towards more work. Two cells far apart in a large
store can share a bit of it, and then a write to one also evaluates a reader
of the other, which comes out equal and emits nothing. A reader of something
that changed is never skipped.

An effect result takes the same path: the runtime calls `event` on a reserved
node with the request's id, and the engine runs the reaction as a turn.
Events raised while a batch is being applied are queued and delivered after
it, so the engine is never re-entered.

The queue holds at most 4096 events, and one drain delivers at most 4096
turns before returning to idle. Either overflow stops the instance with
`resource_limit`, including a focus loop that queues only one event at a time.

## The command stream

Commands are bytes in Wasm memory: create an element or text node, set an
attribute or text, move, remove, listen, and the effect commands (start or
cancel an effect, navigate, write storage, set the title, focus). The rows
of a list or of a table view are compiled once per site into a template, so
creating a row is one `INST` command carrying only its holes' values.

The batch becomes visible only when the call returns. If the call traps,
nothing from it is applied.

## Work

Every call also returns cumulative counters: commands by kind, closures
evaluated, rows created, moved, reused and removed, scopes created and
disposed, states and cells written, keys hashed and compared. Specs read them with
`mark-metrics` and `expect-metric-delta`, natively and in Chrome, which is how
"this keystroke updates one text node" becomes a test. The native runner also
checks that the counters agree with the commands it decoded.

## Memory

Each piece of state has one holder. A site's storage is referenced by exactly
one closure, and the root alone holds the store, so Roc updates lists,
records and tables in place rather than copying them. That is also why the
engine never keeps an earlier copy of a state or a cell to compare with: the
copy would be a second holder, and every write would then copy what it
changes. What changed comes from the write. The one earlier state the engine
keeps is a table's changes: one earlier row per distinct key its last writing
turn wrote. Unrelated turns retain them; the next writing turn releases them
before its first modifier runs, or disposal of the holder releases them.
There is no time bound and no earlier whole table is kept. Freeing that record
costs its previous writing turn's recorded keys, even if the next turn writes
only one key; this is delayed cleanup proportional to recorded keys over the
session.

Disposing a site drops its closure, and reference counting frees what it
held. The repository's long-session tests walk every example for thousands
of steps and repeat its round trips, and fail if live allocations or Wasm
pages keep growing.

## When something goes wrong

A broken contract (a duplicate key, say), a `crash` in app code, a failed
`expect` or running out of memory *poisons* the instance. The host records a
class and a diagnostic of up to 512 bytes, and traps. The runtime catches the
trap, reads the diagnostic, reports it through `onFault`, detaches its
listeners and cancels its effects, and keeps the last rendered page on screen.
A poisoned instance never runs again; `recover()` mounts a fresh one. The
classes are listed in the [Reference](@/docs/reference.md#errors). A worker's
instance is poisoned the same way, but only that worker is discarded: its job
answers `WorkLost` with the class, and the page goes on.

## Natively

An app's `main.roc` built for a native target (`x64musl`, `arm64mac`,
`x64mac` or `x64win`) runs the same engine as native code:
the platform's spec runner calls the engine's turn functions directly
and feeds the command bytes to `platform/Dom.roc`, an independent decoder that builds
a model of the DOM. Specs assert against that model. Because it reads only the
command stream, a spec that passes natively has exercised the same protocol
the browser runtime consumes.
