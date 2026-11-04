# Existing application API, experimental Roc runtime

Run from the repository root:

```sh
bash .test-out/roc-runtime/reproduce.sh
```

Uses the pinned nightly-2026-09-12-220fd47 compiler, default unoptimized Roc
build, Zig Debug, and Node/Wasm. No optimized timing claim is made.

## What actually executes

main.roc is the unchanged-API acceptance app from ../generic-engine/same-api,
with only its platform URL changed. TaskPanel.roc is identical. The public
Ui, Signal, Html, Elem and capability modules are unchanged copied platform
sources. The app supplies no model, graph IDs, registrations or update loop.

platform/Runtime.roc interprets the existing descriptors, owns a node list,
Roc Dict identity index, rank-ordered deduplicating queue, source/derived caches,
rendered-text model, event bindings and scopes. Map/Map2 callbacks execute from
Roc. The platform entrypoints transfer one Box(Runtime.Model) into and out of
the host. main() runs only at initialization; conditional builders run when
their branch becomes live, not on ordinary events.

host.zig does NOT import the Zig engine. It imports copies of the existing
checked value registry, capability and ABI helpers. It provides raw allocation,
opaque identity, checked equality/drop invocation, and value ownership primitives.
It owns the current model pointer without inspecting it. The copied shared
directory contains other files, but they are not part of the host's import path
unless used by those helpers; there is no graph execution delegated to them.

## Verified result

Three fresh instances each pass mount, first task toggle, counter increment,
equal counter update, second task toggle, first-component disposal, recreation,
and teardown. The assertions execute against the experimental runtime, NOT the
native production engine.

- Task changes run exactly three derived callbacks and one text update, with
  no scope changes. The unchanged caption prunes while the status and combined
  output change.
- Counter changes run one derived callback and one text update; equality runs
  zero derived callbacks and emits zero text updates.
- Independent sibling state survives updates and branch removal/recreation.
- Cached values count 11 after mount, 7 while the first task is hidden, and 11
  after recreation. Its recreated state starts open rather than retaining done.
- Normal teardown leaves zero registry values and zero live Roc allocation
  requests/bytes. Registry backing is also released before the host reports
  completion. This is requested ownership, not reclaimed Wasm page capacity.
- Disposable negative-test instances reject a stale button binding with
  `disposed event` and cross-capability comparison with `CapabilityMismatch`.
- Inverting equality pruning deliberately made the first task action fail its
  rendered-text assertion. The mutation was removed and the suite rerun.

The checked registry caught an initial prototype bug: Ui.switch builders consume
the case argument. Runtime now supplies an owned clone at both mount and branch
replacement instead of transferring its cached value. This is not a compiler bug.

## What is not established

This is a semantic experiment, not a replacement product engine or browser
renderer. It checks an in-Roc rendered-text model and work counts; it does not
publish a browser command protocol. It supports only the descriptor and unit
click subset required by the fixture and rejects unsupported cases.

Most importantly, the runtime's caches STILL contain HostValue handles. Each
typed value remains in the existing checked host cell, with its capability.
Thus this verifies the app API and Roc graph-execution boundary, but NOT the
original allocation-consolidation hypothesis. One outer model does not mean
one allocation: columns, closures, nested values, and host cells remain.

The queue scans/sorts its frontier. Graph, visual and scope slot arrays are
append-only with explicit spike budgets rather than reusable production slot
stores. Scope dependency detachment for ancestor-shared signals and arbitrary
cross-scope sinks is incomplete; the fixture's conditional component owns its
own sources. No generic cross-scope locality claim follows from this test.
Snapshots, arbitrary shared model aliases, multi-source atomic actions, general
keyed rows, effects, timers, event policies, transactional command publication,
allocation-failure recovery and long-session capacity plateaus are unproven.
Traps are terminal and negative-test instances are discarded.

Current architecture in design.md still mandates the Zig runtime. This isolated
ignored spike explores an alternative without changing that authority or the
production implementation. The remaining decisive experiment is a safe
platform-private representation that consolidates heterogeneous typed state,
while retaining the exact app input and the semantic checks above.
