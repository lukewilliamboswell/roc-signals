# Profiling and Improving the Engine

Use measurements to choose engine work. A useful optimization starts with a
repeatable workload, identifies a specific source of cost, and demonstrates
that the cost and wall time both improved without changing behavior.

## Start with a ReleaseFast native host

Roc links the platform host that is already present under `platform/targets/`
into a native app. Rebuild that host before measuring:

```sh
zig build build-test-hosts -Doptimize=ReleaseFast
```

`--bench-app` rejects hosts built in another optimization mode. In particular,
Debug enables expensive engine assertions whose scaling can overwhelm the code
being investigated. Roc's `--opt=speed` does not change the optimization mode
of a previously built Zig host.

Run every registered benchmark with:

```sh
python3 scripts/test.py bench --roc-bin /path/to/roc
```

The keyed-table fixture has a machine-readable coverage contract at
`examples/_fixtures/js-framework-benchmark/benchmarks.toml`. The benchmark
driver consumes its sample counts and warmup policy. Warmup runs replay the
complete spec in a fresh mounted host and discard all measurements; they do not
mutate the measured sample or get mixed into its allocation counters. This pins
the js-framework-benchmark convention: five warmups for replace, partial
update, select, swap, and remove, and no warmup for create 1,000, create 10,000,
append to 10,000, or clear 10,000.

The manifest is also the requirement-to-evidence map for browser comparisons:

| Requirement | Evidence available now | Browser evidence still required |
| --- | --- | --- |
| Nine table operations | Semantic/native cases plus a production adapter whose DOM and keyed identity behavior are checked | End-to-end duration from the official runner around each real DOM action |
| Ready/run/update/replace/repeated-clear memory | Exact action sequences and an official-harness-compatible artifact | Browser-process memory after stabilization and collection from the official runner |
| Startup time | Production `--opt=size` Wasm, runtime modules, and mount entry point | Navigation-to-first-render measurement from the official runner |
| Consistently interactive, script bootup, main-thread work | Required metric entries and a real-browser-mounted artifact | Lighthouse results from the official browser environment |
| Total byte weight | The complete production artifact is built in one directory | Post-compression transferred bytes reported by the official environment |

The Node/Wasm-controlled measurement path, production-host instrumentation,
and repeatable Node workflow are tracked in
[issue #19](https://github.com/lukewilliamboswell/roc-signals/issues/19). That
issue explicitly excludes real-browser layout, paint, cross-browser memory,
and Lighthouse. The adapter under
`benchmarks/js-framework-benchmark/roc-signals-keyed/` now supplies the real
production artifact and official DOM/build contract. The official runner still
owns browser timings, process-memory collection, and Lighthouse evidence; do
not attribute those measurements to the Node harness.

The manifest contract deliberately does not manufacture browser numbers from
the native host. Native results isolate Roc reducer time, engine application,
work counters, and allocation behavior. DOM layout/paint, JavaScript and Wasm
startup, browser heap accounting, compression, and Lighthouse metrics require a
real production browser build. Contract tests fail if any required operation,
warmup, memory scenario, audit metric, or adapter contract disappears.

Build the browser adapter from its directory:

```sh
cd benchmarks/js-framework-benchmark/roc-signals-keyed
npm ci
ROC_BIN=/path/to/roc npm run build-prod
npm run verify
```

The verifier exercises the production Wasm and shared JavaScript runtime and
asserts the official table structure plus keyed node movement, removal, and
replacement. For comparative numbers, copy the adapter into an official
`js-framework-benchmark` checkout as documented in its README and run Roc
Signals and the comparison framework with the same driver, browser, machine,
and checkout. A successful local verifier is not an official performance
result.

For quick iteration on the keyed table fixture on x86-64 Linux:

```sh
mkdir -p .test-out/profile
roc build \
  --target=x64musl \
  --opt=speed \
  --no-cache \
  --output=.test-out/profile/js-framework-benchmark \
  examples/_fixtures/js-framework-benchmark/main.roc

.test-out/profile/js-framework-benchmark \
  --bench-app \
  --bench-name replace_1k \
  --bench-warmup 5 \
  --bench-iterations 1 \
  --bench-samples 7 \
  examples/_fixtures/js-framework-benchmark/specs/replace_1k.scm
```

Use the Roc target for the current machine on other platforms. Keep the host,
Roc app, fixture, compiler, and machine unchanged when comparing revisions.

The native benchmark CSV separates:

- `dispatch_roc_ns`: time executing the Roc event reducer;
- `dispatch_apply_ns`: host propagation, reconciliation, and render-command
  generation;
- `total_ns`: the complete measured operation, including small harness costs;
- runtime counters such as scanned descriptors, keyed-row work, emitted
  patches, and allocation counts.

Report the median and range from multiple samples. One sample is useful only
for finding very large regressions. Avoid increasing `--bench-iterations` for
large cases until one iteration is known to finish quickly.

## Measure the production Wasm and JavaScript path

Run every Node/Wasm boundary case with:

```sh
python3 scripts/test.py wasm-bench --roc-bin /path/to/roc > before.csv
```

This builds the ordinary Wasm host with Zig `ReleaseFast`, builds the Roc
js-framework fixture with `--opt=size`, performs one complete warm-up pass, and
runs seven samples of twenty fresh instances per case. Narrow an investigative
run without changing the meaning of an iteration:

```sh
python3 scripts/test.py wasm-bench \
  --roc-bin /path/to/roc \
  --bench-case 'select_*' \
  --bench-warmups 1 \
  --bench-iterations 5 \
  --bench-samples 3 \
  --bench-app-opt size > select.csv
```

Build diagnostics go to stderr; stdout is CSV. Each measured iteration creates
a fresh WebAssembly instance and `SignalsRuntime`, mounts it, performs untimed
setup, resets the marked counters, fires one real event through the DOM double,
validates the result, and unmounts outside timing. Warm-ups execute the complete
production workload and are discarded.

The harness deliberately uses a paired measurement design:

- wall-time phases and deterministic JavaScript work come from the ordinary
  production host—the artifact users receive;
- exact Wasm allocator and shared-engine counters come from a same-source
  instrumented companion build;
- the harness rejects a pair unless final runtime state, command counts, opcode
  counts, wire bytes, and decode work are identical.

The companion is diagnostic evidence, not the timing subject. Instrumenting
allocations and engine counters changes optimizer decisions and adds writes to
hot paths, so its durations must not be presented as production timings. CSV
rows record `measurement_design`, both Wasm SHA-256 identities, both build
modes, and protocol/schema versions to keep that distinction reviewable.

Timing columns are integer nanosecond totals across the sample:

- `event_total_ns` brackets the complete synchronous DOM-double event;
- `wasm_event_ns` brackets the real `roc_ui_event` export;
- `command_read_ns` materializes fixed records;
- `command_snapshot_ns` copies string and dynamic buffers for reentrancy;
- `command_execute_ns` is the command-apply duration after subtracting its
  nested read and snapshot phases;
- `event_residual_js_ns` is the total minus those four mutually exclusive
  phases.

The runner rejects missing or duplicated required phases and rejects nested
time greater than the event total. Compilation, instantiation, mounting, setup,
validation, unmounting, CSV output, and profiler collection are outside the
marked interval.

Durations, action work, wire work, allocation traffic, retained deltas, and
engine counters are summed across fresh iterations. Peak allocation fields are
the maximum observed iteration. Live/before/after gauges and committed page
counts must agree across the fresh diagnostic instances or the sample is
rejected; they are reported once rather than added together.

Interpret timings together with the work columns: fixed record/string/dynamic
wire bytes, every opcode count, decode counts and bytes, copied buffers and
bytes, materialized record objects, live runtime registries, committed Wasm
pages, exact Roc/host allocator traffic and peaks, retained deltas, and shared
engine counters. Linear-memory pages are committed capacity; allocator live
bytes are requested live storage inside that capacity. They are different
questions and should not be added together.

For a before/after comparison, keep the machine, Node/V8, Roc compiler, host
mode, app mode, fixture, case options, and run ordering fixed:

```sh
git switch baseline
python3 scripts/test.py wasm-bench --roc-bin /path/to/roc > before.csv

git switch candidate
python3 scripts/test.py wasm-bench --roc-bin /path/to/roc > after.csv
```

Compare only rows whose recorded environment and build identity are compatible.
Report every sample, then calculate median and range per action or command from
the original integer totals. Alternate baseline/candidate runs when thermal or
frequency drift is material. Do not claim a change smaller than the observed
run-to-run spread, and reject a speedup whose work counters or final behavior
changed unexpectedly.

### V8 CPU and heap investigation

Profilers are separate investigative modes and are never baseline samples:

```sh
node --cpu-prof scripts/browser/run_wasm_benchmarks.mjs \
  --production .test-out/wasm-benchmark/js-framework-production.wasm \
  --production-only \
  --case update_10k --warmups 1 --iterations 5 --samples 1 > /dev/null

node --heap-prof scripts/browser/run_wasm_benchmarks.mjs \
  --production .test-out/wasm-benchmark/js-framework-production.wasm \
  --production-only \
  --case create_1k --warmups 1 --iterations 5 --samples 1 > /dev/null
```

Run the documented `python3 ... wasm-bench --keep-output` command once first so
the two Wasm files exist. CPU/heap-profiler runs add substantial work and their
wall times are not comparable with unprofiled CSV. `--production-only` keeps
the diagnostic companion out of the profile and labels any emitted row as a
profile run; it is not accepted for baseline evidence. Use the profiles to
explain deterministic allocation/copy changes already visible in ordinary
paired rows.

For retained-growth investigation, repeat complete fresh-instance workloads and
force collection only between checkpoints:

```sh
node --expose-gc scripts/browser/run_wasm_retained_growth.mjs \
  .test-out/wasm-benchmark/js-framework-production.wasm \
  update_10k 100 10 > retained.csv
```

The output records `heap_used`, `external`, `array_buffers`, and RSS after
forced-GC checkpoints. Treat them as V8/process capacity gauges, not as
allocations caused by one event. Exact Wasm live/peak and retained-delta
counters remain the allocation authority; a process gauge is evidence only of
a plateau or continuing trend.

## Separate setup from the measured operation

Place `(mark-metrics)` immediately before the action being measured:

```scheme
(test "replace all 1,000 rows"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (mark-metrics)
    (click (role button :name "Create 1,000 rows"))
    (expect-visible (test-id "row-2000"))))
```

Actions before the marker establish state but are excluded from native timing.
Assertions after the action validate the result and are also untimed.

The benchmark process still executes setup and teardown. System-wide tools such
as `perf stat` and `perf record` therefore observe them, and allocation metrics
for setup-bearing cases can include cumulative host activity. Prefer a create
case when isolating process-wide costs, or compare profiles by call path and
runtime counters rather than treating every sample as action-only.

## Check scaling before micro-optimizing

Measure the same mechanism at two or more sizes. The keyed fixture provides
1,000- and 10,000-row creation cases for this purpose.

If 10x the rows costs close to 100x the time or produces 100x the scan count,
look for an accidental nested scan before changing allocators or packing data.
Common sources are:

- linear membership checks inside a loop;
- scanning all identities or descriptors once per row;
- shifting a growing descriptor table once per inserted or removed row;
- rebuilding global indexes for every local change;
- deduplicating with repeated list searches.

Add or consult runtime counters at the loop that performs the work. A counter
that scales quadratically is stronger evidence than a noisy wall-clock sample.
After changing the algorithm, verify both the counter and elapsed time.

Prefer these shapes for bulk work:

- one reconciliation pass followed by one descriptor splice;
- dense bitsets when IDs are bounded and reasonably compact;
- hash sets or indexed tables for sparse membership;
- direct `(scope, ordinal) -> ID` indexes instead of global identity scans;
- intrusive free lists when a table already owns reusable slots.

Do not replace a small linear scan automatically. Hashing and temporary storage
have fixed costs; retain the simpler representation where the cardinality is
known to stay small.

## Use `perf` with optimized symbols

On Linux, preserve symbols without changing ReleaseFast code generation:

```sh
zig build build-test-hosts \
  -Doptimize=ReleaseFast \
  -Dprofile=true

roc build \
  --target=x64musl \
  --opt=speed \
  --no-cache \
  --output=.test-out/profile/js-framework-benchmark \
  examples/_fixtures/js-framework-benchmark/main.roc
```

Start with hardware counters:

```sh
perf stat -r 7 \
  -e cycles,instructions,cache-references,cache-misses,branches,branch-misses,page-faults \
  -- .test-out/profile/js-framework-benchmark \
  --bench-app \
  --bench-name create_10k \
  --bench-iterations 1 \
  --bench-samples 1 \
  examples/_fixtures/js-framework-benchmark/specs/create_10k.scm
```

Then collect a sampling profile:

```sh
perf record -g -o .test-out/profile/perf.data -- \
  .test-out/profile/js-framework-benchmark \
  --bench-app \
  --bench-name create_10k \
  --bench-iterations 1 \
  --bench-samples 1 \
  examples/_fixtures/js-framework-benchmark/specs/create_10k.scm

perf report -i .test-out/profile/perf.data
perf report -i .test-out/profile/perf.data --no-children
```

The normal report attributes inclusive cost to callers. `--no-children` is
useful for finding the leaf function actually consuming cycles. Inspect both.
When a profile is diffuse, use the runtime counters and scaling ratio to choose
the next hypothesis instead of optimizing the tallest small bar.

## Measure allocations without changing the allocator

The native host deliberately retains Zig's debug allocator and wraps it with
allocation counters. This provides leak detection and per-event telemetry.
Switching to a faster general allocator can hide bookkeeping cost, but it does
not reduce the number of objects, bytes touched, reference-count operations, or
cache misses. Treat an allocator swap as an A/B diagnostic, not as the default
fix.

Focus on:

- `host_allocs_this_event` and `host_alloc_bytes_this_event`;
- retained allocation and byte deltas;
- allocations per row, rendered node, signal record, or emitted patch;
- allocation growth between the 1,000- and 10,000-row cases.

Useful ways to reduce allocation pressure include:

- retain capacity in engine scratch buffers used only during an event;
- batch rows into one temporary descriptor stream;
- store related records contiguously instead of allocating each record;
- use inline storage for genuinely small collections;
- pool objects with identical lifetimes;
- remove duplicated ownership and unnecessary cloned values.

Scratch storage is preferable when temporary data has a clear event-scoped
lifetime and can be cleared while retaining capacity. Arenas are appropriate
only when all contained values share a lifetime. They do not remove required
deinitialization or decrements for Roc values and signal records, so do not use
an arena to blur those ownership boundaries.

## Improve cache efficiency deliberately

Reducing allocations often improves locality before any explicit packing work.
After that, use hardware counters and structure sizes to guide layout changes.

Consider:

- narrower integer IDs when the maximum range is enforced;
- packed flags or bitsets for dense boolean state;
- separating frequently read fields from cold diagnostics and ownership data;
- structure-of-arrays layouts when hot loops consume only a few fields;
- iteration order that matches storage order;
- avoiding pointer-heavy trees for flat indexed relationships.

Do not bit-pack by intuition alone. Record `@sizeOf` and alignment changes,
measure cache misses and cycles, and check that extraction overhead does not
erase the locality benefit. Keep invariants explicit: truncating an ID or count
without a checked bound trades performance for latent corruption.

## Validate every optimization

An engine optimization is complete only when it preserves behavior and improves
the intended workload. At minimum:

```sh
zig build test -Doptimize=ReleaseFast

python3 scripts/spec_driver.py \
  .test-out/profile/js-framework-benchmark \
  examples/_fixtures/js-framework-benchmark/specs \
  --jobs 1 \
  --timeout 120
```

Also run the nearest focused unit tests and any fixtures exercising the changed
engine path. For keyed reconciliation, validate creation, replacement, update,
selection, swapping, removal, append, and clear; a fast result with the wrong
row order or stale event bindings is a regression.

Record in the commit or pull request:

- compiler revision, host optimization mode, machine, and benchmark command;
- median, range, and sample count before and after;
- the profile or counter evidence that motivated the change;
- relevant allocation and scan-count changes;
- correctness commands run;
- remaining hotspots or tradeoffs.

Prefer one evidence-backed optimization per commit when practical. This keeps
performance changes bisectable and makes regressions easier to attribute.
