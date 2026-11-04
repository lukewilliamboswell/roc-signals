# Allocation spikes: trial plan

Three bounded experiments that test whether per-event and per-row allocation
in Roc Signals is a design choice or a floor. Each spike is assigned to one
agent, runs on its own branch, and ends in a written result against the gates
below. Nothing here changes `design.md`; spike 1 produces a *proposed*
`design.md` diff for human review and nothing more.

Read `AGENTS.md`, `design.md` (at minimum *Confined Erasure*, *The split law*,
*Complexity Discipline*, *Memory management and allocation failure*),
`docs/profiling.md`, and `www/content/docs/contributing.md` before starting.
Read `style.md` before editing Roc.

## Why these three

Historical baseline, superseded by each spike's re-baseline at `ea1da63d`.
Measured on 2026-11-02 at `main` `f8ee4748`, old pinned compiler
`nightly-2026-09-12-220fd47`, prebuilt `platform-web/targets/x64musl` host,
counter fixture (`examples-web/_fixtures/counter`), one Increment click:

| Metric (one click, second event after warmup) | Delta |
|---|---:|
| `derived_calls_into_roc` | 1 |
| `allocs_this_event` / `deallocs_this_event` (Roc) | 34 / 34 |
| `host_allocs_this_event` / `host_deallocs_this_event` (Zig) | 54 / 54 |
| `closure_retains` / `closure_releases` | 12 / 12 |
| `retained_alloc_delta`, `host_retained_alloc_delta` | 0 |

Issue #39 records the construction shape at create-10k on the benchmark
fixture: per row about 68 Roc allocations, 249 host allocations, 63 retained
callable or capability edges, 10 elements, 35 patches. PR #38's Chrome
comparison against SolidJS: partial update 0.96x, create-1k 3.51x, create-10k
5.61x, append 5.95x, clear 8.89x.

The inherent floor is one `Box` per changed node whose type the host cannot
see. Everything above that is split-and-replace reads (two boxes per read),
equality reading both sides (four boxes per prune check), per-event host
scratch, and per-row descriptor, closure, and capability construction.

PR #38 also recorded four experiments that reduced allocations but were
timing-neutral or slower end to end. **Every spike therefore gates on
optimized wall time as well as counts.** A count win without a time win is a
negative result and is reported as one.

## Shared protocol

### Toolchain and builds

- Base: `ea1da63d` (origin/main plus the nightly upgrade from draft PR 169).
- Compiler: `/home/lbw/roc_nightly-linux_x86_64-2026-11-01-48d3369/roc`. Pass it
  explicitly as `--roc-bin` or `ROC_BIN`; the `roc` on `PATH` is different.
- Zig host for measurement: `zig build build-test-hosts -Doptimize=ReleaseFast`
  (add `-Dprofile=true` when you need symbols for `perf` or `addr2line`).
  Debug or ReleaseSafe hosts use the debug allocator and are for leak and
  invalid-free detection, not timing.
- App build for native probes:
  `roc build --target=x64musl --opt=speed --no-cache --output=<out> <fixture>/main.roc`.
  `--host-bench-app` rejects a host built in another optimization mode.
- Never write results or binaries under `.test-out/`; the test driver wipes it.
  Keep build outputs in a scratch directory outside the repo and keep results
  in the pull request or issue for the spike.
- One worktree per spike off `main`: `spike/shared-reads`,
  `spike/host-scratch`, `spike/row-anatomy`. Do not touch `design.md` except as
  spike 1's final proposal commit. Do not fold unrelated cleanups into a spike.

### The per-event probe

The spec runner stops at the first failed assertion and prints the actual
delta. Use that to read any metric for any step without adding instrumentation:

```sh
# probe.scm: warm up with one event, mark, repeat the event, assert an impossible delta
(test "probe"
  (steps
    (click (role button :name "Increment"))
    (mark-metrics)
    (click (role button :name "Increment"))
    (expect-metric-delta allocs_this_event 999999)))

<app> --host-run-spec-json probe.scm 2>&1 | grep -o 'Got .*'
```

Loop over `derived_calls_into_roc`, `allocs_this_event`, `deallocs_this_event`,
`host_allocs_this_event`, `host_deallocs_this_event`, `retained_alloc_delta`,
`host_retained_alloc_delta`, `closure_retains`, `closure_releases`. Always
measure the **second** identical event so one-time growth is excluded, and
report the first event separately when it differs.

### Timing

- Native: `--host-bench-app --host-bench-name <case> --host-bench-samples N`
  on the js-framework-benchmark fixture
  (`examples-web/_fixtures/js-framework-benchmark/specs/*.scm`, manifest
  `benchmarks.toml`), or `python3 scripts/test.py bench --native always`.
  Report median, range, sample count, machine, host mode.
- Production Wasm: `python3 scripts/test.py wasm-bench --roc-bin <roc>`; it
  pairs the production artifact with an instrumented companion for exact
  allocation counts. Wall time there is diagnostic, not gating.
- Browser: `benchmarks/js-framework-benchmark/roc-signals-keyed` (`npm ci`,
  `ROC_BIN=... npm run build-prod`, `npm run verify`), then the official runner
  per its README with Solid on the same machine and Chrome. Required only for
  spike 3's final gate; optional supporting evidence for spikes 1 and 2.

### Correctness suites every spike must pass before claiming a result

```sh
python3 scripts/test.py zig
python3 scripts/test.py roc-check
python3 scripts/test.py roc-test
python3 scripts/test.py native --native always
python3 scripts/test.py wasm
python3 scripts/test.py browser
python3 scripts/test.py fault --native always      # spikes 1 and 2 especially
python3 scripts/fuzz.py check                      # replays the committed corpus for every target without AFL++
python3 scripts/test.py gui                         # spike 1 changes the GUI platform too
```

Check `test/known-failures.txt` at `main` first so pre-existing failures are
not attributed to the spike.

### Result report (one per spike, in the PR description)

1. Hypothesis and whether it held.
2. Before and after table for every metric above, on the named fixtures.
3. Optimized timing before and after, with spread.
4. Correctness commands run, with outcomes, including fault and fuzz replay.
5. Remaining hotspots and anything deliberately left out.
6. For spike 1 only: the proposed `design.md` wording and the compiler finding.

---

## Spike 1: refcount-shared reads instead of split-and-replace

### Hypothesis

A non-consuming read of a retained cell can share the existing `Box(a)` by
reference count instead of splitting it into two fresh boxes. Reads then
allocate nothing, and the counter click falls from 34 Roc allocations to
roughly 3 to 5 (the reducer's new state box, the transform's new output box,
and any string the app builds). Pruning checks and sink reads stop allocating
entirely.

### Design conflict, stated up front

`design.md` *The split law* (around line 933) says a `get` is "split-and-replace
clone, never a borrow" and that the host "never increments a nested refcount".
A shared outer box is neither a borrow nor a nested refcount, but it is not
what the text says. The spike must not paper over this. Its final deliverable
is a separate commit proposing new wording for *The split law*, *Boundary
discipline*, and the `CapabilityHandle` sketch, with the measured evidence
attached. Whether that commit lands is a human decision.

### Step 0: compiler semantics check (do this first, half a day)

The approach is only sound if `Box.unbox` on a box with refcount greater than
one leaves the box intact, increments the payload's nested refcounts, and
decrements the box, and if dropping either alias later releases nested fields
exactly once. The pinned compiler has `box_unbox`, `box_unbox_borrowed`, and a
`consume_dead_boxes` solver flag (`src/lir/arc_solve.zig` in the Roc repo); do
not assume the behavior, test it.

Write a small Roc program under a scratch platform (copy the pattern of the
Sept 2026 spikes: raw ABI helpers only, native host with
`--host-trace-allocations` or the Zig debug allocator for the leak oracle):

1. Box a record containing a heap `Str` (over 23 bytes), a `List(Str)`, and a
   tag union carrying a `Str`.
2. Share it two ways and keep both variants in the test:
   - **A (host incref):** the host calls `abi.increfBox` on the outer box and
     passes both aliases to Roc.
   - **B (Roc share):** an app-compiled `share : Box(a) -> { keep : Box(a), out : Box(a) }`
     that returns the same box in both fields, so the compiler inserts the incref.
3. Unbox one alias, append to the list, build a new string from the old one,
   rebox. Unbox the other alias and assert the original content is unchanged.
4. Drop in both orders (first-then-second, second-then-first). Assert zero live
   Roc allocations and no invalid free at teardown.
5. Repeat with the payload being a boxed closure that captures a `Str`, since
   capabilities and transforms are closures.

If either variant fails, stop the spike, file the upstream issue with the
minimized program, link it from the result report, and record which variant
is viable. If both pass, prefer B for the implementation because it keeps the
host literally refcount-free, and measure A as the alternative.

### Scope

Roc platform (both platforms; the hosted lists must stay identical):

- `platform-shared/Capability.roc`, `platform-web/Capability.roc`,
  `platform-gui/Capability.roc`: replace `split` with the chosen share
  operation inside `clone`, `eq`, and the read path. `drop` stays
  app-compiled and keeps consuming the box; a decref of a shared box is
  already correct Roc.
- `platform-shared/HostValue.roc` and the two platform copies: rename or
  replace `get_with_split!` / `take_with_split!` only if the hosted signature
  changes. If the hosted signature changes, regenerate glue
  (`roc glue <roc>/src/glue/src/ZigGlue.roc src/signals platform-gui/main.roc`,
  then `zig fmt src/signals/roc_platform_abi.zig`) and update the hosted
  lists in `platform-web/main.roc` and `platform-gui/main.roc`.

Zig engine and hosts:

- `src/signals/host_value_registry.zig`: `getWithSplit`, `getWithSplitUnchecked`,
  `clone`, `get`, `take`, and the `assertTakenAfter` epoch postcondition.
  Keep the `CloneReturnedSource` and capability-match checks; they are about
  handles, not boxes, and still apply.
- `src/signals/host_values.zig` `RegistryOps.splitBoxWithSplit` and
  `src/signals/erased_calls.zig` `callErasedRocBoxToRocBoxPair`.
- `src/signals/roc_platform_abi.zig` is a generated layout contract; only
  regenerate it, never hand-edit meaning into it.
- `src/native_host.zig` and `src/wasm_host.zig` hosted exports
  (`hostValueGetWithSplit`, `roc_host_value_get_with_split`, and the
  compile-time signature checks beside them).

Do not change the engine's call sites in `engine.zig`
(`evalDirtyHostSignalRecord` and friends); if the registry contract holds,
they should not need to know.

### Measurements

Before and after, same host mode, same compiler:

| Fixture | Event | Metrics |
|---|---|---|
| `_fixtures/counter` | second Increment | all nine probe metrics |
| `_fixtures/large-each-08` and `large-each-64` | Update middle row, Append one row, Remove middle row | the existing `(expect-metric-delta-at-most allocs_this_event ...)` budgets in their specs, plus actual values |
| `_fixtures/js-framework-benchmark` | `update_10k.scm`, `select_1k.scm`, `swap_1k.scm` | `allocs_this_event`, `host_allocs_this_event`, `closure_retains`, native bench median |
| `_fixtures/signal-combine-caps`, `coordinated-writes`, `task-latest-wins` | their existing specs | pass/fail only; these exercise `eq`, multi-source writes, and effect snapshots through the read path |

Then tighten the `allocs_this_event` budgets in
`examples-web/_fixtures/generate_large_each.py` (currently `row_count * 200`)
and the large-each specs to the new measured ceiling with a small margin, so
the win is pinned by CI rather than remembered.

### Gates

- Compiler check passes for the chosen variant with zero live allocations in
  every drop order.
- Counter second click: Roc allocations at most 6; `retained_alloc_delta` 0.
- No metric regresses on any listed fixture; `derived_calls_into_roc` and the
  structural counters are unchanged everywhere (this spike must not change
  what runs, only what allocates).
- `closure_retains == closure_releases` after teardown on every spec; the
  `ownership` and `transactions` fuzz corpora replay clean; the `fault` suite
  passes with its recounted coordinates.
- Native bench on `update_10k`, `select_1k`, `swap_1k`: median not worse than
  baseline beyond measured spread. Report whether it improved; a count win
  with a flat time is still a pass here because the sparse-update path was
  already tied with Solid, but say so plainly.
- Release-build capability mismatch, inactive frame, and stale handle
  rejections still fire (design *Measures of Effectiveness* item 7). Add a Zig
  test that a shared-read box handed to the wrong capability is refused
  before typed access.

### Risks to watch

- `eq` previously received two independently owned boxes; with sharing it
  may receive two aliases of the same box when comparing a value to itself.
  `is_eq` must still be called (design: do not assume reflexivity).
- A consuming callback (`take`) on a shared box must still produce an
  independently owned result for the caller; check `Ui.switch` builders and
  effect snapshots, which the roc-runtime spike found consume their argument.
- Rows generation identity relies on callable-pointer comparison
  (`rowsSameGenerationCallable`); sharing boxes must not make two generations
  compare equal.

### Out of scope

Allocator changes, host scratch (spike 2), any public API change, templates.

---

## Spike 2: retain host scratch across events

### Hypothesis

The 54 host allocations on a counter click, and a large share of the 249 host
allocations per row at create-10k, are per-event or per-transaction growth of
buffers that already have a home in `src/signals/engine_scratch.zig` or could
have one. Retaining capacity drives steady-state event host allocations to
zero and reduces construction host allocations materially, without touching
any ownership or reactive semantics. No design question arises; the design
already requires work proportional to the changed set and says to retain
scratch capacity.

### Step 1: attribute, do not guess

Two tools exist and need no new code:

- `--host-fail-on-allocation N` prints `[ALLOC-FAULT] coordinate=N caller=0x...`
  and the origin for the Nth host allocation of a run. On a
  `-Dprofile=true` ReleaseFast host, sweep N over the coordinates inside the
  measured event and symbolize the callers with `addr2line -f -e <app>`. The
  JSON result's `host_allocation_attempts` gives the total to sweep.
- The native ledger records `return_address` and `phase` per allocation
  (`src/roc_alloc_ledger.zig`, `debug_phase.zig`). If the sweep is too slow for
  create-1k, add a temporary, uncommitted dump of `(phase, return_address,
  size)` for allocations between two `mark-metrics` and aggregate it.

Produce a table: call site, phase, count per event, bytes, whether the buffer
is event-scoped, transaction-scoped, or legitimately retained. Do this for
the counter click, `large-each-64` Update middle row, and `create_1k.scm`
(per-row figures). Known candidates from reading the code, to confirm or
rule out: the `combine` branch of `evalDirtyHostSignalRecord` builds a fresh
`shared_buffer.List(HostValue)` per evaluation; command staging in
`render_sink.zig` / `render_commands.zig`; the candidate overlay in
`transaction_map.zig` and `signal_records.PreparedCacheUpdates` (note the
existing `cache_overlay` parking pattern in `Scratch`); dirty scheduling in
`active_signal_graph.zig`; event payload decoding in `boundary.zig`; and
`descriptor_stream.zig` collection during row ingestion.

### Step 2: retain, preserving the failure contract

For each confirmed event-scoped or transaction-scoped buffer, move it into
`engine_scratch.Scratch` (or the equivalent owner on the host side), clear it
while retaining capacity, and keep growth fallible and preflighted. Rules:

- Retained capacity does not exempt growth from preflight. A failed
  reservation must still refuse before any committed state or published
  command changes. The `fault` suite and the `structural`, `propagation`,
  `rows-transitions`, and `transactions` fuzz targets check exactly this; run
  them after every batch of changes, not once at the end.
- Bound retention. Define the shrink or cap policy for each buffer in a
  comment beside it (design: define reservation, release, saturation before
  adding retained storage). Buffers sized by total graph are already covered
  by the `cache_overlay` comment; do not add a new O(total graph) reservation
  on a steady-state path.
- Do not use an arena to blur Roc ownership. Roc values and signal records
  keep their deinit and decrement paths.

### Measurements

| Fixture | Event or phase | Metrics |
|---|---|---|
| `_fixtures/counter` | first and second Increment | `host_allocs_this_event`, `host_deallocs_this_event`, `host_retained_alloc_delta` |
| `_fixtures/large-each-64` | Update middle row, Append one row, Remove middle row | the same, plus the existing structural budgets |
| `_fixtures/js-framework-benchmark` | `create_1k.scm`, `create_10k.scm`, `update_10k.scm`, `clear_10k.scm` | host allocations per row, `host_retained_alloc_delta`, native bench median |
| Long session | 1,000 repeated `update_10k` or large-each updates | `host_retained_alloc_delta` and `retained_alloc_delta` flat after warmup; Wasm pages flat in `wasm-bench` |

### Gates

- Second identical event on counter and large-each: `host_allocs_this_event`
  is 0. Report the first-event figure separately.
- Create-1k host allocations per row at least halved from the attributed
  baseline, with the remainder listed by call site and classified as
  legitimately retained or deferred to spike 3.
- Long-session gauges flat; retained host bytes bounded by the stated policy.
- `fault` suite passes; fuzz corpora for `structural`, `propagation`,
  `rows-transitions`, `transactions` replay clean under `scripts/fuzz.py check`; mutation-test at least one
  moved buffer by making its growth infallible and confirming a fault target
  fails.
- Native bench medians on `create_1k`, `create_10k`, `update_10k`, `clear_10k`
  not worse than baseline beyond spread, and report any improvement.
- No change to `derived_calls_into_roc`, structural counters, or command
  output on any spec.

### Out of scope

Roc-side allocations (spike 1), descriptor representation, templates.

---

## Spike 3: per-row construction anatomy, hoisted capabilities, and a template slice

### Hypothesis

Bulk construction is slow because each row materializes its own descriptor
tree, transform boxes, and capabilities, and the engine then ingests that tree
into its own tables. `Capability.new` alone boxes a split handle plus clone,
eq, and drop closures for every signal edge in every row although none of them
captures anything row-specific. Sharing declarations across rows (issue #39's
template direction) and hoisting constant closures removes most per-row
allocations and retained edges, and that, unlike the earlier count-only wins,
moves optimized create-10k time.

This spike has two halves. Part A is measurement only and is a prerequisite
for both Part B and any decision on issue #39. Part B is the smallest template
slice that can produce a timing result.

### Part A: anatomy of one row (two days, no engine changes)

On `_fixtures/js-framework-benchmark` `create_1k.scm`, attribute the ~68 Roc
and ~249 host allocations per row and the ~63 retained edges per row:

1. Read the fixture's row builder and list, per row, every `Signal.map`,
   `Signal.map2`, `Ui.state`, `Signal.select` or `Row.select`, event handler,
   text or attribute sink, and element. For each, count the boxes the
   platform code allocates (expression box, transform box, `Capability.new`
   boxes, handler boxes) by reading `platform-web/Signal.roc`, `Ui.roc`,
   `Capability.roc`, `Html.roc`, `Elem.roc`.
2. Confirm by ablation: build fixture variants that remove one feature at a
   time (the selected-class binding, the two event handlers, the label
   projection, the static attributes) and probe `allocs_this_event`,
   `host_allocs_this_event`, `closure_retains` per row for each. Keep these
   variants in a scratch directory, not the repo.
3. Use the native ledger phases (`debug_phase.zig`) to split construction into
   Roc builder time, descriptor ingestion, graph construction, event binding,
   scope creation, and command publication. `perf record` on a
   `-Dprofile=true` host per `docs/profiling.md` for cycle attribution.
4. Produce one table: allocation class, count per row, bytes per row,
   retained or transient, Roc or host, and which lever removes it (spike 1,
   spike 2, hoisting, templates, none).

Deliverable: that table plus a cycle breakdown, posted on issue #39. This is
useful even if Part B does not run.

### Part B1: hoisting constant capabilities (two to three days)

`Capability.new` produces closures that depend only on the monomorphized type
(and on `is_equal`). Evaluate three ways to stop paying for them per row,
measure whichever is viable, and reject the rest with reasons:

- **Compiler static boxes.** Does the pinned compiler allocate a non-capturing
  boxed closure statically (refcount 0, like the host's `static_unit_box`)?
  Test with a tiny program and the ledger. If not, this is an upstream feature
  request, not a platform change; file it and link it.
- **Platform-level reuse inside a site.** Inside the engine's ingestion of a
  row subtree, capabilities whose clone, eq, and drop callables have the same
  function pointer and zero capture bytes are interchangeable. Interning them
  per `Ui.each` site is O(1) by hash and never scans, but it changes
  capability ownership from per-edge to shared-with-refcount, and the design
  says callable addresses are alias tokens, not identity. Prototype only if
  the first option is unavailable, and present the ownership change
  explicitly in the report rather than as glue.
- **Templates make the question moot.** With #39 the builder runs once per
  site, so per-row capability creation disappears by construction. If Part A
  shows capabilities are under a quarter of per-row allocations, skip B1 and
  go to B2.

### Part B2: the smallest template slice (one week)

Implement stage 1 of issue #39 only: template static element, text, and
attribute structure plus exact row-key placeholders for text and attributes,
behind an explicit new entry point (names provisional, to be fixed in the API
PR). Ordinary `Ui.each` stays untouched as the dynamic path.

Constraints from #39 and `design.md` that the slice must honor even as a
prototype: every row still owns a row scope; identity is
`(template_site_id, local ordinal, row_handle)`; the template is copied into
host-owned stable storage or held by one explicit owner, never a borrowed Roc
slice; host growth is preflighted; teardown unlinks instances before the site
owner is released; no JS wire change unless a command record actually changes.

Benchmark shape: port the js-framework-benchmark row to the template entry
point in a copy of the fixture, keeping commands byte-identical to the
ordinary `Ui.each` version (assert this with the spec decode golden or a
direct command-stream diff).

### Measurements

| Fixture | Case | Metrics |
|---|---|---|
| benchmark fixture, ordinary vs template | `create_1k`, `create_10k`, `append_1k_to_10k`, `replace_1k`, `clear_10k` | Roc and host allocations per row, `closure_retains` per row, native bench median and spread |
| same | `update_10k`, `select_1k`, `swap_1k` | unchanged `derived_calls_into_roc`, `each_key_compares`, `rows_*` counters, no DOM rebuilds on reorder |
| production Wasm | paired `wasm-bench` run | Wasm script time for create-10k, Wasm pages, host retained bytes |
| browser | official runner, Roc vs Solid, same machine and Chrome | create-1k, create-10k, append, replace, clear ratios; keep the update, select, swap cases to show no regression |

### Gates (from #39, made concrete)

- The template builder runs exactly once per site; assert it with a counter.
- At least 50% fewer Roc row-construction allocations and retained edges per
  row for the benchmark shape, measured not estimated.
- Commands identical to the ordinary `Ui.each` version for the same rows.
- Optimized create-10k improves beyond measured spread in both the native
  bench and the paired production Wasm run; the browser ratio against Solid
  improves from 5.61x. Report the number; do not set a pass threshold
  retroactively.
- Update, select, swap work counters unchanged; reorders rebuild no template
  instances and preserve every row scope.
- Fault sweep on template mount and append leaves the previous generation and
  DOM readable and publishes nothing partial; teardown balances
  `closure_retains == closure_releases` for site owner and instances.
- A composition canary from `wip/issues.md`: one packaged row component with
  independent inputs, an action callback, and a conditional child, written by
  someone other than the implementer, with notes on what was awkward. If it
  cannot be expressed in stage 1, say so; that is a result.

### Out of scope

Stages 2 to 5 of #39, scoped string symbols (#33), any allocator change, any
change to ordinary `Ui.each` semantics.

---

## Sequencing and dependencies

- Spike 2 is independent and lowest risk. Start it immediately.
- Spike 1 starts with Step 0 (the compiler check). Do not write platform or
  engine code until Step 0 has a result; a negative there ends the spike with
  an upstream issue, which is still a complete deliverable.
- Spike 3 Part A starts immediately and in parallel. Part B1 waits for Part A.
  Part B2 benefits from spikes 1 and 2 landing first because they change the
  per-row anatomy, but it can start on `main` if they are not merged within a
  week; rebase and re-measure before the final report.
- Keep the three branches independent. If two spikes touch the same file
  (likely `host_value_registry.zig` for spike 1 and `engine_scratch.zig` for
  spike 2), coordinate through the branch owner, not by merging one spike into
  another.

## Decision rules after the spikes

- Spike 1 passes its gates: open the `design.md` proposal for review and pin
  the new allocation budgets in the generated large-each specs.
- Spike 2 passes: merge; it has no design question.
- Spike 3 Part B2 moves optimized create-10k meaningfully and the canary is
  writable: proceed with #39 stage 2 under the existing P0 gate in
  `wip/issues.md`.
- Spike 3 shows create-10k still above roughly 3x Solid after templates, or
  the canary is not writable without host ids or hidden conventions: that is
  the honest trigger to revisit the platform's viability, and the report
  should say so in those words.
- Any spike that wins on counts and loses or ties on time is reported as a
  negative result with the attribution of where the time actually goes.
