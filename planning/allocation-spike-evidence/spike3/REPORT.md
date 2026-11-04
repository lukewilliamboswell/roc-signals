# Spike 3 result: negative on time, counts win only on a reduced row

**REPORT.md does not exist.** The harness refused the write ("Subagents should return findings as text, not write report files"). I did not route around that, so this message is the report. ANATOMY.md, CANARY_BRIEF.md and COMMIT_MSG.txt were written.

Base ea1da63d, nightly-2026-11-01-48d3369. Worktree `/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a9954894a6aa838c9`, branch `spike/row-anatomy`, uncommitted. Results: `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/spike3/`, also reachable through the symlink `/tmp/claude-1000/s3`.

## Hypothesis: did not hold

Per-row construction is not what makes create-10k slow.
- **Builder share:** the Roc row builder is about 3 to 5% of native apply (under 80 ms of 1,000 to 1,700 ms). Its `Elem` release costs about the same.
- **Where the time goes:**
  - Render topology and positions take 28 to 37% of samples.
  - Page faults and other kernel, startup and spec-parse work (one unsplit bucket) take 15 to 17%.
  - The Rows reducer takes about 20% of apply.
  - A one-element row still costs 518 ms for 10k rows.
- **Upper bound with no engine change:** one fully shared constant `Elem` removes 15 Roc allocations per row and moves apply by about 9% at 10k and nothing at 1k.

## Baseline
| Metric | Plan and #39 | ea1da63d |
|---|---:|---:|
| Counter click: Roc, host, retains | 34, 54, 12 | 34, 54, 12 |
| Roc allocs per row | ~68 | 81.67 (21.67 Rows reducer, 60 row path) |
| "Host" allocs per row | ~249 | 185.15 reported, 103.48 real |
| Retained edges per row | ~63 | 60.04 |

**Metric correction:** `host_allocs_this_event` includes every Roc allocation, so the 249 in #39 cannot be read as Zig allocations. Production Wasm reports 84.5 Roc and 68.5 host calls per row.

## Part A: complete
ANATOMY.md holds the class table and cycle breakdown. Reconciled per row:
- **Roc:** 21.67 reducer, 2 row entry, 6 bare structure, 9 attrs and keys, 19 label, 14 selection, 10 events. Total 81.67.
- **Retained edges:** 21 label, 25 selection, 14 events. Total 60.

Capabilities are 12 of 81.67 allocations (14.7%), or 20% of the row path.

## B1: skipped by the plan's rule
Capabilities are under a quarter of per-row allocations. Compiler static boxes do not exist on this nightly: 1,000 boxes of a non-capturing lambda allocate 1,000 times. Draft upstream text is in `upstream-static-box.md`, not filed.

## B2: `Ui.each_template`, stage 1 only
- **Design:** a thin wrapper over an unchanged `Ui.each`. The row closure returns `Elem.RowTemplate({ child : Box(Elem), key })`, and the retained closure is the one explicit owner. The engine resolves key placeholders during ordinary row collection.
- **Rejection:** anything non-static panics, and the message names the rule (signal, event and state checked).
- **Coverage of the benchmark row:** 15 of 60 row-path Roc allocations (25%) and 0 of 60 retained edges. The real row cannot use the entry point at all, because label, selection and events are stages 2 and 3. I added no dynamic hole, since that is stage 4. All paired numbers below are a reduced `static_key` row: structure and key placeholders, literal label, no selection, no events.

## Gates
| Gate | Outcome | Numbers |
|---|---|---|
| Builder runs once per site | pass | `row_template_subtrees` 1 for 1,000 rows; per-row mutant caught |
| 50% fewer Roc allocs | pass on reduced row, not applicable to benchmark row | row path 17 to 2; whole event 38.66 to 23.66 (39%); Wasm 41.53 to 24.53 |
| 50% fewer retained edges | fail on benchmark row, by construction | 0 of 60 covered; reduced row was already 0 |
| Commands identical | pass | byte-identical, 429,094 commands in 8 batches (mount, run, add, run, clear, runlots, clear) |
| Native create-10k beyond spread | fail | apply 760 [703..879] to 681 [677..871], n=5, ranges overlap |
| Production Wasm create-10k beyond spread | fail | 1,157 [1,124..1,342] to 1,119 [1,093..1,248], n=5; create-1k did not improve (98 to 108) |
| Browser ratio against Solid | not run | no js-framework-benchmark checkout found, none cloned |
| Update, select, swap work counters | pass | base vs candidate identical; swap identical ordinary vs template; select and update are not expressible on the template row |
| Reorders preserve scopes | pass | 0 instances, 0 scopes created or disposed on reorder |
| Teardown balance | pass with a narrow scope | retains = releases (87 = 87) on a toggle cycle; `retained_alloc_delta` 0; host retained growth same as ordinary and flat after warmup. Full-teardown equality not separately asserted |
| Fault sweep | pass, with a hole | 17,391 passed, 0 regressed; hole below |
| Composition canary | not run, dispatch pending | CANARY_BRIEF.md is ready |

The canary requirements (an action callback and a conditional child) are outside stage 1. Expect it to stop there.

**Fault sweep hole, pre-existing:** the mutation making key-text growth unrecoverable was not caught, even with a key that forces growth inside an event. The harness skips any allocation made under an active capability frame, and row collection runs under one: 570 of 3,730 coordinates in `fault.scm`, including 382 `dupe` calls for descriptor strings. So host allocations during row collection, ordinary rows included, are not swept. The other three mutations were caught (per-row builder, dropped suffix, key escaping the row).

## Correctness suites, candidate against base
- `zig`: pass. The base run shows 623/623 unit tests; its only failure was a tidy git lint from my non-repository copy.
- `native`: 333 passed, 0 regressed.
- `wasm`, `browser`, `fuzz check`: pass, on a snapshot before the final fixture-only edits (fixture, specs, golden). `native`, `fault` and `zig` were rerun after them.
- `fault`: 17,391 passed, 0 regressed.
- Adapter verify: pass.
- `roc-check` fails at conduit (a release package pins the previous nightly) and `roc-test` fails at spreadsheet-lite (#12793), same points as base. Both stop at the first failure, so later examples were not exercised. `roc check` and `roc test` pass on the new fixture directly.
- Size budgets fail at base too, because the nightly more than doubles raw size. The slice adds 2,515 raw bytes and about 1,223 gzip bytes to the benchmark fixture.

No wire change. Metrics schema goes from 6 to 7 for two new counters.

## Projection, derived from the Part A table, not measured
- Stage 1 on the full row, if a row could mix static and dynamic parts: 81.67 to about 66.7 Roc allocations per row.
- Stages 2 and 3 upper bound: the row path falls from 60 to about 26, total about 48. About 24 evaluation boxes remain unless spike 1 removes them.
- Removing the whole builder and release is under 10% of apply. From the old 5.61x that leaves roughly 5x.

**Decision rule:** the browser gate did not run, so this is not a measured ratio. On this projection create-10k stays well above 3x Solid after templates, which is the plan's honest trigger to revisit the platform's viability. The remaining cost is engine structure, not anything inherent to Roc, so I would take the structural work below before stage 2 of #39.

## Adjacent findings, reported and not fixed
1. `PreparedGraphAppend.plannedRecordId` (`src/signals/active_signal_graph.zig:2053`) ends in a linear scan. Route planning is therefore quadratic in new signal records for one transaction: 7.9% self time on full-row create-10k. This breaches *Complexity Discipline* and is independent of templates.
2. The fault harness gap above.
3. `roc test --opt=dev` ran over 7 minutes on a top-level `Rows.from_list` constant before I stopped it. Draft text is in `upstream-roc-test-toplevel-hang.md`, not filed. The fixture now avoids it.

## Limits and what was left out
- The machine was loaded (load average 10 to 37), and full-row native medians drifted by about 15% between runs. All timing ran under the lock, alternating ordinary and template.
- Not done: reference docs, a Wasm-suite fixture, a 10k plateau test, or a fuzz target for templates.
- The row closure still makes one trivial Roc call and two entry boxes per row, and the host still copies every byte per row. So this slice is not the full #39 instantiation model.

`design.md` is untouched. No design conflict, though the site-owned `Box(Elem)` is close enough to "no general descriptor owner" that the API PR should check it.

**Decision for the user:** whether to pause #39 at stage 1 and do the structural and quadratic work first. All paths below are under the results directory.

Files are in the results directory:
- ANATOMY.md
- CANARY_BRIEF.md
- COMMIT_MSG.txt
- upstream-static-box.md
- upstream-roc-test-toplevel-hang.md
- appendix-old-base/ (not evidence for any gate)
- data/alt_table.txt (paired timing)
- data/cmd_identity.txt
- data/workcmp.txt
- data/mutation.log
- data/rejection.log
