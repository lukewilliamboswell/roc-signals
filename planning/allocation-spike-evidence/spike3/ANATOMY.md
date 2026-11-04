# Spike 3 Part A: anatomy of one js-framework-benchmark row

Base `ea1da63d`, compiler `nightly-2026-11-01-48d3369`, Zig 0.16.0, ReleaseFast
host built from the clean tree, app `--opt=speed` (native) or `--opt=size`
(Wasm). Machine: AMD Ryzen 7 9700X, shared with two other agents; load average
stayed between 10 and 37, so timing below is noisy even under the timing lock.
Allocation and work counts are deterministic.

Everything here predates any engine change. Raw data: `data/variants_create_1k.txt`,
`data/allocsites_*.txt`, `data/perf_*`, `data/wb_*.csv`. Generator:
`bin/mkvariants.py`. Old-base figures are only in `appendix-old-base/`.

## Baseline against the plan

| Metric | Plan and #39 | This base | Note |
|---|---|---|---|
| Counter click, second event | 34 Roc, 54 host, 12 retains | 34, 54, 12 | identical |
| Roc allocs per row, create 1k | ~68 | 81.67 | 21.67 is the Rows reducer, 60.00 the row path |
| Host allocs per row | ~249 | 185.15 as reported | see the correction below |
| Retained edges per row | ~63 | 60.04 | |
| Elements, patches per row | 10, 35 | 10, 35 | |

**Correction to how "host allocations" reads.** `host_allocs_this_event`
includes every Roc allocation: `rocAllocAt` calls `recordHostAlloc` as well as
`recordRocAllocMetric`. Proof: `no_each` reports 21,665 Roc and 21,782 "host".
So the real figure is 103.48 host allocations per row natively, of which about
20 are the native simulated DOM publication. Production Wasm, which has a
separate host counter, reports 68.5 host and 84.5 Roc calls per row. The 249
in #39 cannot be read as "249 Zig allocations".

## 1. What the row declares

From `render_row` in `examples-web/_fixtures/js-framework-benchmark/main.roc`:
9 elements plus 1 static text and 1 signal text, reduced by the spec counters to
10 `create_element` (the text nodes are counted there), 2 `Row.select`/`row.map`
bindings, 2 `on_event` handlers, 2 `Ui.state` reads through `model.update`, 7
`class_attr`, 2 `aria_label`, 1 `test_id`, 2 custom `attr`.

Boxes by platform code, per row:

| Construct | Boxes the platform allocates | Source |
|---|---|---|
| Row entry (`row_hv`) | 2: `row_source` box, `RowSource` expr box | `Ui.each` |
| `Capability.new()` | 4: `split_handle`, `clone!`, `eq!`, `drop!` | `Capability.roc` |
| `row.map` | 1 capability (4), `wrapped!`, expr box, plus the `read!` box in `text_s` | `Signal.map`, `Html.text_s` |
| `row.select` | no capability (site-shared `Keyed`), expr box, `read!` box in `class_attr_s` | `Signal.Keyed.for_row` |
| `model.update` | 1 payload capability (4), `wrapped!` | `State.update` |

Three `Capability.new` per row: one for the label, one per handler.

## 2. Ablation (measured per row, `create_1k`)

Each variant removes one feature and leaves everything else. `bin/mkvariants.py`
binds only what it uses, since an unused binding still constructs its descriptor.

| Variant | Roc | Host proper | Retained | `create_element` |
|---|---:|---:|---:|---:|
| `full` | 81.67 | 103.48 | 60.04 | 10 |
| `no_events` | 71.67 | 91.47 | 46.04 | 10 |
| `no_remove_event` | 76.67 | 97.48 | 53.04 | 10 |
| `no_label` | 62.67 | 102.47 | 39.04 | 10 |
| `no_select` | 67.66 | 97.45 | 35.03 | 10 |
| `no_static_attrs` | 75.67 | 59.46 | 60.04 | 10 |
| `static_key` (stage-1 shape) | 38.66 | 84.36 | 0.03 | 10 |
| `static_bare` (no attrs) | 29.66 | 40.33 | 0.03 | 10 |
| `one_elem` | 23.66 | 6.31 | 0.03 | 1 |
| `no_each` (Rows reducer only) | 21.67 | 0.12 | 0.02 | 0 |

Roc allocations reconcile exactly: 21.67 reducer + 2 row entry + 6 bare structure
+ 9 static attrs and key strings + 19 label + 14 selection + 10 events = 81.67.
Retained edges reconcile exactly: 21 label + 25 selection + 14 events = 60.

## 3. Roc and host attribution by phase

Sites from a throwaway instrumented host (`bin/instr_patch.py`, applied to a copy,
never to the worktree). Roc sites are hashed specializations; size class and
variant diffing identify them. Host sites by source line in
`data/allocsites_full.txt`.

Host proper, per row, `full`:

| Phase | Count | Where |
|---|---:|---|
| Graph and route planning | 16 + 2 | `PreparedStructuralDownstream` `engine.zig:10027`, `:9748` |
| Descriptor walk and strings | 10 + 8 + 1 + 4 + 2 + 2 + 1 | `collectActiveElemDescriptorsWith`, `prepareElementInNamespace`, `prepareTextNode`, `appendAttr` |
| Render topology | 8 + 6 + 6 + 4 + 1 + 1 | `BranchReplacementPlan.prepareRenderTopology` `engine.zig:10908`-`10988` |
| Native simulated DOM publication | 10 + 6 + 2 + 2 | `NativeRenderPublication.prepare`; absent in Wasm |
| Signal binding | 3 + 1 + 1 | `bindSignalRoot`, `bindSignalExprView` |
| Stream reservation, moved publication | 3 | `reserveMovedStreamPublication` |
| Scope, collection, transition | 3 | `reserveScopeDescriptors`, `prepareStable`, collection staging |

These are small per-string and per-node copies: of the 103 host allocations 78
come from the 10 elements and their attrs, and only 6 from the row itself.

## 4. Cycle breakdown (native `create_10k`, `perf record --call-graph dwarf`)

Classified by `bin/perfclass.py`. `full` was classified against its matching
binary; share of all process samples (3,552):

| Phase | `full` | `static_key` |
|---|---:|---:|
| Render topology and structural positions | 28.2% | 37.3% |
| Kernel, startup, spec parse (page faults dominate) | 15.0% | 17.3% |
| Reducer: Rows generation | 11.8% | 16.4% |
| Host teardown | 8.6% | 2.5% |
| Graph construction, routes | 7.7% | under 1% |
| Descriptor ingestion walk | 5.3% | 4.9% |
| Commit | 4.5% | 5.3% |
| Row item clone | 4.2% | 0 |
| Other row collection | 4.2% | 5.7% |
| Row `Elem` release | 3.0% | 2.6% |
| Row reconciliation prepare | 2.6% | 3.6% |
| First evaluation of row signals | 2.5% | 0 |
| Roc row builder | see below | 2.5% |
| Command publication | 1.0% | 1.2% |

Direct timer around the row builder call, `create_10k`, 5 interleaved runs,
median: `full` 45 ms, `static_key` 58 ms, `one_elem` 78 ms. These are not ordered
by work, because ledger hash growth lands inside whichever call crosses it, so
treat them only as a bound: **the Roc row builder is under 80 ms of 1,000 to
1,700 ms of native apply, about 3% to 5%.**

Native bench, `create_10k`, 5 samples, ms apply (`data/variants_bench.txt`):
`full` 1,724; `no_events` 1,383; `no_label` 1,427; `no_select` 1,457;
`no_static_attrs` 1,464; `static_key` 985; `static_bare` 927; `one_elem` 518;
`no_each` 0.16. The Rows reducer adds about 360 ms to all of them. **A one-element
row still costs 518 ms for 10k rows** (52 us per row), which no per-element or
per-closure lever touches.

Production Wasm, 5 samples of 5 fresh instances, median ms per action:

| Case | `full` | `static_key` |
|---|---:|---:|
| create 1k | 294 [201..329] | 130 [122..139] |
| create 10k | 1,923 [1,353..3,411] | 1,333 [1,238..1,857] |
| append 1k to 10k | 225 | 234 |
| replace 1k | 190 | 331 |
| clear 10k | 654 | 341 |

Roc 84.5 and 41.5, host 68.5 and 53.4 calls per row. The append and replace rows
are inside run-to-run noise. Spreads this wide mean only large effects can be
claimed.

### A cheap upper bound, with no engine change

Two variants render one constant row, with no key anywhere: `fixed_built` builds
it per row, `fixed_shared` returns one shared `Elem`. Nothing is constructed per
row in the second, so this is what skipping the builder can buy at most:

| | Roc/row | Host proper/row | `create_10k` apply | `create_1k` apply |
|---|---:|---:|---:|---:|
| `fixed_built` | 38.66 | 84.36 | 1,035 [median of 7] | 62.6 |
| `fixed_shared` | 23.66 | 84.35 | 937 | 69.4 |

Roc falls 15 per row, retained edges are already zero, host allocations do not
move, and time moves by about 9% at 10k and not at all at 1k within noise.

## 5. The table

Per row, `create_1k`. Bytes are from the instrumented ledger on `full`: 9,636
Roc bytes per row in total, 82,537 host bytes per row (most of the host bytes
are amortized hash-table growth, not per-row objects).

| Allocation class | Count/row | Bytes/row | Lifetime | Side | Lever that removes it |
|---|---:|---:|---|---|---|
| Rows generation, make_rows, labels | 21.67 | ~2,855 | item data retained; rest transient | Roc | none for items; spike 1 for read boxes |
| Row entry boxes | 2 | 176 | transient | Roc | templates (any stage), not stage 1 alone unless the entry skips the source |
| Static structure lists, element records | 6 | ~1,000 | transient | Roc | **templates stage 1** |
| Attr lists, key interpolation strings | 9 | ~1,700 | transient | Roc | **templates stage 1** |
| Label: `Capability.new` | 4 | ~160 | retained | Roc | hoisting or templates stage 2 |
| Label: map closure, expr, read boxes | 3 | ~250 | retained | Roc | templates stage 2 |
| Label: first evaluation, item clone, split reads | 12 | ~1,000 | mixed | Roc | spike 1 for split boxes; none for one output box |
| Selection: expr, read, cell initial value, split reads | 14 | ~1,100 | mixed | Roc | templates stage 2; spike 1 for split boxes |
| Events: `Capability.new` x2 | 8 | ~320 | retained | Roc | hoisting or templates stage 3 |
| Events: `wrapped!` x2 | 2 | ~100 | retained | Roc | templates stage 3 |
| Retained edges: label 21, selection 25, events 14 | 60 edges | n/a | retained | host refcount traffic | templates stages 2 and 3; hoisting would not reduce the count unless edges are also shared |
| Element and text descriptors, attr strings | ~28 | ~1,500 | retained | host | not stage 1; shared static storage (a later stage, or #33) |
| Graph and route planning | ~18 | ~250 | transient | host | spike 2 scratch |
| Render topology plan | ~26 | ~450 | transient | host | spike 2 scratch; instance-backed layout |
| Native sim DOM publication | ~20 | ~1,630 | mixed | host, native only | none needed, not in production |
| Signal binding | ~5 | ~1,000 | retained | host | templates stages 2 and 3 |
| Row scope, transition, reservations | ~6 | ~800 | mixed | host | none (a row owns a scope) |

## 6. Findings that change the plan

1. **Stage 1 covers 15 of 60 row-path Roc allocations (25%) and 0 of 60 retained
   edges.** Every retained edge in this row belongs to the label, selection and
   events, which are stages 2 and 3. The "50% fewer retained edges" gate cannot
   be met by stage 1 on the real benchmark row, by construction.

2. **The hypothesis that per-row Roc construction drives create-10k time is not
   supported natively.** The builder is 3% to 5% of apply and its `Elem` release
   about the same. Most time is structural: render topology and positions (28%
   to 37% of samples, 15% in `StableOrderIndex` insertion alone), scope and row
   machinery (52 us per one-element row), page faults, and the Rows reducer
   (about 20% of apply). Wasm has yet to be attributed the same way; B2 gives
   that measurement directly.

3. **Capabilities are under a quarter of per-row allocations.** Three
   `Capability.new` at 4 boxes is 12 per row: 14.7% of 81.67, or 20% of the 60
   row-path allocations. The handler ablation pins the 4: removing one handler
   removes exactly 5 (4 capability boxes plus `wrapped!`). **The skip rule
   applies. B1 is skipped; go to B2.**

4. **Compiler static boxes do not exist on this nightly.** Boxing a non-capturing
   lambda or a top-level function 1,000 times in a reducer allocates 1,000 times,
   identically to a capturing closure (`bin/staticbox.py`: 34, 1,034, 1,034,
   1,034 allocs for none, non-capturing, top-level, capturing). Even with static
   boxes, `clone!`, `eq!` and `drop!` capture `split_handle`, so only 1 of the 4
   boxes would qualify without restructuring `Capability`. Draft upstream text
   is in `upstream-static-box.md`; nothing is filed.

5. **Adjacent defect, reported and not fixed here.** `PreparedGraphAppend.plannedRecordId`
   (`active_signal_graph.zig:2053`) ends in a linear scan of the planned records,
   and `appendTextRoute` calls it once per sink, so route planning is quadratic
   in new signal records for one transaction: it is 7.9% self time on full-row
   create-10k and absent from the static row. This violates *Complexity
   Discipline* for bulk append, is independent of templates, and should be its
   own fix. It accounts for part of why `full` scales worse than linear
   (99 ms to 1,724 ms for 10x rows).

## Addendum after B2 (written after the engine change)

Finding 2 left Wasm unattributed. The slice now measures it directly on the
stage-1 row: dropping 17 Roc allocations per row moved production Wasm create 10k
from 1,157 ms [1,124..1,342] to 1,119 ms [1,093..1,248], inside the spread. Wasm
agrees with native: per-row Roc construction is not where create-10k time goes.
