# Allocation spikes: results

Results for `planning/allocation-spikes.md`, run 2026-11-02 on base `ea1da63d`
(head of draft PR 169: `origin/main` plus the nightly upgrade) with
nightly-2026-11-01-48d3369. Evidence is in `planning/allocation-spike-evidence/`;
the code is uncommitted in three worktrees (see the end).

## Answer

**Per-event allocation is not the fundamental flaw.** Shared reads removed almost
all of it on sparse events and made `update_10k` 21% faster. The remaining gap is
bulk construction, and most of that time is engine structural work rather than
allocation: the Roc row builder is 3-5% of native create-10k apply, while render
topology and positions are 28-37%.

**The plan's viability trigger has still fired.** In the plan's words, this is the
honest trigger to revisit the platform's viability, on both conditions:

- The composition canary is not writable: per-row signals, callbacks and
  conditional children all stop at template stage 1.
- Create-10k stays above 3x Solid after templates, at about 5x. This is a
  projection from the old 5.61x browser ratio, not a measurement.

The trigger assumed templates were the main lever, and spike 3 shows they are not.
So it should send the work to the structural costs before anyone decides on
retirement. No structural fix has been tried, and that is the unmeasured question.

## Results by spike

| Spike | Verdict | Counts | Time |
|---|---|---|---|
| 1. Shared reads | **Pass, recommended** | counter 34 to 2 Roc; update_10k 51,468 to 23,416 | update_10k -21%, select_1k -12%, swap_1k -6% (select and swap ranges overlap) |
| 2. Host scratch | **Negative on time; 1 gate failed outright** | Zig allocations on a repeated counter event 20 to 0; create-1k unchanged | no change beyond spread |
| 3. Row anatomy and templates | **Negative on time** | reduced row 38.66 to 23.66 Roc per row; real row cannot use templates | native and Wasm create-10k ranges overlap |
| Canary | **Fail** | only static values compile and run | n/a |

Spike 1 and 2 were never measured together, so their savings cannot be added up.
Their only shared file is `test/spec-decode.golden`.

## Corrected baseline

`host_allocs_this_event` includes Roc allocations. The earlier "54 host
allocations" is 34 Roc plus 20 Zig, and issue 39's 249 per row cannot be read as
Zig allocations.

| Measure | Counter, second click | Create-1k, per row |
|---|---:|---:|
| Roc allocations | 34 | 81.67 |
| Real host allocations | 20 | 103.48 |
| Metric as reported | 54 | 185.15 |
| Closure retains / retained edges | 12 | 60.04 |

## Spike 1: shared reads

All plan gates pass. On the final tree, rerun after the disk was cleared:

| Suite | Result |
|---|---|
| zig | pass |
| native | 330 passed, 0 regressed |
| wasm | 36 passed, 0 regressed |
| browser | pass |
| fault | 13,660 passed, 0 regressed |
| fuzz check | 638 replayed, 0 regressed |
| roc-check | fails on a compiler crash, same as base (below) |
| roc test, per example | 59 pass; conduit and spreadsheet-lite fail, as at base; two-row-types timed out at 570 s fresh (also timed out at 300 s on base), passes from cache |

- The compiler check passed both variants across 562 checks; four deliberately
  broken oracle hosts were rejected.
- The change is in `Capability.roc`: the split closure returns the same box twice.
  Compiled Roc retains, and the host stays refcount-free. Hosted signatures, glue
  and engine logic are untouched.
- The fuzz target first missed a missing-retain mutant. A live-count oracle now
  catches it on 21 corpus inputs.
- `host_retained_bytes_delta` moved on append because one-time capacity growth lands
  on a different event. `task-latest-wins` needed one extra warm cycle for the same
  reason.
- `get_with_split!` and `CapabilitySplit` are now misnomers; renaming changes glue.
- `generate_large_each.py` emits older spec syntax, so specs were hand-edited.

It conflicts with *The split law* in `design.md`, and with the split-and-replace
rule in `AGENTS.md`, which also needs updating if this lands.
`spike1/proposed-design.patch` covers `design.md` only.

## Spike 2: host scratch

| Gate | Result |
|---|---|
| Second identical event, host allocations 0 | Fails on the literal metric (34 remain, all Roc); host-only reaches 0 |
| Create-1k host allocations halved | **Fail**: 103.5 to 103.5 per row |
| Long-session gauges flat | Pass over 1,000 cycles |
| Retained bytes bounded | Pass by unit test: 1 MiB chunks, 16 KiB text |
| Wasm pages flat in long session | Pass: 1,477 base, 1,478 candidate, flat over 2,000 cycles on one instance |
| Fault and fuzz | Pass: 13,534 and 638, 0 regressed |
| Mutation | Pass: 3 of 3 rejected |
| Native bench not worse | Pass, no improvement claimed |
| Derived calls and structural counters unchanged | Pass on 15 probed cases |

- `wasm-bench` makes a fresh instance per iteration and cannot show this gate, so
  `spike2/long_wasm/one_instance.mjs` keeps one instance mounted. The gate sequence is
  1k run, update, select, swap, clear. `update_10k` grows 0.468 pages per cycle on both
  trees because its labels grow by design.
- Create-1k cannot be halved by scratch reuse: 95% of its host allocations are
  retained objects.
- Costs: a new allocator, a new `--host-exact-scratch` flag, a changed meaning for
  `host_retained_*_delta`, and 126 fewer fault coordinates, not fully accounted for.
- Changing events are not at zero: large-each Update after a cycle is 443 to 174.

## Spike 3: row anatomy and templates

- Roc allocations per row: 21.67 reducer, 2 row entry, 6 structure, 9 attrs and keys,
  19 label, 14 selection, 10 events. Capabilities are 12 of 81.67, so B1 was skipped
  by the plan's rule.
- `Ui.each_template` stage 1 covers 15 of 60 row-path Roc allocations and 0 of 60
  retained edges. Commands are byte-identical (429,094).
- Native create-10k apply 760 to 681 ms, Wasm 1,157 to 1,119 ms; ranges overlap in
  both, so both gates fail.
- The browser ratio against Solid is **not measured**. Installing the official runner
  was blocked as external code, so the 5.61x and the 5x projection are still unconfirmed
  at this base. Scripts are ready in `allocation-spike-evidence/browser/` and untested.
  They compare Solid with base, spike 1 and spike 2. Spike 3 cannot enter this run
  because the real benchmark row cannot use templates.
- `wasm`, `browser` and `fuzz check` were rerun on the final tree: 36 passed, pass, and
  638 replayed, 0 regressed.
- Time in create-10k: render topology and positions 28-37%, Rows reducer about 20%,
  kernel, startup and spec parse 15-17%, builder 3-5%. A one-element row still takes
  518 ms at 10k.

Timing here is weaker than in spike 1: load average was 10-37, medians drifted about
15% between runs, and n=5.

## Gaps found along the way

- `PreparedGraphAppend.plannedRecordId` at `src/signals/active_signal_graph.zig:2053`
  ends in a linear scan, making route planning quadratic in new signal records:
  7.9% self time on full-row create-10k. This breaches the complexity rules.
- The fault harness skips allocations under an active capability frame: 570 of 3,730
  coordinates in `fault.scm`, and row collection is unswept.
- Public signatures cannot name a handler because `Node` is not exposed. This also
  affects ordinary components.
- `wasm-bench` can hang with Node idle, on base as well as candidate.
- `roc test --opt=dev` hangs on a top-level `Rows.from_list` constant. Compiler static
  boxes do not exist on this nightly. Both have upstream drafts in the spike 3
  evidence, not filed.

## Compiler failures

`roc-test` fails on `spreadsheet-lite` (roc-lang/roc#12793). `roc-check` crashes on
conduit or spreadsheet-lite, with a segfault or an out-of-memory error that varies
run to run. A clean base export failed 6 of 6 paired runs, and so did both spike
trees (`roccheck-paired.txt`). One earlier base run passed, so the failure is
intermittent, and spike 1's report calling these suites identical was too strong.
Because the driver stops at the first failure, per-example runs by spike 1 are the
evidence that the other examples still check. They are not a substitute for a clean
`roc-check` once the compiler is fixed. Whether the conduit crash is the same defect as #12793 was not checked.

## Open items

These gates remain unmet and were not relaxed:

- Spike 2 create-1k halved: failed.
- Spike 2 literal zero on `host_allocs_this_event`: failed; 34 Roc allocations remain.
- Spike 3 50% fewer retained edges on the benchmark row: failed, 0 of 60 covered.
- Spike 3 native and Wasm create-10k beyond spread: failed.
- Spike 3 browser ratio: not measured, needs the official runner.

Per-spike reports are `allocation-spike-evidence/spike{1,2,3}/REPORT.md` and
`canary/REPORT.md`. Spike 2's REPORT.md predates the long-session Wasm result; the table
above supersedes that row.

## Recommendation

1. Land spike 1 after reviewing the read law, including the `AGENTS.md` wording.
2. Do not land spike 2 as written. If wanted later, take only the transaction scratch
   and re-measure on top of spike 1.
3. Pause issue 39 at stage 1. Do not land `Ui.each_template`.
4. Next: fix `plannedRecordId`, then attack render topology and positions.
5. Set up js-framework-benchmark, then decide on viability from a measured ratio.

## Where the work is

| Spike | Worktree under `.claude/worktrees/` | Commit message |
|---|---|---|
| 1 | `agent-a7f367a813cf0c931` | `allocation-spike-evidence/spike1/COMMIT_MSG.txt` |
| 2 | `agent-a22147108dd3cc61d` | `allocation-spike-evidence/spike2/COMMIT_MSG.txt` |
| 3 | `agent-a9954894a6aa838c9` | `allocation-spike-evidence/spike3/COMMIT_MSG.txt` |

Nothing has been committed, pushed, or posted to issue 39.
