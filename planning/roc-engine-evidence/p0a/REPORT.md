## Phase 0a storage probe: recommend CONTINUE to Phase 1, with a different representation than the plan assumed

Everything is in `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p0a/` (referred to as P below). Nothing in the repository was changed or committed, and nothing was filed. `git status` is clean, and I deleted the two `.test-out` runs I created.

### Answer to the central risk
**Erasing each site as a record of closures copies the whole column on every update.** That representation fails the kill condition. Two other representations stay in place and both pass the gates:

| Representation (probe P/probe/main.roc) | Update one row, 1k / 10k / 100k rows |
|---|---|
| A. Erased site: a record of closures capturing `List(Row)`, rebuilt on change | 2 allocs; 40,061 / 400,061 / 4,000,061 B. **Copies the column every time** (same on nightlies 10-23 and 11-01) |
| B. Hand-written union `[Bench(List(Row)), Todos(List(Todo))]` in State | 1 alloc, 45 B at every size (in place) |
| C. **Static composition, no erasure:** `Both(a, b)` of `EachSite(item, msg)` leaves, dispatched with `where` clauses | 1 alloc, 45 B at every size (in place) |

The full engine is built on **C**. It needs no code generation: the app's site set is an inferred nested generic type, and dispatch resolves at compile time. This replaces the plan's "erase once per site". The union fallback (B) also works but would need code generation. What C costs and what it must still answer:
- The site tree's type is static. Conditional children, nested `each` and dynamic site sets need type-level encodings such as `Maybe(site)`, or sites whose rows contain sites. This is the Phase 0b and Phase 2 question.
- Dispatching to site k is O(depth).

### Engine built (pure Roc, no effects)
`P/engine/Engine.roc` (generic core), `P/engine/Bench.roc` (benchmark app plus a todo site with a different row type), `P/engine/main.roc` (roc-fuzz target).

- **Storage:** each `EachSite` keeps:
  - one slot list of `[Live({item, key, text, cls, dirty}), Free]`;
  - an `order` list;
  - a free list;
  - an open-addressing U64 key index with backward-shift delete;
  - a keyed selector (`sel_key`).

  The row description is built once per site. Handlers receive the row key at fire time: node id → slot → key.
- **Semantics:**
  - Rank order: rank 1 is per-row label and class, rank 2 is the per-site count, rank 3 is a cross-site summary. Each rank settles across all sites before the next.
  - Equality pruning at the source (equal item write), at derivations (label/class/count/summary), and on selection.
  - A dirty list deduplicated by per-row bits.
  - A duplicate key crashes ("duplicate key"); a key change on write crashes.
- **Command encoding:** one `List(U8)`, little endian:
  - `1 CREATE node parent key:u64 class:u8 text`
  - `2 TEXT node text`
  - `3 CLASS node u8`
  - `4 MOVE node before`
  - `5 REMOVE node`
  - `6 CLEAR parent`

  Strings are u32 length + bytes. Node id is `site<<24 | slot+1`.
- **Known O(n) step:** removing one row scans `order` and memmoves it, the same as Solid's splice. Everything else on the sparse paths is O(1).

### Gates (roc-fuzz exact baselines accepted on nightly 11-01; 11-03 reproduces them exactly)

| Gate | Result | Pass? |
|---|---|---|
| Create, allocations per row | 1k: 87 calls (0.087/row); 10k: 401 (0.040); 100k: 3,277 (0.033). Only long labels (over 23 bytes) and buffer growth allocate | Yes (limit 3) |
| Create, bytes per row, 10k vs 1k | 480.3 vs 478.4 B/row, ratio 1.004 (100k: 367) | Yes (limit 1.25x) |
| Sparse ops, allocs/bytes at 1k = 10k = 100k | update-one 1/72; select 1/72; select-other 0/0; select-same 0/0; swap 0/0; remove 1/72; touch (derived prune) 0/0; relabel-equal (source prune) 0/0; todo-toggle on site 2: 2/144 | Yes, identical at all sizes |
| Update every 10th | 37 / 293 / 2,785 allocs (about 0.28 per changed row): proportional to the changed set, not to row count | Yes |
| Append 1k | 10k and 100k identical (36 allocs, 137,784 B) | Yes |
| Clear | 1 alloc / 72 B; frees 106 / 628 / 5,707 (the heap labels) | Yes |
| Site-2 update, no bytes proportional to rows | 144 B at all sizes | Yes |
| Mutation tests (each in a fresh copy) | All 5 caught (below) | Yes |

Mutations:
- **Derived prune broken:** caught by the DOM oracle ("TEXT command did not change the text").
- **Source prune broken:** caught by the `Count("eval-r1")` trace rule.
- **Dedup broken** (always push, and process clean rows): caught by `Count` on the `UpdateTwice` sequence.
- **Rank order swapped:** caught by `Before("eval-r1","eval-r2")`. This needed a new `UpdateAndAdd` message. With single-change messages the `Before` rule was vacuous, and the mutation first passed 133k sequences.
- **Selection prune broken:** caught in exploration.

Oracle: a separate list-recomputing reference model plus an independent decoder that replays the command stream into a simulated DOM. They are compared after every step on keys, labels, classes, order, counts and summary. Trace rules run per step: exact `Count` of rank-1 derivations, `Forbidden` evaluation of unchanged rows, `Before` for r1 < r2 < r3, and r3 evaluated at most once. The generator decodes bytes into 20 operation kinds, including handler fires.

Exploration found one real bug: a U64 underflow in the index's backward-shift delete. It is fixed and kept as a saved example (`regressions/index-backshift-wrap.bin`). After the fix, 321,788 executions passed.

### Timing (native, --opt=speed, apply only, under the timing lock, n=11, ms)

| Case | nightly 11-01, median (range) | nightly 11-03, median (range) |
|---|---|---|
| create-1k | 0.098 (0.097–0.244) | 0.102 (0.100–0.232) |
| create-10k | 0.965 (0.962–1.265) | 1.012 (1.007–1.287) |
| update every 10th, 10k | 0.086 (0.084–0.090) | 0.085 (0.084–0.106) |
| select / swap / remove, 10k | under 0.001 | under 0.001 |
| append 1k to 10k | 0.091 (0.090–0.125) | 0.095 (0.094–0.151) |
| clear 11k | 0.024 (0.024–0.026) | 0.025 (0.024–0.025) |

Current engine on the same machine: the js-framework-benchmark fixture with the ReleaseFast host on 11-01, n=7, dispatch = roc + apply, ms:

| Case | Dispatch median (range) | Apply median |
|---|---|---|
| create_1k | 68.6 (67.2–83.8) | 54.9 |
| create_10k | 955.7 (936–1145) | 755.7 |
| update_10k | 44.6 (43.9–47.6) | |
| select_1k | 0.046 | |
| swap_1k | 0.474 | |
| remove_1k | 0.324 | |
| append_1k_to_10k | 141.6 | |
| clear_10k | 332.7 | |

`scripts/test.py bench` itself failed on this nightly: building the onboarding-wizard example exited with code 2 after printing warnings. So I built and ran the fixture by hand with `P/run-current-bench.sh`.

These are not equivalent workloads. The probe emits one templated CREATE per row and has no real element tree, no JavaScript application step and no general signals. Still, about 3 orders of magnitude on create-10k leaves very large headroom for Phase 1.

### Ownership hazards found (each made a measured operation copy its whole column)
1. **Erased closure captures always copy** (representation A). Draft upstream issue text, not filed:
   > *Title:* Updating a list captured by a closure copies the list even when the closure value is uniquely owned.
   > *Repro:* `Site := [Site({ set : U64, Str -> Site })]`; `make = |rows| Site({ set: |i, l| make(rows.set(i, l) ?? rows) })`. Calling `set` on a uniquely owned `Site` requests 40·N bytes per call (N = list length) on nightlies 2026-10-23 and 2026-11-01. The same data in a tag union or a record updates in place.
   > *Expected:* when the closure value is uniquely owned and consumed by the call, its captures could be moved out. Otherwise, document that erasure via captured state is copy-on-write.
   >
   > Full source: P/probe/main.roc, rep 0 versus reps 1 and 3.
2. **A value consumed in one match or if branch and kept or borrowed in another was copied.** Workaround: branch only on scalars and rebuild the record once (`Engine.summarize`, `apply`).
3. **Reading a field of a record that stays alive shares the field.** `taken.list.set` after `taken = list.replace(...)` copied. Destructure instead.
4. **The closures passed to one higher-order function influence each other's ownership.** One closure, `|s,m,c| if s.len() > 998 consume(s) else {site: s, ...}`, made every other closure passed to `on_left` copy the column. It only shows when the message is not a compile-time constant. I could not reduce this to a small standalone repro (two attempts are in P/repro-msg). The in-tree reproducer is the mode-9 probes in P/engine/main.roc: `upd6` (copies 88 B per row) versus `upd2`/`upd5` (in place).

Hazards 2–4 are traps for anyone writing in this style, but all have narrow workarounds. Only exact allocation baselines at three sizes caught them.

### Compiler notes
- roc-fuzz: the local `platform/targets/x64musl/libhost.a` was stale. I rebuilt it from source with zig 0.16 into P/fuzzpf.
- The fuzz platform works with 11-01 and 11-03, and the baselines match exactly across them.
- I did not hit the 11-01 crashes.

### Recommendation
**Continue to Phase 1** using static composition (C) for typed sites. Constraints to carry forward:
- Put site-dispatch and reducer rules in Phase 1 code review: destructure, branch on scalars, and never let one closure conditionally return its site.
- Keep exact allocation ratchets per operation.
- Ask Phase 0b and Phase 2 to show conditional children and nested `each` in the static site type.

Gaps not closed:
- The DOM command set is minimal (one template per row).
- `remove` scans `order` linearly.
- Wasm counts were not checked against native.

### Files (in P)
- `probe/main.roc` and `probe/*baseline*.json`: the representation comparison.
- `engine/`: `Engine.roc`, `Bench.roc`, `main.roc` (fuzz target), `p0a-engine_baseline.json`, `timing.roc`, `regressions/`.
- `baseline-1101.txt`, `timing-1101.txt`, `timing-1103.txt`, `current-bench.csv`: raw numbers.
- `mutate.sh`, `run-current-bench.sh`, `summ.py`, `tstat.py`, `cstat.py`: scripts to rerun or summarise.
- `explore3/`: the passing exploration report.
