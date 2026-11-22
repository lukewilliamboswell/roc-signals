# Reactivity oracle: implementation plan

Working plan for the branch `integration/reactivity-oracle`. It coordinates
agents in worktrees to give the engine an independent reference, the fuzz
targets and probe that check the engine against it, the algorithm seams that
make direct checks possible, and fixes for the defects the exploration found.

This file and `wip/reactivity-oracle/` are working material. They are
committed to the integration branch so agents in worktrees can read them, and
they are deleted in the last commit before the pull request to `main`
(WP-40). Enduring conclusions go to `design.md`, the contributing docs and
module comments, as `AGENTS.md` requires.

## Status

The coordinator keeps this table current. States: `todo`, `active`,
`review`, `merged`, `blocked`.

| WP | Title | Wave | Branch | State | Notes |
|---|---|---|---|---|---|
| WP-00 | Bootstrap the branch | 0 | `integration/reactivity-oracle` | merged | Base `check` failed on the stale 0.6.0 API baseline after 0.7.0 shipped; fixed in dc1b1ad0, then passed. `file-transfer-memory-browser.mjs` fails about half its runs at `e23f5c69` ("progress opt-in changed"): pre-existing, not ours |
| WP-11 | Ingress queue: fix, class, property test | 1 | `wp/oracle-ingress` | merged | runtime.mjs +1612 B Brotli; storage-failure shared bound still counts waiting reports (candidate issue) |
| WP-12 | Lean oracle project and vector format | 1 | `wp/oracle-lean` | merged | Generator `derive`s were injective; WP-14 added halving |
| WP-13 | Tables: `kept` fix and direct targets | 1 | `wp/oracle-tables` | merged | `kept` requires `Writing`; four table vectors dropped |
| WP-14 | Value model in the structure target | 1 | `wp/oracle-value-model` | merged | Merged with WP-16. Both seeded bugs found by the seeded series in under 1 s |
| WP-15 | Design answers and contradictions | 1 | `wp/oracle-design` | merged | Findings F1–F4 in the PR body; F3 (request id exhaustion) is a candidate issue |
| WP-21 | `Sig` module, `Pass` type, schedule table | 1 | `wp/oracle-sig` | merged | Inner-first seeded bug now lives in `Sig.at_state` |
| WP-16 | Walk into a scope the pass remounted | 1 | `wp/oracle-walk-fix` | merged | `fresh` flag on block-choosing sites; `walk_stops` |
| WP-22 | Probe and the checks that read it | 2 | `wp/oracle-probe` | merged | Gates on 11-19 at its tip; six seeded bugs caught; count model rejects the count-only bad traces. `check` passed on integration at ce72e2e6 with 11-19 first on PATH (537/537 native and browser). 0.1.0_RC1 and 11-21 hang checking `PicturePage` (`BUG_TO_INVESTIGATE.md`), 11-19 hangs on `--opt=speed` in check-slow |
| WP-23 | Vector replay and oracle sensitivity | 2 | `wp/oracle-vectors` | merged | `twoPassOuter`, `noJoinKeep`, `pruneWakes` are rejected by count only: WP-22's count model must reject them |
| WP-31 | `Reconcile` planner | 3 | `wp/oracle-reconcile` | todo | After WP-22 |
| WP-32 | `FxCore` and nested effect scopes | 3 | `wp/oracle-fx` | todo | After WP-22 |
| WP-40 | Close out and pull request | 4 | `integration/reactivity-oracle` | todo | |

## 1. Outcome

When this branch merges, the repository has:

1. A reference semantics of a turn, written in Lean 4 under `oracle/`, with a
   Roc port inside the fuzz loop and checked-in vectors that keep the port
   honest.
2. Fuzz properties that compare the real engine with that reference on the
   page, on scopes created and on evaluations, with generators that are
   shown to reach the shapes that matter.
3. A test-only probe of the engine: what each site holds and what a turn did.
4. Pure cores for masks, row reconciliation, the request table and the
   ingress queue, each with a direct target and no engine in the loop.
5. Fixes for three defects and the documentation contradictions listed in
   section 4.

Not in scope: a proof of the engine, Lean in CI, a maintained Quint model,
any app-facing API change, any change to the wire protocol or the work
record, and any exact allocation baseline.

## 2. What exists already

Baseline commit: `e23f5c69` (`origin/main` on 2026-11-22). Line numbers in
this plan refer to that commit.

`wip/reactivity-oracle/` holds the exploration's material:

| Path | What it is | Used by |
|---|---|---|
| `lean-turns/` | Lean 4.36.0 project: kernel AST, 99-line reference (`Spike/Spec.lean`), count and shape reference (`Spike/Expect.lean`), incremental model with ten switchable bugs (`Spike/Incr.lean`), checks, a proof for the static fragment, a trace checker, `vectors/` | WP-12, WP-14, WP-22, WP-23 |
| `lean-table/` | Lean project: `TableCore` and `View` transliterated with Roc line ranges cited, an exhaustive checker with 31 named rules, 28 theorems, six seeded bugs, sample vectors, `roc-probe/` (the `expect`s that confirm the `kept` defect) | WP-12, WP-13, WP-23 |
| `quint/` | `effects.qnt` (14 invariants, 7 seeded bugs), `ingress.qnt` (11 invariants, 3 seeded bugs), counterexample traces | WP-11, WP-32 |
| `patches/value-model.patch` | The reference ported into `fuzz/structure` as "valued" modes, with four directed examples. Built and passed standalone | WP-14 |
| `patches/probe.patch` | `Describe` message, `Probe` in the turn accumulator, trace notes, three checks in `fuzz/structure`. Built and passed standalone | WP-22 |
| `patches/ingress-full-queue-repro.mjs` | Browser test reproducing both ingress poisons, cases A to I | WP-11 |

The patches apply to `e23f5c69`. They are starting points: each was built
standalone only, and neither ran the suite build or `check`.

## 3. Rules for every agent

Read `AGENTS.md`, then `design.md` in full, from your own worktree before
changing anything. The points below are the ones this work is most likely to
break.

- **Design first.** Where a package changes what `design.md` says, change
  `design.md` in the same package and say so in the report. Do not encode a
  disagreement in code alone.
- **Nothing app-facing changes.** New modules (`Sig`, `Reconcile`, `FxCore`)
  are unexposed: listed in `platform/main-fuzz.roc`, never in
  `platform/main.roc`. Probe functions sit beside `Core.settled`.
- **Seams preserve behaviour.** A seam package changes no command, no work
  counter and no allocation count that a spec, the allocation guard
  (`tests/runtime/write-scaling.mjs`) or a soak asserts. Add no exact
  allocation baseline; leak checks and existing guards are the gate.
- **A reference shares no code with what it checks.** A model in a fuzz
  target calls nothing in `Core`, `View`, `Seq` or `TableCore` to compute an
  expectation. App-domain helpers of the generated program may be shared.
- **Seeded bugs are acceptance tests, not a framework.** To accept a target,
  apply each named bug by hand in your worktree, record whether and how fast
  the target finds it, and revert. Never commit an injected bug or a
  mutation harness.
- **No fuzz target is skipped.** Register every new target in
  `scripts/src/Targets.roc`. Run fixed-example replays; campaigns are short
  (`blueprint run fuzz -- --time 120 TARGET`) and local.
- **The repository describes the present.** No "spike", "prototype",
  "previously" or "ported from" in any file outside `wip/`.
- **Comments are written for their reader.** Internal items: invariants,
  ownership, cost, oracle obligations. Read the Roc Style Guide before
  editing Roc.
- **Roc compiler defects** are reported upstream and worked around narrowly,
  with the issue linked beside the workaround and in `design.md`.
- **`roc test` on a module that imports the platform** needs
  `--main=<its main.roc>`.

### Machine limits

One suite build needs up to 16 GiB and this machine has 30 GiB. So:

- During development, build one target standalone:
  `roc build --opt=size fuzz/<target>/main.roc` (about 15 s and 1.2 GB for
  `structure`).
- Suite builds (`blueprint run fuzz-smoke`, `check`, `check-slow`, `fuzz`)
  run one at a time across all agents. Before starting one, take the lock:
  `mkdir /tmp/roc-signals-heavy.lock` (it fails if another agent holds it);
  `rmdir` it when done. If it is held, wait and retry.
- Each worktree builds into its own `.build/`. Browser tests use an
  ephemeral debugging port, so they may run in parallel.

## 4. Decisions

Each has a default this plan proceeds on. The user may override any of them;
a package that depends on one says so.

| ID | Question | Default | Decided by |
|---|---|---|---|
| D1 | Adopt Lean 4 as a second toolchain? | Yes, pinned by `oracle/lean-toolchain` (4.36.0), run by a local Blueprint task, not in CI | User |
| D2 | May a site answer a fourth, test-only message? | Yes: `Describe`, stated in `design.md` as a harness question outside the reactive model, answered on a copy that is dropped | User |
| D3 | What does the evaluation counter (work counter 21) count? | Document what the code does; WP-15 derives it from the code and WP-22's model must match it exactly | WP-15 |
| D4 | In an `also` event, what does the second handler read? | The state after the first handler's writes: writes compose. This matches the engine on every session run | WP-15 |
| D5 | What conservation law do the effect counters obey? | State the law in `design.md` in terms of the existing counters and the live gauge. Change no counter in this branch | WP-15 |
| D6 | What does the ingress bound limit? | Two budgets: at most `MAX_QUEUED` entries waiting, and at most `MAX_QUEUED` entries raised since the runtime last left idle. Total retained is at most twice `MAX_QUEUED`. The drain budget counts only turns for entries queued after the drain began | User, then WP-11 |
| D7 | How is a table from another history of a pure store handled? | `kept` accepts as the cell's own only a table that was already recording when the modifier received it; any other is stored as a whole rewrite. This makes the code do what `design.md` 822–832 already says. Verified in the Lean model before the Roc change | WP-13 |
| D8 | How is the settle sentinel removed? | `Changed` carries `Pass : [Turn(Mask), Check]`; the all-ones mask stops being special | WP-21 |
| D9 | Where do new pure targets build? | A seventh suite root, `FuzzCores.roc`, so they do not join the `structure` build | WP-13 creates it |
| D10 | Is the value model a new target or modes of `structure`? | Modes of `structure`, with the model in `fuzz/structure/Reference.roc`, following `fuzz/markup/Reference.roc` | WP-14 |

If D2 is refused, WP-22 keeps only the turn trace and drops the tree dump;
the checks that need stored masks are then cut, and that is recorded in
`design.md`'s testing section as a known gap.

## 5. Branch and worktree protocol

### Branches

- `integration/reactivity-oracle` is cut from `origin/main` at `e23f5c69`.
- Each package works on `wp/oracle-<slug>`, cut from the integration branch
  at the start of its wave, in a worktree at
  `.claude/worktrees/oracle-<slug>`.
- A package merges into the integration branch with a merge commit. The
  integration branch reaches `main` through one pull request.

### Commits are signed by the user

`commit.gpgsign` is on and the passphrase prompt needs the user's terminal.
An agent never passes `--no-gpg-sign`. Instead:

1. The agent stages its work (`git add`) and writes the commit message to
   `<worktree>/.claude/COMMIT_MSG` (ignored by git).
2. The agent's final report names the worktree and says it is staged.
3. The coordinator asks the user to sign. When the user is at the keyboard,
   `git -C <worktree> commit -F .claude/COMMIT_MSG` opens the prompt on
   their desktop. Otherwise the user runs it with `!`.
4. Merges into the integration branch are signed the same way.

A package may be several commits. The agent then stages and describes them
in order, and the coordinator has each signed in turn.

### Who edits what

The waves are arranged so that two active packages do not work in the same
Roc or JavaScript file, apart from the two small `Core.roc` hunks noted in
the table. `design.md` and `www/content/docs/contributing.md` are
edited by most packages, in different sections; conflicts there are resolved
by the coordinator at merge.

| File | Edited by, in order |
|---|---|
| `platform/Core.roc` | WP-21, then WP-22, then WP-31 and WP-32 (disjoint regions). In Wave 1, WP-13 may touch the generated cell modifier (427–439) and WP-15 the `watch_latest` comment: one small hunk each, merged first, and WP-21 rebases onto them |
| `platform/runtime.mjs`, `platform/SpecRunner.roc` (ingress parts) | WP-11 |
| `platform/TableCore.roc`, `platform/View.roc`, `platform/Seq.roc` | WP-13 |
| `fuzz/structure/*` | WP-14, then WP-22, then WP-23 |
| `tests/apps/effects/*` | WP-32 |
| `scripts/src/Targets.roc`, suite roots, `platform/main-fuzz.roc` | Every package that adds a target or module; one line each, merged by the coordinator |
| `oracle/*` | WP-12, then WP-23 |

### What an agent hands back

A report with: what changed (`git diff --stat` against the wave's base); each
gate command with its real output line; each seeded-bug acceptance with time
to find; design and doc sections changed; anything not done and why; any
compiler obstacle with its exact error. The coordinator copies the measured
numbers into the pull request body, not into any file.

### Coordinator duties

- Run WP-00, then start each wave's agents from the brief template in
  Appendix D.
- After each merge into the integration branch, run `blueprint run check`
  under the heavy lock. A wave is finished when `check` is green on the
  integration branch.
- Keep the status table current.
- Before blaming a failure on new work, check whether it reproduces at
  `e23f5c69`.

## 6. Waves

```
Wave 0   WP-00
Wave 1   WP-11  WP-12  WP-13  WP-14  WP-15  WP-21      (parallel)
Wave 2   WP-22  WP-23                                  (parallel)
Wave 3   WP-31  WP-32                                  (parallel)
Wave 4   WP-40
```

Dependencies: WP-22 needs WP-14 (it edits the same target), WP-15 (D3) and
WP-21 (it adds an arm beside every `Changed` arm). WP-23 needs WP-12, WP-13
and WP-14. WP-31 and WP-32 need WP-22, so that their refactors are checked
by the probe and the value model.

## 7. Work packages

### WP-00: Bootstrap the branch

Owner: coordinator. No agent.

1. `git fetch`, then create `integration/reactivity-oracle` from
   `origin/main`.
2. Commit `wip/` (this file and `wip/reactivity-oracle/`).
3. Run `blueprint run check` and record the result in the status table. Any
   failure at the base is listed there so later packages are not blamed.
4. Confirm the two patches still apply:
   `git apply --check wip/reactivity-oracle/patches/*.patch`.
5. Remove the three exploration worktrees (`agent-ab5e…`, `agent-a535…`,
   `agent-a6a9…`) once the patches are committed. Ask the user first: they
   hold uncommitted work that the patches duplicate.

### WP-11: Ingress queue: fix, class and property test

**Goal.** A full queue of waiting reports never poisons the runtime, the
queue's rules live in one unit with a parameterised bound, and a seeded
property test checks them. The native runner's copy follows the same rules.

**Depends on.** D6.

**Files.** `platform/runtime.mjs` (`dispatch`, `takeIngress`, `takePayload`,
`drainQueue`, `scheduleReports`, `dropReports`, `clearIngress`, about
lines 4438–4658); the ingress model in `platform/SpecRunner.roc` (`reports`,
`pop_input`, `queue_report_in_loop`, `release_reports_in_loop`,
`drain_focus_in_loop`); `tests/runtime/ingress-unit.mjs` (new);
`tests/browser/reports-browser.mjs`; `scripts/src/Targets.roc` (the
`runtime_unit!` script list); `design.md` "Re-entrancy", "Reports and
occurrences" and "Boundedness".

**The defect.** Two variants, both reproduced by
`wip/reactivity-oracle/patches/ingress-full-queue-repro.mjs`:

- *Queue bound.* On an idle full queue, `dispatch` takes the oldest entry,
  appends the new one (the queue is full again), then delivers. Any entry
  raised during that one turn meets `queue.length >= MAX_QUEUED && busy` and
  poisons (runtime.mjs:4489–4523). Cases A, B, E.
- *Turn budget.* `drainQueue` counts every delivered entry, including reports
  that were already waiting. With W waiting and r raised, W + r > 4096
  poisons, in an ordinary frame drain (runtime.mjs:4576–4588). Cases C, G.

**Steps.**

1. Move the repro into `tests/browser/reports-browser.mjs` as failing cases
   A to I, with the expectations D6 implies (A, B, C, E, G must not poison).
2. Extract `export class Ingress` in `runtime.mjs`, following `WorkMonitor`:
   `admit(input, { busy, transitionWaiting })`, `next(...)`, `cancel(source)`,
   `clear()`, `length`, `needsFrame`. No timers, no DOM, no engine. The bound
   is a constructor parameter that defaults to `MAX_QUEUED`. The runtime
   keeps `busy`, delivery and scheduling. This step changes no behaviour;
   the existing browser tests must pass before the next step.
3. Apply D6 inside `Ingress`: count waiting and raised entries separately;
   the drain budget counts only entries queued after the drain began. Keep
   poison for a real feedback loop, and keep its message accurate.
4. Write `tests/runtime/ingress-unit.mjs`: a hand-rolled seeded generator
   (no dependency) drives an `Ingress` with bound 2 and 3 through reports,
   occurrences, replacements, cancels, drains, busy periods and a waiting
   transition, and checks the eleven rules of `quint/ingress.qnt` as
   predicates over the recorded trace: `boundHolds`, `indexSound`, `fifo`,
   `pinned`, `newestBeforeOccurrence`, `occurrencesKept`, `newestReportKept`,
   `deadNeverDelivered`, `idleHoldsOnlyWaitingReports`, `noStrandedReport`,
   `poisonOnlyWhenRunning`. Register it in `runtime_unit!`.
5. Apply the same rule to the native runner's ingress model and its
   `expect`s (near `SpecRunner.roc:7067`), including a re-entrant event
   during the initiating turn, which neither side tests today.
6. Add a differential check: one generated input script replayed through the
   JavaScript `Ingress` and through the Roc runner's model must deliver the
   same sequence. If the Roc model cannot be driven from Node cheaply, emit
   the script and expected deliveries from the JavaScript test as a fixture
   that a Roc `expect` replays; say which was done.
7. Update `design.md`: the two budgets, the retained total, the drain rule,
   rule 6's wording (the runtime queues, then drains the entries ahead), the
   "since the drain" wording (it is join order), the frame drain cut short
   by a view transition, and the exceptions to lines 1542–1543 (CANCEL,
   disconnected targets, poison). Update the Boundedness table.

**Acceptance.**

- Cases A to I behave as D6 says, in headless Chrome.
- The property test passes for 10,000 seeds at bounds 2 and 3, and fails
  when each of the three ingress bugs from `quint/ingress.qnt` (no pin on an
  occurrence, cancel that clears only the index, late pin) is applied by
  hand to `Ingress`.
- Every existing browser and runtime test passes.
- `blueprint run sizes -- --runtime-only` is run and its numbers reported;
  size is recorded, not gated.

**Out of scope.** The worker pool. The hidden-page microtask and DOM
identity checks stay in the runtime, outside `Ingress`.

### WP-12: Lean oracle project and vector format

**Goal.** `oracle/` holds the reference models as maintained Lean projects,
a local Blueprint task builds them and regenerates vectors, and the vector
format is fixed and documented.

**Depends on.** D1.

**Files.** `oracle/turns/`, `oracle/tables/`, `oracle/lean-toolchain`,
`oracle/README.md`; `scripts/oracle.roc`; `Blueprint.roc`;
`www/content/docs/contributing.md`; `design.md` "Testing Architecture".

**Steps.**

1. Move `wip/reactivity-oracle/lean-turns` to `oracle/turns` and
   `lean-table` to `oracle/tables`. Rename namespaces away from "Spike".
   Core Lean and `Std` only; no network dependency.
2. In `oracle/turns`, keep three things apart: the reference (`Spec`,
   `Expect`), the known-bad algorithms (`Incr` with its variants), and the
   proof. State at the top of each file what it is trusted for. `Expect` is
   a second specification and says so.
3. Align the kernel with the Roc generator WP-14 lands: the same node kinds,
   the same selector rules, the same row-key function, restricted to the
   Roc generator's typed levels when emitting vectors. Agree the names with
   WP-14's agent through the coordinator; the Roc `Node` type is the
   authority for what can be generated, Lean for what it means.
4. Fix the vector format, one line-oriented text file per target, as in
   `lean-turns/vectors/directed.trace`: `trace`, `prog`, `page`,
   `step k | leaves | evaluations`, `end`. A click is "the k-th live button
   in document order". Document the grammar in `oracle/README.md`.
5. Emit: `fuzz/structure/vectors.trace` (directed scenarios plus a seeded
   random set within the typed levels, a few hundred lines);
   `fuzz/structure/vectors-bad.trace` (the same programs with observations
   from each known-bad algorithm, labelled by variant);
   `fuzz/table-changes/vectors.txt` and `fuzz/view-follow/vectors.txt` (a
   cover set: one vector per operation kind × record state × `how` × change
   kind). The files are only emitted here; WP-23 wires the replay.
6. `scripts/oracle.roc` and a Blueprint task `oracle`: build both projects,
   run their exhaustive checks at the small scopes the exploration used,
   regenerate every vector file, and fail if a regenerated file differs from
   the checked-in one. Local only; it is not part of `check` and CI does not
   install Lean. If `lake` is absent the task fails with a message naming
   the toolchain file; it never skips silently.
7. Contributing docs: a section on the oracle (what it is, how to run it,
   the rule that a semantic change edits `design.md`, then Lean, then the
   Roc reference, then vectors, in one pull request). `design.md` "Testing
   Architecture": a subsection naming the reference as the statement of a
   turn's meaning and Lean as the side that decides a disagreement.

**Acceptance.**

- `blueprint run oracle` passes on a clean checkout with Lean 4.36.0, and
  fails when a vector file is edited by hand.
- Both proofs build with no `sorry`; `#print axioms` output is recorded.
- The exhaustive table check reproduces the branching-history failure before
  WP-13's fix is mirrored, and none after (step shared with WP-13).

**Out of scope.** Lean in CI. Any proof beyond the two that exist.

### WP-13: Tables: `kept` fix and direct targets

**Goal.** A table from another history can no longer be taken as the cell's
own; `TableCore`, `View` and `Seq` have direct fuzz targets that reach chunk
splits and the changes record.

**Depends on.** D7, D9.

**Files.** `platform/TableCore.roc`, `platform/View.roc`, `platform/Seq.roc`
(only if a target needs a parameter exposed), `platform/Core.roc` only at
the generated cell modifier (lines 427–439) if the fix needs it (tell the
coordinator: WP-21 is editing `Core.roc` in the same wave);
`platform/main-fuzz.roc` (add `TableCore`); `fuzz/table-changes/`,
`fuzz/view-follow/`; `FuzzCores.roc` (new suite root);
`scripts/src/Targets.roc`; `.github/workflows/ci.yml` (shard count);
`design.md` "Tables and views", "Decisions as functions", the settle check.

**The defect.** `kept` (TableCore.roc:219–225) identifies a turn by
`(id, start)`. Every value of one pure `Store` shares the cell's id, and two
histories can reach the same count with different rows. Shortest trace, from
`lean-table/out/none-branching-5t.txt`:

```
start rows=[]
turn 1: (copy kept)                             -- snapshot R
turn 2: |t| t.insert(0,0)
turn 3: |t| t ; (copy kept)                     -- X: rows {0:0}, v=1, start=1
turn 4: take up snapshot R; |t| t.insert(0,1)   -- other history: rows {0:1}, v=1
turn 5: |_| X.put(0,0)
=> record=[(0, was 0)] keyed, but the turn began with rows=[(0,1)]
```

`lean-table/roc-probe/` holds `expect`s that show it on the real code. A
mounted instance has one history and is not affected; `Store.after` and
`Store.read` values are.

**Steps.**

1. Add the failing case as a top-level `expect` over `Store.after` and
   `Store.read`, asserting the safe outcome (`inverse` answers `Rewritten`).
2. Design the fix in the Lean model first
   (`wip/reactivity-oracle/lean-table`, or `oracle/tables` if WP-12 has
   merged). Default (D7): only the table the modifier received, which the
   generated modifier has already put into its recording phase, can be the
   cell's own; a table that enters recording inside the modifier is a
   foreign copy. Re-run the branching exploration: `recordSound`,
   `recordCovers`, `inverseRestores` and `verEqStartMeansUnchanged` must
   hold on branching histories, and all 31 rules on single histories.
   Check what the fix does to the legitimate single-history case of a copy
   kept across a turn that wrote nothing: it becomes a whole rewrite, which
   is what `design.md` 822–832 and the `kept` comment already say.
   If the default cannot be made sound in the model, stop and report the
   options to the coordinator; do not ship a partial fix.
3. Port the fix to Roc. Update the `kept` and `mark` comments and
   `design.md`.
4. `fuzz/table-changes` (pure, in `FuzzCores.roc`): generated modifiers,
   turn boundaries, stored older copies, copies under another cell's id and
   fresh `from_list` tables, against a model that holds a list of rows and
   an explicit snapshot of the turn's start. Properties: the record is the
   exact difference from the start, or `Rewritten`; `inverse` restores the
   start; a stored count never makes `follow` treat a changed table as
   unchanged. Include branching histories.
5. `fuzz/view-follow` (pure, in `FuzzCores.roc`): drive `View.follow` and
   `draw` with `limit: 4` so chunks split and merge, against a filter, sort
   and slice over a plain list (not `View.build`). Properties: absorb equals
   rebuild; rows entered and left are exactly the window differences; a row
   in both windows is not re-created; moves are minimal. Assert coverage of
   `follow.how`: every run of the seeded series reaches `Absorbed` and each
   `Rebuilt` reason, as top-level `expect`s.
6. Document the two unstated facts the model needed, beside the code and in
   `design.md`: a table's stored count can go down within a turn, and "count
   equals start implies the rows are the turn's first rows" is what keeps
   `follow`'s unchanged shortcut sound.
7. Fix `design.md` 5350 ("the table's changes cleared": the code retains
   them, as 950–961 says) and 5273–5278 as the fix requires.

**Acceptance.**

- The new `expect` fails before the fix and passes after.
- Applied by hand to `TableCore`/`View` and reverted, each of the six bugs in
  `lean-table` (latest earlier row recorded; no clear at the first modifier;
  `kept` on id only; `kept` on start only; two draws; `absorb` never reports
  reaching the window) is found by a fixed example or a 120 s campaign.
  Record which. The two-draws bug must be caught by a per-turn rule, since
  end-state rules do not see it.
- `fuzz/table-view` and every table spec pass unchanged.
- `blueprint run fuzz-smoke -- table-changes view-follow table-view`.

**Out of scope.** Changing the public `Table` API. A proof about the view.

### WP-14: Value model in the structure target

**Goal.** After every generated click, the engine's page equals what a
reference with local state predicts, and the generator provably produces the
shapes that expose ordering bugs.

**Depends on.** D10. D4 is assumed.

**Files.** `fuzz/structure/FuzzStructureProperty.roc`,
`fuzz/structure/Reference.roc` (new), `fuzz/structure/fuzz-package.roc`;
`design.md` "Fuzzing, walks, soak and contract tests"; contributing docs.

**Starts from.** `patches/value-model.patch`: modes 4 (one valued session)
and 5 (a seeded series of 400), a 93-line model, four directed examples.

**Steps.**

1. Apply the patch. Move the model into `Reference.roc`; it imports nothing
   of the platform. Remove the debug modes 6 and 7.
2. Replace the index shortcut (`chosen_of`: an index of 128 or more reads
   two signals) with real `Node` variants for a `when`, `switch` and `each`
   whose selector reads two signals. Keep within the typed levels; say in
   the header comment what the levels still cannot express.
3. Let a row's item vary under a stable key, so a kept row whose item
   changes is generated. Add key churn biased toward remove-then-reinsert.
4. Bias the generator: a share of events are a two-write button with a
   structural reader of both writes below it, including the two derive
   shapes (`valued-rows-of-outer-derive`, `…-inner-derive`).
5. Shape shares. A pure function tallies the seeded series: clicks that
   write two different states read by one structural reader; clicks that
   dispose a scope holding non-initial state; keys removed and reinserted;
   kept rows whose item changed. Top-level `expect`s require a minimum share
   of each. Choose the minimums from the acceptance test below, not by
   guess. Report the tally through a pure function or `Fuzz.count!`, never
   by crashing.
6. The comparison stays the text nodes in document order plus the number of
   click candidates, and says so in its comment, with what it cannot see
   (attributes, properties, order among non-text nodes).
7. Add an outer-first two-pass directed example beside the inner-first one.
8. Update the target's header comment, the fuzzing paragraph of `design.md`
   (the value model, what it compares, the shape shares) and the
   contributing docs.

**Acceptance.**

- All fixed examples pass against the unmodified engine; `roc test
  fuzz/structure/main.roc` passes.
- The inner-first two-pass bug (three lines: `waits_for_outer` always
  `False`, and the settled inner layer hands the outer writes up) applied by
  hand is found by the **seeded series or a 150 s campaign from an empty
  corpus**, not only by a directed example. The exploration's generator did
  not reach it (36 of 16,000 clicks wrote two states); this is the test that
  the bias in steps 2 to 5 worked.
- A kept row's state reset on a list change, applied by hand in
  `reconcile_rows`, is found the same way.
- `blueprint run fuzz-smoke -- structure`, under the heavy lock.

**Out of scope.** Timers, jobs and effects in valued mode. Evaluation counts
(WP-22).

### WP-15: Design answers and contradictions

**Goal.** `design.md` answers the questions the models raised and no longer
contradicts itself or the code. No code changes, except comments.

**Files.** `design.md`; doc comments in `platform/Core.roc` (`watch_latest`)
and nowhere else. Tell the coordinator the exact comment lines touched, since
WP-21 edits `Core.roc` in this wave.

**Steps.** For each item, read the code, write the sentence, cite the lines
in the report.

1. **D3, the evaluation counter.** From `count_evals` and its call sites,
   state exactly what counter 21 counts: mount evaluations, text holes,
   selectors, list reads (one for a read of two signals), holes of a created
   row, and what it does not (a kept row's unchanged item, buttons). Update
   the `derived_calls_into_roc` row in "Work assertions". WP-22's count
   model is built from this sentence.
2. **D4.** State that handlers composed with `also` see earlier handlers'
   writes, and what a `derive` layer in that environment holds at that
   point.
3. **D5.** State the conservation law the effect counters obey, naming what
   `delivered` and `stale` each include (terminal results, subscription
   messages, delivered follow-ups; late results, dropped follow-ups,
   unresolved reference commands), that a refused request takes an id
   without being issued, that `reparented` counts adoptions, and that a
   subscription its JavaScript ended is counted `delivered` with no
   `CANCEL` (against "retires its id like a cancel", 2890–2891).
4. **Rules implied and not stated.** Add each where it belongs: no scope is
   removed and created again within one turn; a site mounted during a pass
   never waits, so the walk after the pass may enter it; a write to a layer
   the same turn disposes is lost (or is not: decide from the code); the
   order of remove, create, move and text commands within one
   reconciliation.
5. **Contradictions.** 3077–3081 against 1368–1370 (`resource` answers
   refresh at their own site). The `watch_latest` comment (Core.roc about
   2186–2192) against kept requests that outlive a dispose and remount:
   scope the sentence to one site lifetime. `keep_current` across disposal:
   an eligible orphan and the remounted site can both answer; state whether
   that is intended.
6. **Undeclared bounds.** Request ids are 32-bit and never reused; state the
   behaviour at wrap in "Boundedness", or open an issue and link it. An
   orphaned request with no timeout holds an in-flight slot until teardown:
   state it.

**Acceptance.** Each of the above has a sentence in `design.md` with the code
lines that support it listed in the report. `blueprint run site` builds (the
docs are part of the product).

**Out of scope.** Tables (WP-13), ingress (WP-11), the probe's message
(WP-22).

### WP-21: `Sig` module, `Pass` type and the schedule table

**Goal.** Masks and write sets live in one pure module with a direct target;
the settle check's all-ones mask is no longer a legal turn mask's twin; the
three scheduling decisions are one small table.

**Depends on.** D8. This package owns `platform/Core.roc` in Wave 1; rebase
onto WP-13's and WP-15's small hunks when the coordinator merges them.

**Files.** `platform/Sig.roc` (new), `platform/Core.roc`,
`platform/main-fuzz.roc`; `fuzz/masks/` (new, in `FuzzCores.roc`; create the
suite root if WP-13 has not merged, and tell the coordinator);
`scripts/src/Targets.roc`; `design.md` (the read-signature and settle-check
passages, the module list in "Architecture"); `AGENTS.md` ("Preserve one
engine" names the modules that hold engine policy).

**The defect.** `every_layer` (Core.roc:4766) is both the settle check's mask
and a value a turn's signature can equal. `view_inst` (7923–7931) treats that
mask as the settle check: in a turn that wrote the table, `view_check`
reports drift and the site returns before following the table. The other
tests of the sentinel are in `refresh` (5398), `store_inst` (6058),
`each_inst` (7651) and `settle` (7530).

**Steps.**

1. Move the pure functions at Core.roc:4717–4931 (`bit`, `cell_bit`,
   `own_bit`, `above_bits`, `upto`, `Layers`, `layers_*`, `layers_sig`) to
   `Sig.roc`, with their `expect`s. No behaviour change. Build and run the
   structure target's fixed examples.
2. Introduce `Pass : [Turn(Mask), Check]` and make `Changed` carry it. Every
   `mask == every_layer` test becomes a match on `Check`. A turn whose mask
   is all ones now takes the turn path. Remove the comment at 4762–4765 that
   claims the collision is harmless.
3. `Sig.fold_cells` replaces the bit loop in `finish_table_word`.
4. Extract the schedule decisions as pure functions, used by `state_settle`,
   `turn` and `state_walk_on`:
   `at_state : Wrote, U64 -> [Untouched, Waits, Starts({ walk : Wrote })]`,
   `at_root : Wrote -> { pass : [NoPass, Cells(Mask)], walk : Wrote }`,
   `walk_on : Wrote, U64, Bool -> [Further, Ends]`. Top-level `expect`s
   enumerate them over small write sets.
5. `fuzz/masks` (pure): generated sets of layer indices (well past 64) and
   cells against exact sets. Properties: the mask of a union is the union of
   masks; a member's bit is in the mask; `below` and `from` partition the
   layers, with cells only in `below`; the canonical form makes `==` set
   equality; `above_bits(i)` covers every layer below `i` and every cell;
   stripping a site's own layer never drops another read.
6. A regression for the collision: the cheapest honest one. If a turn whose
   mask is all ones cannot be built in a test app within the typed levels,
   test it at the level it can be reached (a `Changed(Turn(all ones))` sent
   to a view site in a top-level `expect`), and say so.

**Acceptance.**

- `git diff` shows no change to any spec or expected counter.
- The allocation guard and `blueprint run spec -- table deep write-scaling
  store` pass.
- `fuzz/masks` finds, within its fixed examples or 120 s, each of: a mask
  that drops a read when an index is 64 or more; `below` that keeps a cell
  it should not; stripping that removes a sibling's bit. Apply by hand,
  revert.
- `blueprint run check` under the heavy lock, since the change touches every
  `Changed` arm.

**Out of scope.** The pass traversal itself, hole refresh and selector sites
stay as they are.

### WP-22: Probe and the checks that read it

**Goal.** A test harness can see what each site holds and what a turn did;
the structure target checks the proof hypotheses and the per-turn rules on
the real engine, including evaluation counts.

**Depends on.** D2, D3; WP-14, WP-15 and WP-21 merged.

**Files.** `platform/Core.roc`; `fuzz/structure/*`; `design.md`
("Sites and messages", "Testing Architecture", the effect channel's
"Observation", "Boundedness"); `AGENTS.md` (the sentence that a site answers
`Fire`, `Changed` and `Dispose`).

**Starts from.** `patches/probe.patch`, rebased onto WP-21's `Pass` type. It
covers holes, `state`, `derive`, `when` and `switch`; other kinds answer
`Opaque`.

**Steps.**

1. Land the mechanism: `Probe : [Quiet, Recording(List(Fact))]` in the turn
   accumulator; `probe_note` at the call it names; `Describe` answered on a
   copy that is dropped; `Core.probe_tree`, `probe_start`, `probe_take`
   beside `settled`. A host instance is always `Quiet`; `settled` runs its
   scratch pass `Quiet`. No host export reaches `probe_start`.
2. Cover the remaining kinds, in this order: `remount_on`, `resource`,
   placeholders, `guard`; rows of `each` and of table views, with
   `RowAt{slot, key text}` and `Evaluated` for row holes; effect sites
   (owned ids, adopted orphans) and the follow-up queue; a table's version,
   start and phase with the view's ordered keys; `last` on `HoleHeld`.
   After this step no site kind answers `Opaque`; a top-level `expect`
   enforces it.
3. The rule for a fact: stored facts are read from the storage the pass
   tests; event facts are noted at the call they name, beside the counter
   they bump. Write this in `design.md` and in the comment on `Fact`.
4. Checks in the structure target, each with its own crash message:
   nothing waits after a turn and the root holds no pending write; each
   child's stored reads cover every mask held below it that names something
   above it (mounted subtrees); no hole or row hole is evaluated twice in a
   turn; a `derive` is recomputed before any reader below it; a pass's mask
   and every joined layer are consistent with the turn's exact write set;
   live node ids equal allocated minus free, and none appears twice.
5. The count and shape model: port `Expect.lean` to
   `fuzz/structure/Reference.roc` (or a sibling module). After every valued
   click: evaluations equal the due set under D3; scopes created and
   disposed equal the reference's; no scope is both removed and created.
   Add the equal-value-write relation: no command, and `dirty_source_roots`
   still rises.
6. Static reads against mounted reads: at every mount assert that the site's
   stored reads are within what the static `rf(depth)` closure gives, for
   each kind that computes both (`state`, `each`, view, `when`, `derive`).
7. `design.md` and `AGENTS.md`: admit `Describe` as a harness question
   outside the reactive model; a probe subsection in the testing
   architecture; bind the probe to the passive-observation sentence;
   state that only a harness may start recording, which is why its growth
   between takes needs no bound.

**Acceptance.**

- With the probe quiet, allocation and reallocation counts over the
  structure target's fixed examples are identical to the commit before this
  package. Report the three-column table (before, quiet, recording).
- Applied by hand and reverted: a joined layer keeps its `Waiting` flag;
  the outermost layer refreshes its block twice; a child's reads lose one
  layer bit; a pruned `derive` still wakes its readers; two passes in either
  order. Each is found by a fixed example or the seeded series. Record which
  check fires. The first two were missed by every check at `e23f5c69`.
- Soak: `blueprint run check-slow` under the heavy lock; live allocations
  stay flat.
- Report native and Wasm size change; recorded, not gated.

**Out of scope.** A `--trace` mode of the native runner and a text format
for external checkers; nothing outside Roc reads the probe yet.

### WP-23: Vector replay and oracle sensitivity

**Goal.** The Roc references are checked against Lean on every `roc test`,
and each oracle is shown to reject known-wrong observations.

**Depends on.** WP-12, WP-13, WP-14 merged.

**Files.** `fuzz/structure/Vectors.roc` (new) and its imports;
`fuzz/table-changes/`, `fuzz/view-follow/`; `oracle/*` (generator
restrictions); contributing docs.

**Steps.**

1. A module that imports `vectors.trace` as text (the
   `fuzz/names/NameCorpus.roc` precedent) and parses it.
2. A top-level `expect` runs the Roc reference alone over every vector: no
   engine. The page at every step must equal the vector's.
3. The same programs as `Fuzz.example`s, so the engine is run on them too.
4. `vectors-bad.trace`: a top-level `expect` requires the comparison to
   reject every labelled trace, and reports which observation rejects it
   (page, shape or count). This tests the oracle, not the engine, and needs
   no engine change.
5. The table vectors, the same way, for `table-changes` and `view-follow`.
6. Make `blueprint run oracle` regenerate exactly these files; a diff fails.

**Acceptance.** Editing one expected page in a vector file makes `roc test`
fail with the trace name and step. Deleting one known-bad label's rejection
makes it fail. `blueprint run oracle` is clean.

### WP-31: `Reconcile` planner

**Goal.** The keep, create, drop and move decisions of `each` are a pure
fold with a direct target; the engine applies its steps.

**Depends on.** WP-22 merged, so the probe, the value model and the count
model check the refactor.

**Files.** `platform/Reconcile.roc` (new), `platform/Core.roc`
(`reconcile`, `reconcile_rows`, `reconcile_general`, `lis_mark`, about
7205–7480), `platform/View.roc` (`longest_run`), `fuzz/reconcile/` (new, in
`FuzzCores.roc`), `platform/main-fuzz.roc`, `design.md`.

**Steps.**

1. First cut, no risk: one shared longest-increasing-run function used by
   `lis_mark` and `View.longest_run`, with its own `expect`s.
2. The planner as a fold over a callback, so no plan list is allocated on
   the prefix, suffix, swapped-ends, pure-insert and pure-remove paths:
   `plan : { old : U64, new : U64, same : U64, U64 -> Bool,
   find : U64 -> [Old(U64), Fresh] }, sink, (sink, Step -> sink) -> sink`
   with `Step : [Keep(old, new), Create(new, before), Drop(old),
   Move(old, before)]`. The engine's sink is its columns and accumulator; a
   test's sink is a list.
3. Measure before committing to the shape. `same` and `find` capture the
   columns while the sink carries them; the comment at Core.roc:7687–7690
   (roc-lang/roc#12846) says that shape can make every later write copy.
   Run the allocation guard and the `each` specs' exact metrics. If a copy
   appears, fall back to `find` over a precomputed list on the general path
   only, leave the fast paths inline, and say so.
4. `fuzz/reconcile` (pure): two generated key lists, up to thousands of
   keys. Properties: applying the steps to the old list gives the new list;
   `Keep` and `Move` occur exactly for keys in both; `Create` and `Drop` are
   the set differences, once each; a duplicate key is refused; moves equal
   kept rows minus the longest increasing run.

**Acceptance.**

- `each_key_hashes`, `each_key_compares`, `rows_*` and the allocation guard
  are unchanged in every spec.
- The structure target (value model, count model, probe checks) and
  `blueprint run check` pass.
- `fuzz/reconcile` finds, applied by hand and reverted: a step applied
  against the new position instead of the old; a kept key reported as
  `Create`; a non-minimal move set.

**Out of scope.** Templates, columns and row creation stay in `Core.roc`.

### WP-32: `FxCore` and nested effect scopes

**Goal.** The in-flight table and the follow-up queue are a state machine
module with a direct target; the effect-channel target covers nested scopes
and states the counter law.

**Depends on.** WP-22 merged; D5 (WP-15).

**Files.** `platform/FxCore.roc` (new), `platform/Core.roc` (the `Fx`
record at about 9030–9065, `fx_admit_progress`, `fx_refuse`, `fx_follow`,
`fx_dispose_by`, `fx_supersede`, `fx_adopt`, `drain`, `Core.result`),
`fuzz/fx-core/` (new, in `FuzzCores.roc`), `tests/apps/effects/*`,
`platform/main-fuzz.roc`, `design.md`.

**Steps.**

1. `FxCore.Life(res)`: `next`, `inner`, `live`, `queue`, `max`, `counts`,
   nested as one field of `Fx`. Functions `admit`, `refuse`, `follow`,
   `give_up`, `adopt`, `arrive`, and the drain stepper
   `next : Life(res), Drain -> [Idle, Skipped(..), Run(..), TooDeep(..),
   TooBroad(..)]`. `Core` turns `Admitted(id)` into the request bytes and
   `cancel` into opcode 14; it keeps the loop and the crash text. Return the
   cap decision once, so `turn_end_later` no longer recomputes it.
2. Measure compiled size before and after (the comment at 9072–9077 says
   each inline field of `Fx` costs code at every site). Recorded, not gated.
3. `fuzz/fx-core` (pure): bytes drive `admit`, `give_up`, `arrive` and
   `next` against a small state machine. Properties from `quint/effects.qnt`
   that need no engine: `capHolds`, `refusalExactlyAtCap`, `fatesAgree`,
   `countersBalance` (the law WP-15 stated), `noOldAnswerToNewRequest`,
   `noRunAfterEnd`; the inferred follow-up depth equals an explicit depth
   tag in the model; the depth and breadth bounds.
4. Extend `tests/apps/effects` and its target: effect sites inside nested
   `when` scopes, mixed policies per site, an orphan whose adopter is later
   disposed. Add to the model the rules that need the engine:
   `onlyKeptOrphans`, `noScopedRunAfterDispose`, `noWriteToRetired`,
   `supersededNeverRuns`, `latestOwnsOnlyCurrent`, and the counter law as a
   stated rule beside model equality. Use the probe's owned and adopted ids
   to check that the table agrees with the sites.
5. Orphans, reparenting and per-site supersession stay typed closures in
   `Core.roc`. Only `layers_below` and `layers_from` are exercised
   separately, through `Sig`.

**Acceptance.**

- The existing effect-channel target passes unchanged before step 4: exact
  command order, eight counters, live ids.
- Applied by hand and reverted, each of the seven bugs in
  `quint/effects.qnt` (reparent a scoped request; supersession that forgets;
  an orphan that writes a remounted state; id reuse; cap off by one; an
  uncounted drop; disposal that keeps the table entry) is found. Record by
  which target.
- `blueprint run check`.

**Out of scope.** Any change to a counter's meaning or to the work record.

### WP-40: Close out and pull request

Owner: coordinator, with one agent for the documentation sweep.

1. Gates on the integration branch, each under the heavy lock:
   `blueprint run check`; `blueprint run check-slow`;
   `blueprint run fuzz -- --time 120` for each new or extended target
   (`structure`, `masks`, `reconcile`, `table-changes`, `view-follow`,
   `fx-core`, the effect-channel target); `blueprint run oracle`;
   `blueprint run site`.
2. Any campaign finding: minimise, add with `Fuzz.saved`, and triage three
   ways. Engine wrong: fix it, and add the case as a Lean vector. Roc
   reference wrong: fix the reference. Lean and the design disagree: a
   `design.md` change.
3. Documentation sweep: `design.md` "Testing Architecture" describes the
   whole arrangement once (reference, vectors, value model, probe, direct
   targets, what each can and cannot see); the contributing docs' fuzzing
   section lists seven suites and the new members; `AGENTS.md` reflects the
   new modules, the fourth message and the probe rule; every new doc comment
   is written for its reader. Search the tree for "spike", "prototype",
   "previously", "legacy".
4. CI: the fuzz shard matrix covers the seventh suite.
5. Delete `wip/`.
6. Pull request to `main`. The body carries: the three defects and their
   fixes; the design changes; every seeded-bug acceptance with time to
   find; allocation, size and build-time numbers; what is not covered.

## 8. Gates

| When | Command | Who |
|---|---|---|
| While developing | `roc build --opt=size fuzz/<t>/main.roc` and the binary's `check`; `roc test` on the target root; `roc fmt --check`; `node tests/runtime/<script>` | Agent |
| Before handing back | `blueprint run fuzz-smoke -- <targets touched>`; `blueprint run spec -- <apps touched>`; for `Core.roc` changes, `blueprint run check` | Agent, under the heavy lock |
| Before handing back | A 300 s campaign (`blueprint run fuzz -- --time 300 <targets>`) on every target the package adds or extends, and on every engine-driving target (`structure`, `table-view`, `startup-placeholders`, `controls`, `fx-channel`) when it changes `Core.roc`; any finding is minimised, saved with `Fuzz.saved`, triaged (engine, reference or design) and fixed or reported | Agent, under the heavy lock |
| After each merge | `blueprint run check` on the integration branch | Coordinator |
| After each wave | The same 300 s campaigns on the integration branch, over every target the wave touched | Coordinator, under the heavy lock |
| Before the pull request | WP-40 step 1 | Coordinator |

A gate that fails is reported with its output. A target that fails to build
has failed. Nothing is skipped because its inputs look unchanged.

## Appendix A: where each rule lands

Rules from the exploration's catalogue, with the package that makes each one
checked. "Now" means a check exists at `e23f5c69`.

| Rule | Checked by | Package |
|---|---|---|
| Every evaluation sees all of the turn's writes | Value model; trace order | WP-14, WP-22 |
| A reader is evaluated at most once per turn; a created node is not updated | Node writes (now); probe trace for holes and rows | WP-22 |
| A `derive` is recomputed before readers below it | Probe trace | WP-22 |
| The pass starts at the outermost write; nothing waits after a turn | Probe tree | WP-22 |
| A layer's bit is carried only in its own subtree | Count model | WP-22 |
| A full pass after a turn emits nothing | Settle check | Now |
| Pruning at observation points; no pruning at writes | Value and count models; equal-write relation | WP-14, WP-22 |
| The page equals a render from the store and live local state | Value model | WP-14 |
| A kept key keeps its row and state; a reinserted key starts again | Value model; `fuzz/reconcile` | WP-14, WP-31 |
| No scope is removed and created in one turn | Count and shape model | WP-22 |
| Declared reads cover descendants' reads; static reads cover mounted reads | Probe tree | WP-22 |
| A mask never drops a read, at any index | `fuzz/masks` | WP-21 |
| A turn's mask is never the settle check | Removed by the `Pass` type | WP-21 |
| Node ids are reused only after disposal | `Dom` oracle (now); probe id invariant | WP-22 |
| A table's changes record is exact; `inverse` restores the turn's start | `fuzz/table-changes`; Lean proof | WP-13 |
| Only the written tables rearm | Settle (now); `Sig.fold_cells` model | WP-21 |
| A view equals filter, sort and window; absorb equals rebuild | `fuzz/table-view` (now); `fuzz/view-follow` at chunk scale | WP-13 |
| A turn changes a view's drawn rows once | `fuzz/view-follow` per-turn rules | WP-13 |
| In-flight never exceeds the cap; refusal exactly at the cap | Effect target (now, flat); `fuzz/fx-core` | WP-32 |
| Every issued id has exactly one fate; the counters balance | `fuzz/fx-core`; effect target | WP-15, WP-32 |
| No result reaches a disposed scoped site; no write to a retired layer | Effect target with nested scopes | WP-32 |
| Follow-up depth and breadth bounds | `fuzz/fx-core` for the stepper; `expect`s and specs for the poison | WP-32 |
| An occurrence follows every earlier report and precedes every later one | `tests/runtime/ingress-unit.mjs` | WP-11 |
| Waiting reports never poison | Browser cases A to I; property test | WP-11 |

Not for a fuzz target: a tie in a view's order and the follow-up bounds end
in a poison, which a target reports as a crash, so they stay as `expect`s
and specs. Equality as an observation contract and poisoning are an app
contract and a host property.

## Appendix B: seeded bugs used for acceptance

Each is applied by hand in a worktree, timed, and reverted. None is
committed.

| Bug | Where applied | Must be found by | Package |
|---|---|---|---|
| Two passes, inner first | `Core.roc`: `waits_for_outer` always `False`; the settled inner layer hands the outer writes up | Value model from generated inputs; count model | WP-14, WP-22 |
| Two passes, outer first | `Core.roc` pass scheduling | Count model; probe once-rule | WP-22 |
| A joined layer keeps its `Waiting` flag | `state_inst` | Probe once-rule | WP-22 |
| The outermost layer refreshes its block twice | `state_settle` | Probe once-rule | WP-22 |
| A child's reads lose a layer bit | A site's child-reads computation | Probe reads rule, at mount | WP-22 |
| A pruned `derive` still wakes its readers | `derive_inst` | Count model | WP-22 |
| A kept row's state is reset | `reconcile_rows` | Value model | WP-14 |
| State kept across remove and reinsert | row removal | Value model | WP-14 |
| A mask drops a read at index 64 or more | `Sig` | `fuzz/masks` | WP-21 |
| Six table bugs | `TableCore`, `View` | `fuzz/table-changes`, `fuzz/view-follow` | WP-13 |
| Three reconcile bugs | `Reconcile` | `fuzz/reconcile` | WP-31 |
| Seven effect bugs | `FxCore`, effect sites | `fuzz/fx-core`, effect target | WP-32 |
| Three ingress bugs | `Ingress` | `ingress-unit.mjs` | WP-11 |

## Appendix C: known limits that remain

- Generated Roc programs nest four layers below the root, with one stateful
  layer inside a row. Depth beyond that is tested only on the pure cores.
- The value model compares text nodes and button counts. Attributes,
  properties and the order of non-text nodes are outside it.
- `Seq`'s chunk code is checked by `fuzz/view-follow` against a list, not
  modelled in Lean.
- Proofs cover the table's changes record and the static fragment of
  propagation, each about a model.
- The hypothesis "a hole's mask covers what its closure reads" is checked
  only for generated programs, whose reads are known.

## Appendix D: agent brief template

```
You are implementing WP-<nn> of wip/reactivity-oracle.md on the branch
wp/oracle-<slug>, in the worktree .claude/worktrees/oracle-<slug>, cut from
integration/reactivity-oracle.

Read, in your worktree, in this order: AGENTS.md; design.md in full;
wip/reactivity-oracle.md sections 3, 4, 5 and your package; the material
your package names under wip/reactivity-oracle/.

Do the package's steps. Meet its acceptance tests and record each result
with the real output. Before handing back, run the 300 s campaigns section 8
names and triage every finding. Stay inside the files your package lists; if you need
another file, stop and say which and why.

Do not commit. Stage your work and write the commit message to
.claude/COMMIT_MSG. Take /tmp/roc-signals-heavy.lock before any suite build
or blueprint check, and release it after.

Hand back the report section 5 describes. Say plainly what you did not do.
```
