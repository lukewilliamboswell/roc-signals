+++
title = "Under the Hood"
description = "What crosses the WebAssembly boundary, why type mismatches are structurally impossible, and the performance model that follows."
weight = 10
template = "page.html"
+++

# Under the Hood

You do not need this page to build apps. You need it to reason about
performance, to debug something strange, or to decide whether to trust the
thing.

## Three layers

```text
        App (Roc)                pure. returns one Elem descriptor tree.
            │                    no mutation, no reads of live state.
            ▼
        Engine (Zig)             node table, topological scheduler, dirty set,
            │                    is_eq cutoff, scope forest, keyed-row diff.
            │                    all reactive and structural logic lives here.
      ┌─────┴─────┐
      ▼           ▼
 Native host   Wasm host         thin boundaries only.
 simulated     command buffer    no reactive logic in either.
 DOM, specs    + JS runtime
```

The engine is **host-agnostic** and shared. The two hosts differ only in where
output goes: the native host writes into a simulated DOM and runs your spec; the
wasm host serializes a command buffer into linear memory for JavaScript to
apply.

This is why a native spec is meaningful evidence about browser behaviour. It is
not a reimplementation — it is the same engine with a different sink.

## Startup

1. The host calls `roc_ui_init` **once**. Your `main()` runs and returns a boxed
   `Elem` tree.
2. That tree contains markup, signal expressions, retained Roc closures
   (transforms, reducers, equality checks, row builders, cleanup thunks), and
   effect descriptors.
3. The host walks the tree, minting node ids and scope ids by construction-order
   position. This is where identity comes from.
4. Browser environment sources — location, visibility, online, declared storage
   keys — are seeded **before** the first render, so deep links and restored
   sessions render correctly on the first frame.
5. The engine evaluates the graph and emits an initial command batch.

Your app code never runs again as a whole. Only the retained closures do.

## An event, step by step

A click on a button bound with `count.on_unit(|n| n + 1)`:

1. JavaScript's delegated listener encodes the event and calls into wasm.
2. The host looks up the binding, reads the current state cell, and calls the
   retained reducer closure. Roc returns a new value.
3. If the new value differs by `is_eq`, the source node is marked dirty.
4. The scheduler walks dependents in topological rank order, calling each
   retained transform. Any node whose recomputed value is `is_eq` to its
   previous value **stops propagating** — its dependents are never woken.
5. Sinks whose inputs changed emit patches.
6. Structural changes (`Ui.when` flips, `Ui.each_str` diffs) splice the active
   stream locally, disposing and mounting scopes, rather than rebuilding the
   tree.
7. The command buffer is written and JavaScript applies it.

There is no full-tree walk anywhere in that list. Work is a function of the
dirty set.

## The wire protocol

The only thing crossing the boundary is a versioned command buffer. It is
small and boring, which is the point:

```json
{"name":"reading-list","commandBatches":2,"commands":61,
 "fixedRecordBytes":1464,"fixedStringBytes":120,"dynamicBytes":764,
 "opCounts":{"reset_dom":1,"create_element":10,"append_child":13,
             "create_text":3,"set_text":5,"set_attr_text":19,
             "set_value":1,"set_checked":3,"bind_event":1,
             "bind_input":1,"bind_click":1,"bind_check":3}}
```

That is the [tutorial](@/docs/tutorial.md) app's entire startup: 61 commands and
about 2.3 KB. You can print this for any app:

```sh
node scripts/browser/mount_wasm_example.mjs app.wasm my-app --telemetry-summary
```

Commands cover creating, moving, and removing nodes; setting text, value, class,
and attributes; setting `checked` and `disabled`; binding and clearing events;
starting and cancelling tasks and intervals; and applying dynamic attributes.

**JavaScript never reconstructs meaning.** It does not diff, does not hold
reactive state, and does not decide what to patch. It executes an already-decided
list. That constraint is what keeps the two hosts from diverging.

## Why type mismatches are impossible

The host stores Roc values but must not know their layouts. The usual solution
is to erase to a tagged union and decode on read, which means a decode can
disagree with the write and crash.

Roc Signals uses **capabilities** instead. Every edge carries a bundle of
operations — clone, equality, drop, and typed read — generated at that edge's
monomorphized type. The host holds an opaque cell and a capability; the only
code that can read the cell is the code generated for the exact type that wrote
it.

So there is no host-authored read site that could disagree with a writer, and no
runtime type tag to get wrong. A `Signal(Article)` cannot be read as a
`Signal(Str)`, because no operation exists that could do it.

## Mount lifecycle

One mount owns one WebAssembly instance. `mountSignalsApp` creates a fresh
instance each time; the wasm host keeps engine state module-global inside it.
For several independent roots on a page, instantiate once per root — do not
share an instance.

`runtime.unmount()` disposes every scope, cancels tasks and intervals, removes
event listeners and behaviours, and releases DOM ids.

At mount the runtime checks a **wire protocol version and feature set** against
the wasm module. A mismatch fails immediately with
`Signals wire protocol version mismatch` rather than misbehaving subtly. Ship
`signals.mjs` and your `.wasm` from the same platform build.

## Payload sizes

Measured with `--opt=size`. Every app also ships `signals.mjs`, the JavaScript
runtime — 105 KB raw, **20 KB gzipped**, unminified — so the delivered total is
the wasm plus that:

| App | Lines of Roc | wasm | gzipped | + runtime = delivered (gz) |
| --- | --- | --- | --- | --- |
| Hello world (counter) | 24 | 283 KB | 100 KB | ~120 KB |
| Reading list (tutorial) | 125 | 317 KB | 110 KB | ~130 KB |
| Conduit (full RealWorld) | 3,864 | 1.73 MB | 485 KB | ~505 KB |

The floor is a few hundred KB — that is the Roc runtime and the host, paid once.
Growth after that is roughly proportional to your code: a 160× increase in
source produced a 4.8× increase in gzipped payload.

This is a real trade-off and worth stating plainly. Roc Signals is not the right
choice for a tiny widget on a marketing page where 120 KB of baseline matters.
For a whole application it is more defensible — but we have not benchmarked
Conduit against other RealWorld implementations, so treat any comparison to
mainstream frameworks as unmeasured.

`--opt=dev` roughly halves build time (Conduit: ~16 s versus ~32 s) at a large
cost in size — Conduit's dev wasm is **10.3 MB**, 3.5 MB gzipped. Use it while
iterating locally; never ship it.

## The performance model

**What scales with change, not size:** derived recomputation, DOM patches, event
dispatch, keyed-row updates. This is the guarantee the architecture exists to
provide, and native specs let you assert it —
[work budgets](@/docs/testing.md#work-budgets).

**What does not:** the initial mount walks your whole tree once, and payload
size scales with code size.

**The eager-edge caveat.** Declared edges are always live. A derived node with
three inputs wakes when any of them changes, even if the transform ignores the
one that changed. `is_eq` then suppresses the *output*, so no DOM work happens —
but the transform ran.

The practical guidance that follows:

- Keep transforms cheap. They can be woken by inputs they ignore.
- Give custom types a meaningful `is_eq`. That is the brake.
- Derive fine-grained signals rather than one giant view-model, so unrelated
  panels stay quiet.
- When dependency *structure* genuinely varies, use a scope (`Ui.when`,
  `Ui.each_str`) rather than a wide always-live edge.

## Debugging, honestly

This is the weakest part of the platform today, and you should know its shape
before you rely on it.

**Roc-level diagnostics do not reach the browser.** In the wasm host,
`roc_dbg` and `roc_expect_failed` are empty functions, and `roc_crashed`
discards its message. A `crash "cart total went negative"` in your Roc code
surfaces as a generic host-failure string, not your message. `dbg` prints
nothing.

**Wasm builds carry no symbols.** There is no name section and no DWARF, so a
trap gives you `wasm-function[8412]` and an offset.

**`onError` is narrow.** It fires for async task-resolution failures. The DOM
event path does not route through it, and there is no error boundary or
recovery — an app that traps mid-batch can leave the DOM partly patched.

What actually works today:

- **The native host is the debugger.** It is a real native binary, so `lldb`,
  allocation tracing, and ordinary tooling work on it, and `crash` messages and
  `dbg` behave normally. Reproduce the bug in a spec and debug it there. This is
  genuinely good, and it is the intended workflow.
- **Telemetry** (below) shows the command stream, task lifecycle, and work
  counters in the browser.
- **Work-budget assertions** catch performance regressions before they ship.

If you need production error reporting from the browser today, you will have to
add it. Weigh that before committing.

## Telemetry

Pass `telemetry` to `mountSignalsApp` to observe the runtime live. It reports
command batches with byte counts, decode counts, task lifecycle events
(`start_task`, `task_resolution`, `cancel_task`,
`ignored_task_resolution`, `unknown_task_resolution`), and interval activity.

`ignored_task_resolution` is the useful one when debugging async: it means a
result arrived for a request that had already been superseded, and the runtime
correctly discarded it.

## Design constraints

The rules the implementation holds itself to, which explain most of its shape:

1. **No compiler changes.** Everything is ordinary Roc plus a Zig host.
2. **No guessing.** The host never scans to rediscover identity, never infers
   what changed, never reconstructs missing information. It consumes explicit
   data.
3. **Work scales with the changed set** — including the data structures.
   Identity resolution and dependency maintenance are O(1) or O(changed), never
   O(total).
4. **Mutation lives only in the host.** Roc stays pure.
5. **Type-mismatch crashes are structurally impossible.**
6. **One engine, two thin hosts.** Reactive logic in a host file is a defect.

Full detail is in
[`design.md`](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).

## Next

[Reference](@/docs/reference.md) — the complete API surface.
