+++
title = "Under the Hood"
description = "Follow an update through the shared engine and browser runtime, and understand where work and failures occur."
weight = 10
template = "page.html"
+++

# Under the Hood

A Signals app describes its dependencies and UI in Roc. A shared Zig engine
holds the current values, runs affected computations, and decides which render
commands to emit. This page explains that path so you can investigate unexpected
updates, understand scope lifetimes, and measure application cost.

## Three layers

```text
Roc application and platform
    descriptor tree, typed values, retained callbacks
                  |
             Zig engine
    dependency graph, scheduling, scopes, rendering decisions
             /       \
    Native host          Wasm host
    simulated DOM        command buffers
    specs and metrics         |
                         JavaScript runtime
                         browser DOM and APIs
```

Both hosts use the same engine. Native specs can therefore check propagation,
row identity, command semantics, and cleanup without a browser. JavaScript
executes the Wasm host's commands and forwards browser inputs; it does not
recompute the dependency graph or diff application state.

The hosts still have different boundaries. Native tests cannot establish actual
layout, input composition, focus, accessibility, or network behavior. Those need
browser tests.

## Startup

1. The host calls `roc_ui_init`, which runs the application's `main` once and
   returns its element description.
2. The engine ingests element and signal descriptors, retaining the callbacks
   it needs for reducers, transforms, structure, and effects.
3. It assigns runtime identities, records scope ownership, and builds the
   dependency graph. Cloned signal descriptors refer to the same signal;
   distinct construction sites and scoped list keys establish structural identity.
4. The browser supplies declared environment values, including location and
   storage, before the first render.
5. The engine evaluates the initial graph and publishes render commands.

Later events do not call `main` again. The engine calls retained reducers and
transforms. When a branch becomes active or a new row appears, it calls the
corresponding structure builder to obtain that subtree.

## An event, step by step

For a button bound to `count.update(|n| n + 1)`:

1. The browser runtime forwards the bound event ID and declared payload to Wasm.
2. The engine calls the reducer with the current count.
3. It compares the proposed count with the cached value using `is_eq`. An equal
   result needs no downstream value update.
4. For an unequal result, it schedules dependents in dependency order. Each
   transform reads settled inputs. If its result compares equal, propagation
   stops on that edge.
5. Affected text and attribute sinks prepare patches. Structural sinks may
   select a branch or reconcile rows, creating and disposing the relevant scopes.
6. After preparation succeeds, the host publishes the complete command batch
   for JavaScript to apply.

Dependency order matters for a diamond: if two values depend on the count and a
third depends on both, the third runs after both inputs settle. It does not
observe one updated input alongside one old input.

An equality cutoff applies to an edge. A downstream node can still run if
another input changed. Likewise, a small dirty set does not make an expensive
Roc transform cheap: scanning a large list inside one callback still scans that
list.

## How keyed collection generations cross the boundary

`Ui.each` retains an immutable `Rows(item)` generation. Roc owns its typed items,
key function, cached exact keys, and edit history from its immediate parent.
The host accesses it through app-compiled operations and bounded output buffers;
it does not inspect the Roc collection's memory layout.

There are two reconciliation paths:

- If the candidate describes an edit from the site's current generation, the
  engine consumes that delta and addresses affected rows through stable slots.
- At initial mount, for an explicit snapshot, or when the candidate's parent
  differs from the current generation, it consumes a full keyed snapshot.

The snapshot path examines the collection. Rebuilding `Rows` from a list on
every update therefore has a different cost from applying a small edit to the
current `Rows` value. Exact keys preserve surviving row scopes in either path;
key equality and generation lineage serve different purposes.

A same-key item update uses the row's ordinary graph source. `row.signal()` and
`row.map(...)` observe that source, with the same dependency ordering and equality
pruning as other signals. A surviving row does not need its builder called
again. Removing a row disposes its scope; reinserting its key later starts a
new lifetime.

Preparation keeps candidate values, keys, item clones, structural changes, and
commands provisional until validation and fallible host allocation succeed.
Commit publishes the generation without allocating. Failure inside a Roc
callback has a different containment boundary, described below.

## The wire protocol

The browser boundary carries command records, text and payload bytes, and
integer IDs. Commands include element creation, text and attribute changes, row
moves, removal, event bindings, and effect requests. JavaScript never decodes
Roc records, lists, or tag unions to recover application meaning.

The runtime checks the protocol version and required features before mounting.
Deploy the application Wasm and browser runtime from the same compatible
platform release. See the [contributing guide](@/docs/contributing.md#bundles)
for artifact validation and the release notes for version-specific migrations.

Wasm allocation may grow linear memory and invalidate JavaScript views. The
runtime refreshes those views before reading host output. Commands become
available as a complete published batch; reentrant browser inputs are deferred
while the batch is being applied.

Removing a subtree releases browser node registrations and listeners as well
as detaching its root. A compact removal command does not mean disposal takes
constant time: every resource owned by the retired subtree still needs cleanup.

<span id="why-type-mismatches-are-impossible"></span>

## Typed values in a shared host

An application can use `Signal(Article)` and `Signal(Str)` in the same tree.
The host needs to retain both values without knowing either layout. Each
retained value is paired with its owning *capability*: app-compiled operations
for cloning, comparing, and dropping that exact type. Readers and reducers carry
the capability that authorizes their typed access.

This removes independent host-written decoders that could disagree with a
writer. It does not remove the need to validate routing: the host checks that a
value reaches its owning capability and that its handle is still live before
calling typed code. These checks remain enabled in production.

A read produces an independently owned value while leaving an independently
owned value in the source cell. Dropping either must not invalidate the other.
Nested strings, lists, and closures are released through typed operations;
the host does not copy their bytes or adjust their internal reference counts.

## Mount lifecycle

One mount owns one WebAssembly instance. `mountSignalsApp` creates a fresh
instance for its root. For several independent roots on one page, call it once
per root; do not share an instance between active mounts.

`runtime.unmount()` disposes scopes and releases their state, retained callbacks,
tasks, intervals, event listeners, behaviors, and DOM registrations. Removing a
branch or row performs the corresponding cleanup for that scope. State owned by
an ancestor survives; passing its signal into a child does not transfer ownership.

## Payload sizes

Measure the artifacts you intend to deploy. The download includes application
Wasm and the JavaScript runtime, and its size depends on the compiler, platform
version, optimization mode, and application code. A source line count is not a
reliable estimate of any of those costs.

Use the production build described in
[contributing](@/docs/contributing.md#static-site). Measure raw and compressed
sizes together, and record the toolchain and build flags with the result. Avoid
using development artifacts to estimate production cost.

## The performance model

Declared dependencies determine which computations may run. Equality determines
where propagation can stop. Scope changes determine which structure must be
created, moved, or released.

This leads to a few practical checks:

- Keep independently changing inputs separate until a consumer needs both.
- Make `is_eq` account for every field downstream code can observe. Ignoring an
  observed field can suppress a required update.
- Use `Signal.select` for keyed selection so changing the selected key need not
  recompute every member.
- Use incremental `Rows` edits for local collection changes. Account for full
  snapshot work when rebuilding or replacing a collection.
- Measure transforms and equality functions as well as engine bookkeeping.
  Filtering, sorting, and whole-collection aggregates have their own costs.

Initial mount processes the initial graph and tree. Creating or removing a large
subtree also costs work proportional to that subtree. Updates can be local
without startup, bulk replacement, or disposal being cheap.

Native [work budgets](@/docs/testing.md#work-budgets) let you pin row creation,
removal, graph work, and derived callback counts. Browser measurements add
command decoding, DOM work, layout, and painting. Use both when investigating a
slow interaction.

<span id="debugging-honestly"></span>

## Debugging failures

For a state or ordering bug, first reproduce the interaction in a native spec.
The native executable supports ordinary debuggers and allocation diagnostics,
and the spec gives you a repeatable event sequence. Browser-only failures need
a browser reproduction as well.

The Wasm host records `crash` messages as host diagnostics. The runtime reads
those diagnostics after a host failure and a supplied `onError` callback can
report fatal errors, including failures entered through events. `dbg` and
`expect` reporting remain empty hooks in the Wasm host, so they are not a
browser logging facility.

After a fatal host failure, the runtime marks the instance unusable, stops its
listeners and asynchronous work, and rejects later calls. Staged host commands
are not applied. Recovery requires a fresh mount; do not try to resume the
failed instance.

Atomic command publication is not rollback of browser APIs. If an executor or
integration fails after some DOM operations or external effects have run, those
operations may already be visible. Error reporting should not assume the page
can retry that batch or restore a previous browser state.

## Telemetry

Pass a callback as the `telemetry` option to `mountSignalsApp` to inspect command
batches, byte and decode counts, task events, and interval activity. For example:

```js
const runtime = await mountSignalsApp({
  wasmUrl: "./app.wasm",
  root: document.getElementById("app"),
  telemetry: (event) => console.log(event),
  onError: (error) => console.error(error),
});
```

Task telemetry distinguishes starting, resolving, cancelling, and ignoring a
stale resolution. An `ignored_task_resolution` event can explain why a late
response did not update the UI. `behavior_missing` identifies an element whose
named JavaScript behavior was not registered with an `attach` function.

For aggregate command traffic from a built app, use the mount helper in
[contributing](@/docs/contributing.md#bundles). Keep measurements tied to a
particular artifact and interaction sequence.

## Design constraints

The authoritative architecture is
[`design.md`](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md).
It describes both the invariants and the intended direction of the platform;
its target API appendix is not a list of available functions. Use the
[reference](@/docs/reference.md) and platform modules for the implemented API.

## Next

[Reference](@/docs/reference.md) lists the application-facing modules and helpers.
