# Operation DRY: share host algorithms across types

## Objective

Reduce the Wasm shipped to applications by implementing common host algorithms
once, with small typed adapters supplying runtime metadata or operations.
Preserve typed application APIs, reactive semantics, allocation-failure
containment, and the shared native/Wasm engine.

The hypothesis is that we specialize too much *bookkeeping*: buffer growth,
route planning, capacity reservation, hash-table operations, and transaction
orchestration. Specialize the parts that depend on a type; share the substantial
algorithms that do not. Source deduplication only counts as a size improvement
when the linked artifact actually contains less code.

The comparison with small Solid or Elm applications motivates a substantially
smaller runtime. It does not yet establish a 40 KB target for an equivalent
Signals application. Compare matched applications and the same compression and
included assets. Do not treat today's size as an architectural lower bound or
promise a tenfold reduction from the measurements below.

This file is an implementation plan, not a change to the architecture.
[design.md](../design.md) remains authoritative. Current commands and toolchain
requirements belong in [Contributing](../www/content/docs/contributing.md);
measurement practice belongs in [Profiling](../docs/profiling.md).

## Evidence and its limits

Investigation baseline: Zig 0.16.0 ReleaseSmall host and official Roc
`nightly-2026-09-04-c125b82`, application `--opt=size`, normal final linking.
These are historical measurements to reproduce, not permanent toolchain pins.

| Counter experiment | Raw Wasm | gzip level 9 | Brotli quality 11 |
| --- | ---: | ---: | ---: |
| Original host | 718,913 B | 268,414 B | 209,509 B |
| Shared array-list growth | 698,611 B | 262,698 B | 206,192 B |
| Measured saving | **20,302 B** | **5,716 B** | **3,317 B** |

The prototype replaces typed unmanaged ArrayList growth with a thin wrapper
calling one non-generic helper. The helper takes runtime element size and
alignment and occupies 281 bytes in the inspected host object. It preserves
remap, allocation fallback, live-element copying, and failure ownership.
Focused failure/alignment tests, ten counter increments, unmount, and zero
retained host-value checks pass. Performance and full engine coverage have not
been established.

The prototype patched a private copy of Zig's standard library. That proves a
code-generation opportunity; it is **not** the production integration strategy.
Do not require an installed toolchain patch or vendor the whole standard library.

The named counter build also contains:

| Candidate family | Visible bodies | Combined body bytes |
| --- | ---: | ---: |
| HashMap helpers, 35 map types | 140 | 24,076 |
| ArrayList helpers, 48 list types | 70 | 14,228 |
| Structural commit with early/late callbacks | 4 | 8,194 |
| Three largest single preparation/collection bodies | 3 | 191,905 |

These are attribution figures, not removable-byte estimates. They include
necessary first implementations, exclude inlined work, and come from a named
companion that differs slightly from production. The growth experiment saves
more than the standalone ArrayList total because callers also become smaller.

There is already one `Engine(WasmCtx)` in the browser artifact. It is built
before application item types are known and uses runtime signal/element tags
and opaque retained values. This operation does not replace one engine per
application type; those copies do not exist.

Temporary evidence is under `.test-out/size-investigation/type-sharing-audit/`:
`README.md`, `probe/report.md`, `probe/array-list.patch`,
`inventory/README.md`, and `architecture.md`. These ignored files may be absent
in another checkout. Stage 0 must establish maintained reproductions rather
than make future work depend on these artifacts or their absolute paths.

### Near-term savings and rollout expectations

A subsequent combined probe applies shared array-list growth and the seven
smaller host sorts together through the normal production build pipeline:

| Application | Original raw → combined raw | Original gzip → combined gzip | gzip saving |
| --- | --- | --- | ---: |
| Counter | 718,913 → 664,404 B | 268,414 → 248,589 B | 19,825 B (7.4%) |
| Recipe scaler | 1,276,901 → 1,222,306 B | 442,428 → 422,699 B | 19,729 B (4.5%) |

This is a measured combined result, not the sum of separate experiments. Both
artifacts mount; the counter also passes ten increments and teardown checks.
Sorting changes still need the ordering and performance validation described
below. The temporary reproduction is in
`.test-out/size-investigation/combined-host/`.

Use **about 20 KB gzip** as the current evidence-backed near-term opportunity
for shared growth plus the separately scoped sorting change. Stage 1 sharing
alone accounts for about 5.7 KB gzip in its isolated counter probe. Further
route, reservation, hashmap, and orchestration savings are unmeasured; do not
turn their body inventories into promised rollout savings. Prioritize later
work using the new profiles after each accepted stage.

The upstream runtime experiment offers a separate roughly 16 KB gzip saving
in a scalar-sort fixture, but has not been combined with this host experiment
or established across production collection apps. Do not add it to these
numbers. The large Rows specialization finding identifies additional code to
investigate, not a removable 261 KB budget. No optimization implementation is
landed merely by adding this plan.

## Architectural rules for the implementation

- Keep common algorithms in `src/signals/`, used by both hosts. Heavy functions
  take ordinary runtime parameters; typed factories may use `comptime` to
  construct small immutable operation tables. Verify LLVM does not recreate
  substantial specialized copies. Use a narrow `noinline` boundary only where
  measurements support it; blanket engine `noinline` increased size.
- Runtime metadata describes host-owned storage and operations: lengths,
  capacities, strides, alignments, identities, and exact hash/equality behavior.
  Descriptors are constructed internally, remain paired with their owning
  storage, and require no per-event allocation or registration.
- Retained Roc values remain opaque capability-owned cells. The host must not
  infer layouts, copy Roc payload bytes, or walk nested reference counts.
  Relocating a host container can move its owning handles exactly as the current
  container does; it must not create a second owner. Clone, equality, drop, and
  split-and-replace continue through the edge's capability.
- Preparation may reserve storage but must not publish partial logical state.
  Failure leaves committed values, graph ownership, and command publication
  coherent. Commit remains allocation-free, with its current phase ordering.
- Preserve bounded storage, scope disposal, identity reuse, equality pruning,
  and dependency ordering. Runtime dispatch must not introduce scans to recover
  type or identity, per-element boxing, or worse asymptotic work.
- Public Roc APIs and browser protocol semantics are not intended to change.
  If an implementation requires such a change, stop that approach and document
  the conflict with the design before expanding scope.

## Stage 0 — establish a reproducible size and behavior baseline

**Deliverable:** a maintained size fixture set and measurement command, integrated
with the repository test driver. Suggested new locations are
`scripts/wasm_size.py` and `test/size/`; choose the final layout alongside the
existing test-driver conventions.

- [x] Add small fixtures for static text, a counter, branch replacement, keyed
  row edits, and two distinct row item types. Keep all supported edit operations
  reachable in the collection fixture; an Append-only example cannot establish
  savings for the complete API.
- [x] Include the existing keyed-table benchmark and one maintained collection
  example so reductions are not tuned only to a minimal counter.
- [x] Build normal production Wasm with the repository's selected compiler and
  ReleaseSmall host. Record source revision, source changes, tool versions,
  flags, artifact hashes, raw/code/data sizes, gzip, and Brotli. Fix compression
  implementations as well as levels: earlier Python and Node zlib results
  differed. Keep JS bridge and total delivered-asset sizes visible separately.
- [x] Generate separate named companions for attribution. Record logical helper
  family counts and the largest caller bodies. Keep production artifact size
  authoritative; compiler merging can move code between surviving symbol names.
- [ ] Capture baseline semantics, work counters, allocation traffic, live/peak
  storage, and optimized performance for the affected benchmark cases.
- [x] Add deterministic size regression checks with explicit budgets derived
  from the reproduced baseline. Review budget changes with compiler upgrades;
  do not automatically bless a larger artifact or include profiler builds.

**Exit:** another checkout can reproduce the comparison without ignored spike
files. Explain any difference from the historical numbers before attributing
new savings to a refactor.

**Outcome (2026-09-08):** `scripts/wasm_size.py`, `test/size/` (fixture
manifest, `baseline.json`, `budgets.toml`), and the `size` driver suite exist.
The baseline reproduces the historical recipe-scaler bytes exactly. The
maintained counter fixture is 5,510 raw / 1,934 gzip bytes larger than the
historical guide counter because it renders more markup, not because the
toolchain differs. Work counters and allocation traffic are covered by the
existing native specs; optimized timing for the affected cases is reported per
stage below rather than as a stored artifact.

## Stage 1 — shared buffer growth behind typed storage

**Deliverable:** a small internal storage core, for example
`src/signals/shared_buffer.zig`, with typed list adapters and explicit tests.

- [x] Implement the measured shared growth operation using runtime byte size
  and alignment. Preserve capacity policy, allocator identity, return-address
  accounting, and zero-sized-element handling. Check multiplication overflow.
- [x] Attempt remap first; on refusal allocate the replacement, copy only live
  elements, and release the old backing after success. Publish pointer and
  capacity only after the helper succeeds. Preserve length throughout.
- [x] Give typed storage its own documented interface. Do not reinterpret
  arbitrary std.ArrayList structs by assuming their field layout. Share through
  typed adapters or an internally owned list representation.
- [x] Start with buffers implicated by the inventory and large reservation
  callers. Implement only the list operations their callers need; do not copy
  the entire standard-library API. Migrate a bounded caller group per change.
- [x] Reuse the helper for further host buffers only when their relocation and
  ownership contracts match. Do not use ordinary byte relocation for values
  with internal pointers into their own storage.
- [x] Confirm the linked helper remains shared across element types and inspect
  the large preparation callers for reductions. Re-run the production pipeline,
  rather than comparing only relocatable host objects.

**Tests:** empty and zero-sized lists; initial allocation; successful remap;
remap refusal followed by successful allocation; refusal of both operations;
retry with unchanged old contents; over-aligned elements; arithmetic overflow;
live length smaller than capacity; one-time teardown. Ownership tests must show
that relocating host handles neither clones nor drops their retained values.

**Exit:** a repository-owned implementation produces a measured compressed-size
improvement with behavior and allocator contracts preserved. The historical
20 KB raw saving is a reference, not a guaranteed result for a different facade.
Reject a broad migration if it merely moves specialization into the adapter.

**Outcome (2026-09-08):** `src/signals/shared_buffer.zig` provides one
`noinline` `relocate` body plus a typed `List(T)` adapter. Engine lists cross
module boundaries as typed parameters, so every `std.ArrayListUnmanaged` in
`src/signals/` migrated as one group. Measured with the Stage 0 tooling:

| Fixture | Raw saving | gzip saving | Brotli saving |
| --- | ---: | ---: | ---: |
| static-text | 20,887 B (2.9%) | 5,831 B (2.2%) | 3,543 B |
| counter | 20,887 B (2.9%) | 5,651 B (2.1%) | 3,669 B |
| keyed-row-edits | 20,959 B (1.5%) | 6,152 B (1.3%) | 3,622 B |
| recipe-scaler | 20,973 B (1.6%) | 6,083 B (1.4%) | 3,479 B |

Zig unit tests, the fuzz corpus replay, native specs, the fault campaign, and
wasm mounts pass unchanged. Budgets were ratcheted to this measurement.

## Stage 2 — share prepared sink-route planning

**Primary code:** `src/signals/active_signal_graph.zig`, especially
`prepareDenseRouteAppends`, `PreparedRouteAppends`, and `SmallRouteList`;
the corresponding structural preparation callers in `src/signals/engine.zig`.

- [ ] Move count/group/remap/preflight/merge control flow into one non-generic
  planner for `TextSink`, `BoolSink`, `ChangeSink`, and `StructuralSink`.
- [ ] Retain typed route storage initially. Supply a closed operation table for
  reading an append's record ID, reading existing lengths, preparing typed
  replacements, copying existing routes, appending input, applying, and releasing.
  Batch operations where practical so dispatch is not added for every scalar.
- [ ] Keep the operation table paired with its erased owner. Typed adapters
  recover only the host type they created; callers cannot supply mismatched
  owner/operation pairs. No string registry or runtime type discovery is needed.
- [ ] Preserve empty/single/spilled route storage, initialized-prefix tracking
  on abort, and the ownership transfer from `next` to the committed table and
  from displaced storage to `retired`.
- [ ] Preserve the explicit original-record mapping after retirement. A newly
  occupied dense slot must never inherit the old occupant's routes.
- [ ] Leave source-route remapping separate for the first change; its filtering
  and ID transformation differ from sink routing. Share later only if the common
  algorithm remains clear.

**Tests:** all four route kinds; empty/single/spilled lists; multiple appends to
one record; invalid destinations; retirement and slot reuse; failure at every
allocation; abort before and after partial initialization; allocation-free
commit; disposal after success. Extend existing route tests and structural and
ownership sequence coverage.

**Exit:** one shared planning body, small typed adapters, and a demonstrated
artifact reduction without worse work or ownership behavior. Measure whole
callers because the original planning code is substantially inlined.

The existing planner allocates/scans `final_count` counters. Record this broad
structural-planning cost explicitly; it is not O(changed). Sharing code must not
hide or worsen that design gap. Track the locality repair separately, and do
not claim the complete complexity contract is satisfied while it remains.

## Stage 3 — express repeated capacity reservation as data

**Primary code:** `StagedCollectionCtx.CapacityPlan` and `reserveCounts` in
`src/signals/engine.zig`, plus descriptor-stream reservation helpers.

- [ ] Define a closed reservation description for the uniform host-vector
  cases: which count applies, which storage receives it, and whether it is
  additional or total capacity. Drive these entries with an ordinary runtime
  loop, using the shared storage core where applicable.
- [ ] Keep cumulative totals distinct from this call's added counts. Preserve
  checked u32 index limits and the capture of committed base lengths.
- [ ] Preserve DOM identity growth on actual claims so repeated reuse does not
  inflate retained storage. Publish the new capacity plan only after every
  reservation succeeds.
- [ ] Leave nonuniform preparation steps explicit. Do not turn materialization
  into an unordered loop: static/signal text interleaving, row spans, signal
  roots, event bases, and named indexes have ordered publication semantics.
- [ ] Measure both the reservation function and its callers. Its historical
  15,448-byte body is a useful observation, not a saving estimate.

**Tests:** nested collection reservations; parent entries still outstanding;
overflow at count conversions; allocation failure at each reservation; retry;
identity reuse and memory plateau; unchanged ordering and publication counts.

**Exit:** less emitted reservation/control-flow code, no extra per-update
descriptor allocation, and unchanged phase and capacity guarantees.

## Stage 4 — evaluate shared hash-table operations

This is a separate experiment after earlier results establish the value and
runtime cost of shared storage. A complete custom hashmap is not a prerequisite
for Stages 1–3.

- [ ] Start with a measured costly family over host-owned IDs or pointers.
  Specify runtime entry layout/alignment and exact hash/equality operations;
  keep typed key/value access and ownership at the boundary.
- [ ] Share growth, probing, or rehashing where the byte inventory justifies
  it. Avoid specializing the shared core again through `anytype` contexts or
  compile-time callbacks.
- [ ] Preserve load policy, collision handling, capacity checks, iterator and
  pointer invalidation rules, and failure atomicity. Borrowed string keys must
  keep their current lifetime; adopting a shared table must not invent ownership.
- [ ] Keep application payloads opaque and retain exact identity/key equality.
  Migrate further key families only after the first has useful size and timing
  results. Stop if adapter and dispatch costs erase the benefit.

**Tests:** forced collisions, grow/rehash refusal, remove/reinsert histories,
identity reuse, borrowed-key lifetime, pointer validity at documented boundaries,
and allocator teardown. Use model sequences rather than only isolated inserts.

**Exit:** a measured net improvement on real engine workloads, with no weakening
of expected/amortized lookup bounds or retained-memory behavior.

## Stage 5 — share transaction orchestration

**Primary code:** `PreparedStructuralDownstream.commitAssumeCapacityWithEarlyAndLate`
and its callers in `src/signals/engine.zig`.

- [ ] Extract common publication phases around the differing typed hooks, or
  pass a bounded runtime callback/context pair into one shared implementation.
  Prefer the form with the clearer ordering and smaller measured artifact.
- [ ] Preserve the exact position of source-cache commits, graph publication,
  descriptor replacement, scope/row retirement, and early/late hooks. Treat
  callback context lifetimes as part of the transaction ownership contract.
- [ ] Keep commit allocation-free and externally observable commands atomic.
  Do not introduce a general transaction interpreter or heap-allocated closures.

**Tests:** single branch, single each, multiple eaches, mixed branch/each,
coordinated state writes, nested replacement, and post-commit observer ordering.
Assert ownership and publication order, not just final rendered text.

**Exit:** fewer substantial commit bodies and lower linked size, with identical
publication and observer semantics. Four current bodies total about 8 KB; one
shared implementation and the distinct hooks still need code.

## Validation and adoption gates

Apply these to each stage before migrating the next group of callers:

1. **Correctness:** run focused Zig tests in a safety-enabled build, native
   semantic specs, the applicable fault campaign, and browser boundary checks.
   Preserve command/work counts where behavior is identical. Explain any changed
   internal counter rather than loosening assertions to accept it.
2. **Sequences:** replay existing structural, ownership, propagation, keyed-scope,
   and Rows-transition corpora as applicable. For new/changed oracles, deliberately
   break the relevant invariant and confirm rejection. Minimize new failures and
   retain regressions using the existing fuzz driver.
3. **Size:** compare ordinary ReleaseSmall final artifacts with a fixed compiler
   and compression implementation. Report per-fixture and cumulative results.
   Keep a raw/code breakdown, but gate delivered compressed bytes as well.
   Separate experiments are not additive forecasts.
4. **Performance and memory:** follow the paired workflow in Profiling. Preserve
   production allocator behavior and report repeated samples, median and spread,
   changed-set work, allocation traffic, and peak/retained bytes. Test scaling
   at the existing 1,000/10,000-row sizes before interpreting small speed changes.
   Measure the actual ReleaseSmall shipping configuration as well as the
   documented ReleaseFast diagnostic workflow; do not silently use instrumented
   or ReleaseFast timing as a claim about the size-built artifact.
5. **Adoption:** accept a stage when size improves, semantics remain intact,
   memory bounds hold, and timing shows no repeatable regression beyond the
   measured noise. If there is a repeatable time/space tradeoff, document it and
   make an explicit decision before broadening the migration. Timing remains
   non-gating in CI; deterministic work and size budgets are the automated gates.
6. **Integration:** rebuild both hosts and candidate bundles; validate the exact
   archives and maintained examples through the test driver. Review added public
   Zig doc comments for ownership/failure contracts. No public guide changes are
   needed for an internal refactor unless observable behavior or workflow changes.

Use the current commands from Contributing for `zig`, `native`, `fault`,
`browser`, `wasm`, `bundle`, `bench`, and `wasm-bench`, and the existing
`scripts/fuzz.py` workflow. Complete the full source suite before integration.
No candidate becomes production-ready solely because a counter mounts.

## Sequencing and review units

Stage 0 precedes implementation. Land Stage 1's core and first migration before
broad container replacement. Stage 2 can then proceed as its own reviewable
change. Stage 3 benefits from Stage 1; Stages 4 and 5 remain independently
measured decisions, not mandatory rewrites.

Parallel investigation can cover inventories, fault/semantic coverage, and
separate algorithm prototypes. Use isolated host/platform outputs: every Roc
app links the host already present in its platform directory, so concurrent
builds must not overwrite each other's measurement input.

Each implementation PR should contain the seam's ownership contract, focused
tests, before/after artifacts and sizes, work/memory/performance results, and
the caller migration it validates. Keep changes bisectable. After each stage,
re-profile the remaining code; abandon a later candidate if the evidence no
longer makes it worthwhile.

## Related findings kept separate

- **Roc runtime build policy:** the pinned boxy runtime was built for speed even
  with app `--opt=size`. An isolated relink saved about 79 KB raw/16 KB gzip in a
  scalar-sort app. This is upstream work, not a requirement to patch Roc for
  Operation DRY or a saving in the static engine floor.
- **Roc Rows specialization:** adding even empty `Rows.apply` retained about
  261 KB raw in a controlled fixture; a second item type added substantial code.
  Investigate shared item-independent order/index algorithms separately. Do not
  remove supported edits or move opaque value interpretation into the host.
- **Host sorting:** seven stable-sort substitutions saved about 34 KB raw/14 KB
  gzip in a probe. Ordering and workload validation remain necessary. Repeated
  ownership-depth scans inside a comparator are a separate scaling issue.
- **Arenas:** the graph-plan arena saved about 3 KB raw/404 B gzip. Use arenas
  where lifetimes justify them; do not combine allocator-policy changes with
  code-sharing experiments or assume an arena replaces resource destruction.

## Completion criteria

- [ ] Adopted sharing mechanisms live in the repository and require no compiler
  or installed-standard-library patch.
- [ ] Maintained fixtures demonstrate smaller compressed artifacts across the
  relevant application shapes, with reviewed size budgets preventing regression.
- [ ] Typed boundaries, capabilities, transaction ordering, scope ownership,
  and both hosts' behavior remain covered by semantic, fault, and sequence tests.
- [ ] Optimized measurements show the chosen tradeoffs, including allocation,
  scaling, and retained-memory behavior; unresolved complexity gaps are explicit.
- [ ] Each proposed seam has an evidence-backed outcome: adopted, rejected, or
  deferred with a concrete reason. Broadening a custom container library is not
  itself a success criterion.
- [ ] Report the final whole-artifact reduction against Stage 0, remaining large
  bodies, and the next demonstrated limitation. Do not declare the wider size
  problem solved merely because this plan's individual changes are finished.
