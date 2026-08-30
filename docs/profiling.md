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

The manifest is also the requirement-to-evidence map for the eventual browser
submission:

| Requirement | Evidence available now | Browser evidence still required |
| --- | --- | --- |
| Nine table operations | One semantic spec and one native optimized benchmark case per operation, including warmup metadata | End-to-end duration around the corresponding real DOM action |
| Ready/run/update/replace/repeated-clear memory | Exact action sequences are validated in the manifest | Browser-process memory after stabilization and collection, using the official runner's metric |
| Startup time | Metric and provider are required by the manifest | Navigation-to-first-render measurement in the built browser artifact |
| Consistently interactive, script bootup, main-thread work | Lighthouse metric entries are required by the manifest | Lighthouse results from the official browser environment |
| Total byte weight | Lighthouse metric entry is required by the manifest | Post-compression transferred bytes for every loaded resource |

The Node/Wasm-controlled measurement path, production-host instrumentation,
and repeatable Node workflow are tracked in
[issue #19](https://github.com/lukewilliamboswell/roc-signals/issues/19). That
issue explicitly excludes real-browser layout, paint, cross-browser memory,
and Lighthouse. The manifest records those later submission requirements but
does not implement or attribute them to issue #19. This avoids duplicating the
Node/Wasm harness while keeping the future browser adapter's completeness
contract explicit.

The manifest contract deliberately does not manufacture browser numbers from
the native host. Native results isolate Roc reducer time, engine application,
work counters, and allocation behavior. DOM layout/paint, JavaScript and Wasm
startup, browser heap accounting, compression, and Lighthouse metrics require a
real production browser build. Contract tests fail if any required operation,
warmup, memory scenario, or audit metric disappears while that adapter is being
built.

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
