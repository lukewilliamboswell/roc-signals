# Spike 1: refcount-shared reads — the hypothesis held

All gates pass except where noted below. One native run on the very last tree state failed only because the disk filled.

- **Worktree:** /home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a7f367a813cf0c931
- **Branch:** spike/shared-reads at ea1da63d. Work is uncommitted in the worktree (10 files, GPG rule).
- **Compiler:** nightly-2026-11-01-48d3369. Host built ReleaseFast.
- **Results directory:** /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/spike1/

**REPORT.md does not exist.** The harness refused the write, saying subagents must return findings as text. This message is the report. I did not route around that refusal. `appendix-old-base/README.md` went in by shell before I hit it.

Files in the results directory:
- `proposed-design.patch` applies cleanly with `git apply --check`
- `COMMIT_MSG.txt`
- `compare-base-final.txt` is the full metric table
- `bench.json`, `final/metrics.json`, `base/metrics.json`
- `step0/` holds the minimal platform, oracle host and app
- `suites-*` hold the suite logs

## Gates

| Gate | Result |
|---|---|
| Compiler check, chosen variant | **Pass** |
| Counter second click: Roc allocs ≤ 6, `retained_alloc_delta` 0 | **Pass:** 2 and 0 |
| No listed metric regresses; `derived_calls_into_roc` and structural counters unchanged | **Pass, with caveats below** |
| `closure_retains == closure_releases` at teardown; ownership and transactions corpora replay; fault passes | **Pass** |
| Native bench not worse than baseline | **Pass, and improved** |
| Rejections still fire; wrong-capability Zig test added | **Pass** |

## Step 0 (compiler check)

Variants A and B both passed on the required nightly: 562 checks, every allocation freed, no invalid free. The oracle poisons freed memory and never reuses it.

- **Targets:** x64musl speed, size and dev, plus wasm32 size. An earlier 544-check matrix also passed on wasm32 speed; that run predates the zero-sized payload.
- **Payloads:** record with heap `Str`, `List(Str)` and tag; `Str`; direct boxed closure; closure in a record; nested box; partly refcounted tag union; scalar; `List(U64)`; zero-sized.
- **Scenarios:** both drop orders, mutation while shared, the unique path, values outliving boxes, self-comparison, and the `box_prepare_update` wrapper shape on shared and unique boxes.
- **Oracle check:** four deliberately broken hosts were all rejected.

There is no compiler defect, so no upstream issue. I chose B, which keeps the host refcount-free.

## Numbers

Baseline is on ea1da63d and matches the plan's 34 / 54 / 12 for the counter. All values below are ReleaseFast host with `--opt=speed`, base → spike.

| Case | Roc allocs | Host allocs | Closure retains |
|---|---|---|---|
| Counter, second click | 34 → 2 | 54 → 22 | 12 (unchanged) |
| Counter, first click | 34 → 2 | 71 → 39 | 12 |
| large-each-08 Update middle | 156 → 82 | 315 → 240 | 39 |
| large-each-08 equality cutoff | 11 → 1 | 15 → 5 | 3 |
| large-each-08 Append | 191 → 107 | 420 → 337 | 60 |
| large-each-08 Remove | 118 → 72 | 308 → 262 | 30 |
| large-each-64 Update middle | 828 → 754 | 1295 → 1221 | 39 |
| large-each-64 Append | 874 → 790 | 1409 → 1325 | 60 |
| large-each-64 Remove | 784 → 738 | 1283 → 1237 | 30 |
| update_10k | 51468 → 23416 | 55540 → 27488 | 9027 |
| select_1k | 101 → 3 | 133 → 35 | 27 |
| swap_1k | 628 → 576 | 729 → 677 | 27 |

Counter `deallocs_this_event` follows allocs, 34 → 2, and host deallocs go 54 → 22. `retained_alloc_delta` and `host_retained_alloc_delta` are 0 on the second click. All 64 runtime metrics were probed.

Native bench: 42 samples per case, 6 interleaved rounds, each batch taken under the timing lock, on an AMD Ryzen 7 9700X with a ReleaseFast host.

| Case | Base median (min–max) | Spike B median (min–max) | Change | Variant A median |
|---|---|---|---|---|
| update_10k | 50.09 ms (46.11–71.23) | 39.50 ms (35.26–53.89) | −21% | 42.38 ms |
| select_1k | 0.385 ms (0.335–0.775) | 0.338 ms (0.309–0.499) | −12% | 0.355 ms |
| swap_1k | 0.854 ms (0.796–1.216) | 0.799 ms (0.697–1.210) | −6% | 0.800 ms |

This is a real timing win, not just a count win, though the ranges overlap on select and swap. Variant A has identical counts and was not faster, so B stands.

## What changed

- `platform-shared/Capability.roc`: the split closure now returns the same box in both fields. Together with the `HostValue.roc` doc comments, that is the whole platform change.
- Hosted signatures, glue and `engine.zig` are untouched, and no Zig runtime logic changed.
- `src/signals/host_value_registry.zig`: doc comments plus the new test `host value registry refuses a shared-read box at the wrong capability before typed access`. It covers inactive frame, capability mismatch and stale handle.
- `src/signals/host_values.zig`: doc comment only.
- `test/fuzzing/fuzz-ownership.zig`: odd edges now run the real shared closure, and a live-count oracle was added.
- large-each budgets go from 200 to 25 per row, in the generator and both specs. Native specs build `--opt=dev`, which is where the 25 comes from (1510 of 1600 at 64 rows).
- large-each-08 gains a cap of 2 allocations on the equality-cutoff event.
- `test/spec-decode.golden` regenerated.

## Guards shown to fail on purpose

- Copying reads restored: both specs fail (11 vs cap 2; 1876 vs cap 1600).
- Registry frame check removed: the new test fails.
- Shared closure missing its retain: **at first the fuzz target did not catch this**, neither on corpus replay nor in a 45-second AFL campaign. Freed bytes still passed the magic check. After the `readPayload` live-count oracle was added, 21 corpus inputs fail on the mutant and the clean tree passes.

## Correctness suites

Base and spike match on every suite below.

| Suite | Base | Spike | Note |
|---|---|---|---|
| zig | pass | pass | final tree |
| fault | pass | pass, 13660 passed, 0 regressed | final tree |
| fuzz check | pass | pass, 638 inputs | final tree |
| wasm | pass | pass | run before the last spec and fuzz edits, which touch neither Wasm nor browser inputs |
| browser | pass | pass | same note as wasm |
| native | pass | pass, 330 passed, 0 regressed | see below |
| roc-check | see below | see below | |
| roc-test | fails | same failures | see below |

- **Native on the final tree failed, environmental.** The last two reruns hit a full disk: `FailedToCreateUniqueTempDir`, and `roc build` exiting 1 or -7 on 37 specs. No spec assertion failed in the output I checked. The 330-pass run was on the same sources apart from the fuzz-only edit, which the native suite does not use.
- **`roc-check` and `roc-test`.** The driver stops at the first failure, so I ran its own check and test paths over all examples on both trees.
  - `conduit` and `spreadsheet-lite` fail on both trees, flipping between exit 139 and 1. That is the known #12793 family and is pre-existing.
  - In `roc check`, the two trees agree except on those same two examples, whose exit codes vary run to run.
  - `two-row-types` `roc test` hit my 300-second timeout, on base and on spike's driver run. It passes on spike from cache, 34 tests.
- **Not run:**
  - `gui`: the platform no longer exists.
  - Official browser runner and `wasm-bench`: optional or diagnostic for this spike.
  - A fresh `roc test` of `two-row-types`.

## Caveats on "no metric regresses"

- Rows retain one fewer allocation each, so removal deltas shrink in magnitude, e.g. −28 → −26. That is an improvement, though it reads as an increase.
- `host_retained_bytes_delta` moved on append: 4625 → 10441 at 8 rows, 34561 → 4905 at 64. These are one-time capacity growth landing at a different event.
- `task-latest-wins` failed its plateau assertion at first, for the same reason: 1728 bytes of one-time growth arrived one cycle later. Per-cycle measurement shows 0 on both trees across the later cycles. I added one warm cycle to the spec and kept the assertion. Please review that edit.

## Design conflict

The implementation contradicts *The split law* as written ("split-and-replace clone", "two independently owned boxes"). The patch proposes a *read law*, a *Boundary discipline* that covers the outer box too, and updates to the `CapabilityHandle` comment and the capability bullet. Variant B honours the literal "host never increments" rule; variant A would not.

**Decision for the user:** whether `proposed-design.patch` lands.

`get_with_split!` and `CapabilitySplit` are now misnomers. Renaming them means a glue change, so I left them.

## Stale plan premises

- The plan's base and compiler are obsolete.
- `platform-gui` is gone, so "both platforms" is now one platform.
- `generate_large_each.py` emits an older spec syntax and lacks the cutoff section, so regenerating would clobber the specs. I changed its budget but hand-edited the specs. This is a separate gap.

## Remaining hotspots

- large-each Update stays at about 12–13 allocations per row, which is row rebuild work rather than reads, so it is spike 3 territory.
- update_10k stays at about 23 allocations per changed row.
- Counter's 22 host allocations are spike 2 territory.

## Environment warning

The disk is at 100%, about 1.3 GB free of 355 GB. Other agents will hit the same failures. I removed my base worktree and scratch binaries. I left `~/.cache/roc` (16 GB) alone because it is yours to decide on.
