# Roc-owned runtime spike, unchanged application API

Run from the repository root:

```sh
bash .test-out/roc-owned/reproduce.sh
bash .test-out/roc-owned/scale.sh
bash .test-out/roc-owned/native.sh
```

All scripts use nightly-2026-09-12-220fd47 and now explicitly select Roc
--opt=dev --specialize=yes with Zig Debug. The original scripts mistakenly
omitted --opt: roc build defaults to speed. The historical Wasm numbers below
are therefore Zig Debug + Roc speed, NOT wholly Debug measurements.

The explicit dev Wasm build currently emits invalid Wasm (Node reports an extra
stack value at fallthrough). native.sh is the working all-development reproduction,
using the same opaque host boundary and libc allocation with request accounting.
At 10/100/1000 rows, native mount retains 342/3222/32022 allocations; sparse
update requests 26 allocations and 2400 bytes at every size; clear requests 10
allocations and 779 bytes, freeing 332/3212/32012 allocations. Root teardown
leaves zero live requests/bytes. The snapshot fixture also passes natively.
These are allocation and semantic experiments, not timing comparisons to SolidJS.

## Boundary and representation

The acceptance app is identical to ../generic-engine/same-api except its
platform URL. TaskPanel.roc is identical. Applications still use Ui.state,
Signal.map/map2, components, events and conditional structure; they do not supply
a graph model, IDs, registrations, value union or update loop.

Runtime.roc interprets those descriptors inside the platform. Roc owns the graph
columns, Dict identity index, rank-ordered deduplicating queue, cached values,
scopes, event bindings and rendered-text model. The host retains an opaque boxed
state between calls. The small fixture also retains a snapshot; the scaling
fixture transfers a single Box(Runtime.Model) with no snapshot.

There is NO host value registry or Zig reactive engine on this execution path.
host.zig imports only the copied raw ABI helper. It supplies allocation,
diagnostics, opaque identity and ownership-preserving callable transfers.

Private HostValue now contains a Roc-owned boxed getter and capability token.
The getter captures its typed value inline. Its erased signature is never
invoked: a token-checked hosted transfer restores its original typed signature
before Roc calls it. The compiler-generated callable drop callback destroys the
actual capture. Ordinary Roc ARC owns cached values and their nested contents.
Capability retains a token and equality closure, not per-edge clone/drop closures.

This removes the old host-cell boundary, but DOES NOT remove all boxing. Each
cached heterogeneous value still has a boxed getter. Descriptors, callbacks,
capabilities and small adjacency/ownership lists retain further allocations.
One boxed model is one ownership root, not one heap allocation.

## Semantic checks

Three fresh instances pass independent component updates, exact callback/text
work counts, equality pruning, conditional disposal/recreation and teardown.
A task update runs three derived callbacks and one text update. A counter update
runs one callback; an equal counter update runs none.

The saved model remains unchanged and independently executable after each current
model update and after current-model disposal. An additional typed payload probe
roundtrips dynamic strings, nested lists and a capturing callback; two reads can
be independently changed and remain usable after releasing the original carrier.
All normal instances finish with zero live allocation requests and bytes.
Existing contract-rejection checks remain in the harness.

The pinned compiler crashes on a constant-input minimized hosted-callable
roundtrip. The probe uses a runtime argument, with the workaround linked beside
the call: https://github.com/roc-lang/roc/issues/11387.

## Historical mixed-mode Wasm allocation results (not Debug-only)

The scaling app mounts N independent TaskPanel components behind one conditional,
updates Row 0, clears that conditional, then disposes the root. It uses the same
public app API. Harness label lookup is outside the propagation work budget.

| Phase / metric | 10 rows | 100 rows | 1,000 rows |
| --- | ---: | ---: | ---: |
| Mount allocations | 657 | 6,079 | 60,108 |
| Mount requested bytes | 72,230 | 1,899,718 | 137,917,614 |
| Mounted live allocations | 352 | 3,322 | 33,022 |
| Sparse update allocations | 28 | 28 | 28 |
| Sparse update requested bytes | 1,825 | 1,825 | 1,825 |
| Clear allocations | 10 | 10 | 10 |
| Clear requested bytes | 583 | 583 | 583 |
| Clear frees | 342 | 3,312 | 33,012 |
| Allocations remaining after clear | 21 | 21 | 21 |
| Live allocations after teardown | 0 | 0 | 0 |

The original disposal implementation requested 358,224,583 bytes while clearing
1,000 rows. A helper which consumes the model's storage columns before retiring
entries reduced that to 583 bytes, without changing the application or work
assertions. The runner now bounds allocation counts/bytes for updates and clear.
Constructor helper/destructuring experiments did not improve construction and
were reverted. Mount still has strongly superlinear allocation traffic.

Clear retains table capacity: live requested bytes after clear are 13,644,
98,556 and 1,116,420 respectively. Root teardown releases these too. Host
instrumentation counts raw Roc requests; realloc deliberately allocates/copies,
and Wasm backing pages need not shrink when live requests reach zero.

The decisive remaining issue is representation: this fixture retains about 33
objects per row even with no host registry. Moving the engine alone does not
consolidate descriptors, getters, capabilities and small lists. These counts
cannot be compared directly with the original native 58k frees: the fixture,
execution target and build mode differ.

## Limits and architectural status

This is a headless semantic prototype, not a browser renderer. It supports only
the descriptor and unit-click subset exercised here. There is no browser command
protocol, general keyed reconciliation, effects, timer/task integration,
multi-source transaction handling or allocation-failure recovery.

The queue scans/sorts its frontier. Node, scope and visual slots are append-only
with explicit spike budgets, not reusable production slot stores. Cross-scope
dependency/sink detachment is incomplete. No long-session capacity plateau or
general changed-set complexity claim has been established.

design.md still mandates the shared Zig runtime. This ignored, isolated spike
deliberately explores an alternative; it does not change that authority or the
production application API. It establishes that platform-owned Roc execution,
Roc-owned heterogeneous values and shared snapshots can work for these fixtures.
It does not establish a production-ready replacement or a solution to the
original benchmark gap.
