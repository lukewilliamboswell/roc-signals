# Spike 2 report: retain host scratch across events

**Outcome:** the hypothesis held for repeated events and failed for row construction. The host's own allocations on a repeated event reach 0. The literal `host_allocs_this_event` metric cannot reach 0, because it also counts Roc allocations. Create-1k is essentially unchanged, because 95% of its host allocations are retained objects, not scratch.

**REPORT.md was not written.** The harness refused it ("Subagents should return findings as text"), so I did not route around that. This message is the report. Raw evidence is in the results directory.

- **Worktree:** `/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a22147108dd3cc61d`
- **Branch:** `spike/host-scratch`, at ea1da63d, work uncommitted
- **Commit message:** `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/spike2/COMMIT_MSG.txt`
- **Results directory:** `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/spike2/`
- **Toolchain:** nightly-2026-11-01-48d3369, Zig 0.16.0 from Blueprint (the Zig on PATH is 0.17.0), ReleaseFast

## Gates

| Gate | Result | Key number |
|---|---|---|
| Second identical event, host allocations 0 | **Fail as literally written; pass for host-only allocations** | counter `host_allocs_this_event` 54 → 34, all 34 Roc; host-only 20 → 0. large-each 15 → 11, host-only 4 → 0 |
| Create-1k halved | **Fail** | 103.5 → 103.5 host-only per row, 185.2 → 185.2 on the metric |
| Long-session gauges flat | Pass | 1,000 cycles: allocs = deallocs on both fixtures |
| Retained bytes bounded | Pass, by unit tests | chunks 1 MiB, text 16 KiB |
| Wasm pages flat in `wasm-bench` | **Not run as a long session** | short runs only, 1 page above base |
| Fault suite and fuzz corpora | Pass | 13,534 fault cases, 638 fuzz inputs, 0 regressed |
| Mutation test | Pass | 3 of 3 mutants rejected, control clean |
| Native bench not worse | Pass, no improvement claimed | see Timing |
| No change to derived calls or structural counters | Pass on the 15 probed cases | all native specs pass; every other probed counter is identical to base |

**The site that cannot reach 0:** `rocAllocAt` and `rocReallocAt` in `src/native_host.zig` call `recordHostAlloc`, so the metric is Roc plus host. 54 = 34 + 20. Those 34 belong to spike 1, and the plan's own floor is one box per changed node, so the metric cannot reach 0 without a design change. I kept this gate as failed and added `host_only_allocs_this_event` as a spec metric, which the new specs pin at 0.

## Baseline and premise corrections

The base (ea1da63d) matches the plan's counter figures exactly, so the rebase did not move them.

| Event | Roc | metric | host-only | host retained |
|---|---:|---:|---:|---:|
| counter, 2nd click | 34 | 54 | 20 | 0 |
| counter, 1st click | 34 | 71 | 37 | 17 |
| large-each-64, 2nd Update | 11 | 15 | 4 | 0 |
| create_1k | 81,678 | 185,161 | 103,483 | 127,212 |

- **large-each repeats prune.** The buttons set a mode, so a second identical click is pruned at state equality and exercises no structure. The large-each gate is therefore weak evidence. I added cycle cases (X, Reset, X) to measure real change.
- **Issue #39's 249 per row** is 185.2 per row here.
- **`scripts/test.py gui` does not exist at this base.** `platform-gui` is gone.

## Attribution (taken before any buffer moved)

Files: `attr_base_counter.txt`, `attr_base_le64.txt`, `attr_base_create1k.txt`, `attr_base_cycle_*.txt`.

**Counter second click: 20 host allocations, 4,960 bytes.**

| Site | Count | Bytes | Scope |
|---|---:|---:|---|
| `PreparedStateWrites.prepare` (4 lists) | 4 | 264 | transaction |
| `prepareRoots` plan object | 1 | 2,232 | transaction |
| `prepareChangedActiveSignalRecordIds` | 2 | 168 | transaction |
| `custom_elem_ids` | 1 | 136 | transaction |
| `PreparedRenderSplice.init` journal | 1 | 168 | transaction |
| `TransactionalBatch.preflight` fallback batch | 2 | 284 | transaction, native only |
| `PreparedTextFieldUpdate` next text | 1 | 8 | replaces retained value |
| Native publication touched map and ids | 2 | 104 | transaction, native only |
| `sim_dom.PreparedPublication` lists | 3 | 1,576 | transaction, native only |
| `Element.cloneOwned` children, tag | 2 | 12 | replaces retained value, native only |
| sim DOM text | 1 | 8 | replaces retained value, native only |

**large-each second Update:** 4 allocations, all in `PreparedStateWrites.prepare`.

**create_1k per row:** 103.5 total, 98.1 retained past the event, 5.4 transient.

| Class | Per row | Kept | Transient |
|---|---:|---:|---:|
| Native-only sim DOM | 36.0 | 36.0 | 0 |
| `descriptor_stream` owned values | 21.0 | 21.0 | 0 |
| `render_cache` owned values | 20.0 | 20.0 | 0 |
| `prepareReplacementChildren` | 6.0 | 6.0 | 0 |
| Collection overlays | 5.0 | 4.0 | 1.0 |
| `collectActiveElemDescriptors` | 5.0 | 2.0 | 3.0 |
| `signal_records` | 5.0 | 5.0 | 0 |
| `prepareSparseExternalScopes` | 3.0 | 3.0 | 0 |
| Rows/each transition | 1.1 | 1.0 | 0.1 |
| `collectEachRow` | 1.0 | 0 | 1.0 |
| Everything else | 0.4 | 0.1 | 0.3 |

All of the remainder is deferred to spike 3 (descriptor and row representation). Even removing all 36 sim DOM allocations and all 5.4 transient ones leaves about 62 per row, above the 51.7 needed to halve. In production Wasm the figure is 68.5 per row, because Wasm has no sim DOM.

**Plan candidates:**

| Candidate | Result |
|---|---|
| combine branch list | Ruled out: no attributed site |
| Command staging | Confirmed for the native fallback batch only; Wasm already has a persistent batch |
| `transaction_map`, `PreparedCacheUpdates` | Ruled out: already parked |
| Dirty scheduling | Ruled out on events |
| `boundary.zig` decoding | Ruled out: no attributed site |
| `descriptor_stream` collection | Confirmed on create_1k, but retained, not scratch |

## What changed

- **`src/signals/transaction_scratch.zig` (new).** A chunked store for buffers that die with the transaction, held in `Scratch.transaction`. Bound: 1 MiB retained, whatever the graph size. Growth still returns `OutOfMemory`. Safety builds poison released chunks. Buffers of 4 KiB or more go straight to the host allocator and are never retained.
- **`render_cache`.** Journal containers move to scratch. Values the cache adopts stay on the host allocator. New `TextSpares` keeps text buffers displaced by the latest transaction: 64 entries, 256 bytes each.
- **`sim_dom` and `native_host`.** New `ElementSpares` for displaced elements: 256 elements, 4 KiB each, native only.
- **Docs and specs.** Two `steady_state.scm` specs, the `counter` fixture registered in `examples.toml`, spec golden updated, `contributing.md` and `profiling.md` updated.

**Deviations from the plan, for review:**

1. **One arena instead of per-buffer lists.** It covers the moved buffers with a single bound, so the bound is stated once, not beside each buffer. The design's transaction scratch domain fits it, and Roc values keep their deinit paths.
2. **The fault campaign now passes `--host-exact-scratch`.** Without it, retained capacity would hide most allocations from the sweep. In that mode each allocation gets its own chunk and the spares are off.
3. **`host_retained_*_delta` now excludes this reusable capacity.** Three existing specs pin exact footprints and failed otherwise (`repeated_churn`, `dispose_remount_footprint`, `when-each-dispose`); `event-actions.scm` failed the same way, and it passes in the native suite on the final tree. I changed the gauge instead of the specs, so please review this: it is a semantic change to a metric. The long-session raw counts are the independent check that nothing leaks.

**Fault coverage fell slightly:** 13,660 → 13,534 cases. Continued 750 → 690, refused-then-retried 11,491 → 11,425, skipped_roc unchanged at 1,402. I think most of this is resize attempts the arena absorbs, but I did not account for each coordinate.

## Measurements on the final code

| Event | Roc | metric, before → after | host-only, before → after |
|---|---:|---:|---:|
| counter 1st | 34 | 71 → 55 | 37 → 21 |
| counter 2nd | 34 | 54 → 34 | 20 → **0** |
| large-each Update, Append, Remove, 2nd identical | 11 | 15 → 11 | 4 → **0** |
| large-each Update after a cycle | 828 | 1,271 → 1,002 | 443 → 174 |
| large-each Append after a cycle | 844 | 1,371 → 1,105 | 527 → 261 |
| large-each Remove after a cycle | 784 | 1,273 → 1,011 | 489 → 227 |
| create_1k | 81,678 | 185,161 → 185,153 | 103,483 → 103,475 |
| create_10k | 875,704 | 1,906,247 → 1,906,239 | 1,030,543 → 1,030,535 |
| update_10k | 51,468 | 55,540 → 55,532 | 4,072 → 4,064 |
| clear_10k | 21,945 | 382,227 → 382,221 | 360,282 → 360,276 |
| select_1k | 101 | 133 → 112 | 32 → 11 |
| swap_1k | 628 | 729 → 713 | 101 → 85 |

- **Changing events are not at zero.** Update after a cycle keeps 174: mostly 64 row keys, about 66 sim DOM clones, and transient buffers I did not move. I stopped there because the rest needs per-site ownership review.
- **Long session, 1,000 repeats.** large-each cycles: allocs = deallocs = 2,004,000, with 1,656,000 of them Roc. Counter: 34,010 allocs, 10 above the Roc count, from digit-length changes in the text.
- **Wasm memory.** Pages end 1 page above base on clear_10k and update_10k, and equal on create_1k. Short paired runs only; no long-session Wasm run.

## Timing

**Native bench, total_ns.** 7 alternating pairs under the lock, on the machine shared with the other spikes.

| Case | Base median [range] ms | Candidate median [range] ms |
|---|---|---|
| create_1k | 80.5 [75.3–90.4] | 79.7 [76.0–89.4] |
| create_10k | 1,109 [1,071–1,212] | 1,065 [from about 1,000] |
| update_10k | 65.3 [51.8–70.3] | 56.6 [49.0–68.6] |
| clear_10k | 502 [436–541] | 510 [455–589] |

All four are within spread, so I claim no improvement. For the larger cases this is a count win without a time win, which the plan counts as a negative result. An earlier low-load run of an almost identical build (64 KiB threshold) gave clear_10k 358 vs 363 ms, and instructions rose 1.2% on the build before that, so a very small clear_10k cost may be real.

**Production Wasm, wasm_event per iteration (diagnostic).**

| Case | Base median [range] ms | Candidate median [range] ms |
|---|---|---|
| clear_10k | 372 [336–525] | 327 [310–414] |
| update_10k | 50.4 [40–52] | 55.1 [40–70] |
| create_1k | 106 [93–107] | 103 [92–105] |

Host allocations per iteration on Wasm: clear_10k 287 → 280, update_10k 1,064 → 1,055, create_1k 68,501 → 68,494.

A 64 KiB oversize threshold made Wasm clear_10k about 25% slower. Turning retention off removed that (1,295 ms vs 1,279 on the 3-iteration sample totals), and 4 KiB beat base. I adopted 4 KiB, but only clear_10k was tested across thresholds. I did not find the mechanism.

## Correctness on the final tree

| Suite | Result |
|---|---|
| Zig tests | 636/636 |
| `zig build test` in the worktree, including tidy | Pass |
| Native | 332 pass (330 at base plus 2 new specs) |
| Wasm, browser | Pass |
| `fuzz.py check`, all targets | 638 replayed, 0 regressed |
| Fault | 13,534 pass |
| `roc-check` | Fails at base and on the candidate, both on conduit |
| `roc-test` | Fails on spreadsheet-lite, the known roc-lang/roc#12793 |

- **The suite's `zig` exit 1** comes only from the git lint, because the snapshots have no `.git`. Base fails the same way.
- **`roc-check` is not in your known-blocker list.** Conduit crashed with SIGSEGV (exit 139) at base and hit a compiler `OutOfMemory` on the candidate. The disk also filled at one point, which may be related. This branch changes no Roc source except a compiler-free spec directory. Neither suite was rerun on the final tree, and the last run predates the final Zig-only changes.
- **Fuzz caught a real bug of mine.** I had changed the public allocation contract of `prepareChangedActiveSignalRecordIds`, and 36 propagation inputs failed. The contract is restored, with a private variant for plans.
- **Mutation.** Fault sweep on the counter: control 260/260 pass. Infallible scratch growth: 34 failed. Infallible state-write journal: 2 failed. Text value in scratch: rejected with "Invalid free". Results in `mutation_b5.txt`.

## Things you should know

- **Disk filled during the run.** The root disk hit 100%, which failed one batch of Wasm runs; I reran them. My scratch data was part of the cause, and I deleted the older snapshots and caches. Your other spikes may have seen failures around 19:40.
- **`wasm-bench` can hang.** One candidate `update_10k` run hung with Node idle while holding the shared timing lock. My attempt to kill that process was denied by the permission classifier, so I stopped my own background task with TaskStop, which released it. A base run then timed out the same way (rc 124) and the candidate rerun passed, so this is not specific to this change. All later runs had a 540-second limit.
- **Base difference.** My worktree first started at ccc0524c, not f8ee4748. That evidence is in `appendix-old-base/` and does not count toward any gate.
- **Overlap with spike 1:** none in `host_value_registry.zig`, `host_values.zig`, `erased_calls.zig`, or the ABI. Both spikes touch `engine.zig` and `native_host.zig`, so expect merge work. `design.md` is untouched.
- **Not run:** official browser runner, optional and no checkout here; long-session Wasm; create_10k in Wasm.

## Decisions for the user

1. Accept host-only allocations as the meaning of the zero gate, or keep the literal metric as failed.
2. Accept the `host_retained_*_delta` change.
3. Whether to land this at all. It removes per-event allocations but shows no measured time win, and it adds a new allocator, a new host flag, and a small loss of fault coordinates.
