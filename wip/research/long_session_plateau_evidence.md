# Long-session Plateau Evidence

Captured: 2026-07-03.

Purpose: keep detailed structural evidence out of the active backlog. Promote new
long-session or slot-reclamation work only when a current measurement shows a
budget violation.

Refresh check: re-run on 2026-07-05:

- `zig build run-test-zig -Dtest-filter=plateau -Dtest-filter="dirty queue"`
  exited successfully.

The current dense-table, scratch-capacity, and dirty propagation coverage below
remained green.

Refresh check: re-run on 2026-07-11 for Conduit Phase 5 measurement triage:

- `zig build run-test-zig -Dtest-filter=plateau -Dtest-filter="dirty queue"`
  exited successfully.

No structural work is promoted from Conduit Phase 5: the reusable plateau gate is
green, while the planned Conduit-specific soak run is blocked by current Roc
compiler crashes before the app can be built for native spec or wasm execution.

## Focused Gate

For evidence-only edits that do not change coverage or current-state claims, run:

```sh
git diff --check
zig build run-check-tidy
```

For plateau, slot-reclamation, or dirty-queue current-state claims, run:

```sh
zig build run-test-zig -Dtest-filter=plateau -Dtest-filter="dirty queue"
```

For promoted structural work that changes benchmark or work-budget claims, add:

```sh
python3 scripts/test.py bench --native always
```

For promoted app-facing structural behavior, also run:

```sh
python3 scripts/test.py native --native always
```

## Native Zig Coverage

- `src/native_host.zig`: `signals host keeps live allocations and table sizes flat across repeated events`
  reuses one host across 100 event dispatches and compares plateau snapshots after
  warmup.
- `src/native_host.zig`: `signals host keeps table sizes flat across repeated keyed row reorder churn`
  reuses one host across 80 dirty keyed-row reorder updates, asserts no row
  creation/removal, avoids row body recollection, and compares plateau snapshots
  after warmup.
- `src/native_host.zig`: `signals host removal reinsert churn plateaus dense tables`
  alternates bounded keyed-row membership for 40 updates, expects one row
  creation/removal per update, and checks table sizes plateau after warmup.
- `src/native_host.zig`: `signals host nested removal reinsert churn plateaus branch scopes`
  runs the same bounded membership churn with nested `when` branches in each row
  and checks branch/component scope tables plateau after warmup.
- `src/signals/active_signal_graph.zig`: `active graph dirty queue collects roots and dependents by rank`
  proves root-triggered dirty propagation includes reachable dependents once and
  orders them by graph rank.
- `src/signals/active_signal_graph.zig`: `active graph dirty queue collects source-route dependents by rank`
  proves source-route propagation deduplicates repeated route entries and orders
  reachable dependents by graph rank.
- `src/signals/active_signal_graph.zig`: `active graph dirty queue reuses retained buffers and ranks reachable records`
  collects dirty records twice through the same retained queue on a diamond-shaped
  graph, asserts the converged dependent appears once, and asserts the pending,
  ordered, seen, and rank-count buffers do not grow on the second pass.

## Snapshot Dimensions

`HostPlateauSnapshot` currently captures:

- retained Roc allocation delta, host retained allocation delta, and host
  retained byte delta.
- native DOM element count.
- active event, event descriptor, signal descriptor, route, dependent, cache,
  state table, state-index, scope, each-row site, and each-row membership table
  lengths.
- node identity and DOM identity table lengths.
- active descriptor-stream element, event, and state lengths.
- active signal graph length and source/text/bool/change/structural route lengths.
- active interval and pending task table lengths.
- dirty propagation scratch capacities: seen generations, pending records, ordered
  records, rank counts, and `dirty_changed_record_ids`.

## Result

The current suite proves plateau behavior for the dense tables and scratch
buffers listed above under repeated events, dirty keyed reorder churn, bounded
removal/reinsert churn, and nested branch-scope churn. It also pins dirty-queue
reachability, rank ordering, source-route deduplication, diamond convergence
deduplication, and retained scratch reuse. Additional structural work should stay
measurement-gated: add or promote it only with a failing budget, a new counter,
or a maintained app or focused fixture that demonstrates a remaining long-session
growth path.

Promotion trigger: name the violated `design.md` budget, the current
counter/benchmark proving it, and the smallest representative app or focused
fixture that demonstrates the long-session growth path. The promoted slice must
preserve existing O(1) lookup and local-splice discipline; do not trade memory
plateaus for scans or broad rebuilds.

Scratch/arena promotion proof belongs in this note too. Name the specific
transient host-internal buffer, the counter that shows it still matters, and the
fixture that reproduces the cost. The measurement must keep host-internal scratch
separate from Roc-owned heap values; do not use this gate to move boxed Roc
values or refcounted data into per-cycle scratch storage.
