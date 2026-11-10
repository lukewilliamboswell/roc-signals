+++
title = "Under the Hood"
description = "Follow an event through the runtime, the Wasm host and the engine, and see where work and failures happen."
weight = 14
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
| Engine | `platform/Engine.roc` | Everything reactive: sites, propagation, lists, effects, identity. Pure Roc. |
| Host | `platform/host/host.zig` | Allocates memory, keeps the engine state between calls, stages one payload, classifies faults. |
| Runtime | `platform/runtime.mjs` | Applies the engine's commands to the DOM, performs effects, delivers events. |
| Worker script | `platform/worker.mjs` | Runs [worker](@/docs/workers.md) programs: a Web Worker instantiates the same `app.wasm`, never mounts it, and calls its `work` entry for each job. |

Your app and the engine compile together into one `app.wasm`. The engine's
state between events is one opaque value the host holds; the host never looks
inside it. The runtime never decides anything: it does what the commands say.

## Mounting

1. The runtime checks the module's protocol version and refuses a mismatch.
2. It asks for the app's declared storage keys, reads them, and stages the
   boot bytes: the URL, those values, and the online, visibility and storage
   flags.
3. `init()` runs your `program`. The engine builds the static structure, mounts
   every site, and returns one batch of commands: create these elements, set
   these attributes, listen for these events, start these effects.
4. The runtime applies the batch to the mount root, then performs the effects.

## One event

1. One delegated listener per event type sits on the mount root. A click walks
   up from the target to the nearest element with a click handler, then to the
   nearest element with an engine node id.
2. The runtime stages the payload (for an `input`, the new text) and calls
   `event(node, handler)`.
3. The engine looks the node up in its routes table — one array index — and
   finds the path of the site that owns the handler, or the list row.
4. The handler runs and writes its state. Then one pass refreshes exactly the
   holes and sites that read the written state, descending only into children
   that read it, and emits a command for each value that changed.
5. The call returns the command batch and the work record. The runtime applies
   the DOM commands in order, then performs any effects.

An effect result takes the same path: the runtime calls `event` on a reserved
node with the request's id, and the engine runs the reaction as a turn.
Events raised while a batch is being applied are queued and delivered after
it, so the engine is never re-entered.

## The command stream

Commands are bytes in Wasm memory: create an element or text node, set an
attribute or text, move, remove, listen, and the effect commands (start or
cancel an effect, navigate, write storage, set the title, focus). List rows
are compiled once per list into a template, so creating a row is one `INST`
command carrying only its holes' values.

The batch becomes visible only when the call returns. If the call traps,
nothing from it is applied.

## Work

Every call also returns cumulative counters: commands by kind, closures
evaluated, rows created, moved, reused and removed, scopes created and
disposed, states written, keys hashed and compared. Specs read them with
`mark-metrics` and `expect-metric-delta`, natively and in Chrome, which is how
"this keystroke updates one text node" becomes a test. The native runner also
checks that the counters agree with the commands it decoded.

## Memory

Each site's storage is referenced by exactly one closure, so Roc updates lists
and records in place rather than copying them. Disposing a site drops its
closure, and reference counting frees what it held. The soak runs repeat a
round trip thousands of times and fail if live allocations or Wasm pages keep
growing.

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

An app's `main.roc` built for `x64musl` runs the same engine as native code:
the platform's spec runner calls the engine's transaction functions directly
and feeds the command bytes to `platform/Dom.roc`, an independent decoder that builds
a model of the DOM. Specs assert against that model. Because it reads only the
command stream, a spec that passes natively has exercised the same protocol
the browser runtime consumes.
