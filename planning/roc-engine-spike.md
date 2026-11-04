# Roc-owned engine with typed sites: spike plan

Goal: find out quickly whether moving the reactive engine into the platform's Roc
code, with typed storage per site, can close most of the gap to SolidJS. Speed of
learning matters more than preserving the current architecture. Work happens on a
branch, and breaking things there is fine.

## The question

The November spikes showed that the remaining cost is per-row machinery, not
allocation on events. The Roc row builder is 3-5% of create-10k; per-edge erasure
(60 retained edges and 81.67 Roc allocations per row) and engine structure are
the rest. The September spikes showed that moving the engine into Roc **without**
changing representation does not help: a Roc-owned runtime with the current API
kept 22-33 allocations per row and requested about 255 MB to mount 1,000 rows.
Their conclusion was that the next experiment must remove erasure upstream.

So the hypothesis is about representation first and location second:

> Every row at one `Ui.each` site has the same type. If the platform's Roc engine
> stores each site as typed columns and builds the row description once per site,
> per-row cost falls to a few allocations and create-10k script time falls by
> several times, with sparse updates no worse than today.

## Architecture under test

**Kept:** pure application API, glitch-free rank-ordered propagation, equality
pruning, construction-site identity, stable keys (duplicates are errors), scopes
that own and dispose structure, and work proportional to the changed set.

**Dropped, as you accepted:**

- Mutation confined to the host. The engine state is Roc data, updated in place
  through unique ownership.
- Prepare-then-commit and allocation-failure recovery. Running out of memory
  traps the instance.
- The host value registry, capabilities and the split law. The host never holds
  Roc values, so none of that machinery is needed.
- One Zig engine shared by hosts.

**Shape:**

- The engine is a **pure Roc module** inside the platform:
  `Engine.apply : State, Input -> (State, Output)`. It holds no effects, so
  roc-fuzz can test it directly.
- The platform's entry points (`ui_init`, event and task entry points in
  `platform-web/main.roc`) call it. The Zig host keeps exactly one opaque
  `Box(State)` and clears its slot before each consuming call. This is the same
  boundary as `sept-2026-roc-runtime-spikes/roc-engine`.
- The host owns only the allocator, event intake, timers and tasks, and command
  delivery.
- Output carries the DOM command stream as one `List(U8)`. JavaScript reads it
  straight from linear memory, with no per-command boundary call.
- **Typed sites (an API change):** a row is described once per site, in terms of
  lenses on the row type rather than a per-row signal. For example:
  `Ui.each(rows, .id, |row| Html.tr([...Html.text(row.field(.label))...]))`,
  where `row` is a site-level accessor, not a value. Handlers receive the row key
  when they fire, instead of capturing it. Components are functions over these
  accessors, so they compose. The engine keeps each site's rows as columns:
  `List(RowState)` plus key index plus DOM node ids.

**The crux.** Sites have different row types, and Roc has no existential types.
The plan erases **once per site**: each site becomes a small record of closures
over its own typed state, rebuilt when the site changes. The open risk is whether
updating state captured inside an erased closure stays in place, or copies the
whole column on every event. Phase 0a tests that first. The fallback, if it
copies: keep site state in the `State` record, typed by a generated or
hand-written per-app union. That needs code generation, so it counts as a partial
failure of the hypothesis.

## Baselines to beat

Measured on ea1da63d with nightly-2026-11-01-48d3369 (see
`allocation-spike-results.md`):

| Measure | Current engine |
|---|---:|
| Roc allocations per row, create | 81.67 |
| Host allocations per row, Wasm | 68.5 |
| Retained edges per row | 60 |
| create-10k native apply | ~760 ms (loaded machine) |
| create-10k production Wasm | ~1,157 ms |
| update_10k native (shared reads applied) | 39.5 ms |
| Wasm pages, 1k run-to-clear session | 1,477 (about 97 MB) |

## Phase 0: kill or continue (2-3 days, two agents in parallel)

### 0a. Storage probe, pure Roc under roc-fuzz

Build only the engine core for one `each` site with the js-framework-benchmark row
shape: id, label, selected class, click handlers. Implement create 1k and 10k,
update every tenth, select, swap, remove one, append 1k, and clear. Include a
second site with a different row type in the same `State`, to exercise the
per-site erasure.

Measure with `Fuzz.measure!` per operation, with exact baselines accepted at 1k,
10k and 100k rows. Use trace rules for semantics: `Count` for derived evaluations
per update, `Forbidden` for work on unchanged rows, and `Before` for rank order.
Use a separate list-recomputing reference model as the oracle.

| Gate | Continue if |
|---|---|
| Create, allocations per row (amortized) | at most 3, ideally just the label `Str` |
| Create, requested bytes per row | 10k within 1.25x of 1k (linear, no copy blow-up) |
| Sparse ops (update, select, swap, remove) | allocations and bytes identical at 1k, 10k, 100k |
| Erased-site update | no requested bytes proportional to row count |
| Mutation test | breaking pruning or deduplication fails the target |

**Kill:** if 0a's erased-site update copies its column and no fix is found within
a day, stop. File an upstream issue with a minimal repro and decide on the union
fallback.

### 0b. API sketch, type-checked

A different agent writes, against stub modules that `roc check` accepts:

- the benchmark row;
- the canary (a packaged row component with independent inputs, an action
  callback, and a conditional child);
- a counter, a form with validation, and a nested `each`.

It records what was awkward, and whether any rule exists that the types don't
show.

**Kill:** the canary needs host ids, hidden static rules, or per-row closures to
express.

## Phase 1: vertical slice in the browser path (about 1 week)

- Work in a new `platform-roc/` directory on a branch, so the current engine
  stays buildable for paired A/B timing on the same commit.
- Build a thin Wasm host from the current one: allocator, event dispatch, and
  command delivery. Adapt the JavaScript runtime to the new command list.
- Port the js-framework-benchmark fixture and make the adapter's `verify.py`
  pass: table structure, keyed moves, removal, replacement.
- Measure with a paired Wasm harness (both engines, same machine, alternating,
  timing lock) plus roc-fuzz counts.

| Gate | Continue | Investigate | Kill |
|---|---|---|---|
| create-10k Wasm script time vs current | at most 25% | 25-50% | over 50% |
| clear-10k vs current | at most 25% | 25-50% | over 50% |
| update, select, swap vs current | not worse beyond spread | | clearly worse |
| Wasm pages after create-10k then clear | report; expect well under current | | |
| Heterogeneous tree (no `each`): mount, sparse update, route-sized subtree swap | at most 50% of current | | not better: the win is tables only |

The heterogeneous tree is a deep tree of distinct components with mixed value
types and no repeated structure, about 2,000 nodes. It tests the general claim:
removing per-node capabilities and the host value registry. Typed columns do not
apply there.

## Phase 2: breadth (about 1 week)

- Add conditional children, nested `each`, components, an HTTP task, timers and
  the canary, run for real.
- Measure dynamic rows (rows with a conditional child) against the current engine.
  These fall off the column fast path, so they must not be worse than today.
- Run long-session plateau checks: pages flat over 2,000 cycles on one instance.
- **Real apps:** port `form-builder`, `kanban-board`, `conduit`, `data-grid` and
  `markdown-editor`. Record mount time, per-event cost for their main
  interactions, Wasm size and startup time on both engines. This is the evidence
  that the result generalises beyond a big table.

## Phase 3: browser ratio

Run the official js-framework-benchmark runner with Solid, the current engine
and the new engine on the same Chrome. This step needs you, because installing
the runner was blocked as external code. Scripts are in
`allocation-spike-evidence/browser/`; add the new adapter beside the others.

**Decision:** separate two outcomes.

- **General win:** the heterogeneous tree and the real apps improve, and the
  table improves. Write the `design.md` replacement, not before.
- **Table-only win:** only repeated structure improves. Then the honest design
  is a typed-column path for `each` inside the existing engine, not a full
  rewrite.

Either way, report Wasm size and startup separately. No engine change fixes those,
and for most apps they are the first gap users notice.

## Testing approach

- The engine is pure, so each operation gets its own roc-fuzz target with exact
  allocation ratchets. A silent copy-on-write cliff shows up as an increase in
  requested bytes, and roc-fuzz requires both increases and reductions to be
  accepted.
- Generators decode bytes into operation sequences (create, update, select, swap,
  remove, append, clear, conditional toggles), checked against the reference
  model. Sequences, not single cases, are where ownership bugs hide.
- Every new oracle gets a deliberate mutation to prove it can fail.
- roc-fuzz runs natively. Confirm once that Wasm allocation counts match native.

## Rules for the agents

- Use the newest available nightly (currently 2026-11-01-48d3369; check for a
  newer one at start).
- Compiler bugs: file upstream the same day with a minimal repro, link the issue
  beside a narrow workaround, and keep going.
- Keep results outside `.test-out`, which the test driver wipes. Use the session
  scratchpad, then copy text evidence into `planning/`.
- Subagents cannot write report files. They return reports as text, and the
  coordinator saves them.
- Time only under the shared timing lock, and keep an eye on disk space: the last
  run filled the root disk.
- Do not commit; commits are GPG signed and need you. Do not edit `design.md` or
  the current platform until the decision.
- Do not build compatibility glue for the old API, a fault campaign, or a GUI
  host. Port only what each phase needs.

## Prior work to start from

`planning/sept-2026-roc-runtime-spikes/` holds the sources and READMEs copied out
of `.test-out`:

- `roc-engine`: closed numeric toy; 9 allocations per update, 224 bytes per row.
  Shows the destructure-and-rebuild pattern that avoids whole-state copies.
- `roc-owned`, `roc-packed`: the current API on a Roc runtime; 22-33 per row.
- `boxed-graph`: copy-on-write cost when the state is shared.
