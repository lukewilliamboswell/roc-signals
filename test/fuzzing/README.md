# Fuzzing

Seven targets, driven by `scripts/fuzz.py`. Run `python3 scripts/fuzz.py list` for
the one-line summaries and `--help` for the commands.

Every target is a **generator**, not a byte sink. It decodes an arbitrary byte
string into a valid program — a signal graph, an operation sequence, an element
tree, a boundary descriptor — and checks that program against a reference model.
`boundary` is the one exception, and even it generates valid trees alongside the
raw-byte angle, because deep valid records are far too structured to reach by
mutation alone.

That shape is deliberate. The bugs worth searching for here are properties of a
*sequence* rather than of a call: a schedule that evaluates a diamond twice, an
identity reused across a retirement barrier, a refcount that leaks and
double-releases in the same run, a fault landing between two phases of a
transaction. None of those are reachable by feeding bytes to a parser, and all of
them are reachable by generating programs and asserting invariants after every
step.

## What each target owns

| Target | Seam | Reference model |
|---|---|---|
| `propagation` | dependency-ordered, glitch-free propagation and equality cutoffs; the prepared path's refusal and retry under allocation failure | a slow evaluator that recomputes every node from the sources, with exact call and prune counts; a deep snapshot of caches, stamps, metrics, and graph that a refused preparation must leave untouched |
| `keyed-scopes` | keyed-row identity, scope retirement, reuse barriers, disposal | a key list plus a predicted scope id for every intern |
| `rows-transitions` | canonical stable-slot generations, lineage, abort, and retry; `prepareStable`/`prepareInitial` refusal and retry under allocation failure | an ordered array of stable slots, exact keys, and values; a deep snapshot of the committed site, indexes, claims, and row pool that a refused preparation must leave untouched |
| `structural` | collect/prepare/commit atomicity under allocation failure | committed topology derived from the shape and the current list |
| `selectors` | selector memberships, fused keyed selects, and `when` on selected values under structural change | the exact document, the live membership multiset, the selector work counters, and the graph's adjacency and routes, all from the shape and the current `(list, selection)` |
| `sparse-rows` | direct `Rows` deltas against the counted snapshot path: store order, row identity, memberships, structural work bounds | an ordered `(slot, key, item)` model per generation, plus a second world that applies every edit as a snapshot |
| `transactions` | event dispatch, effect results, timer ticks, source results, and coordinated writes as host transactions under allocation failure | the state cells, document text, effect queues, and interval registry after every transaction, and unchanged after every refusal |
| `ownership` | retained-value and callable ownership across erased calls | a ledger of what each capability owns, checked every step |
| `boundary` | boundary schema and event extraction plan parsing | the grammar itself, plus one-rule-broken trees |

Three targets inject allocation failure through `FaultAllocator`: `structural`
at the mount and edit transactions, `keyed-scopes` at the keyed-row
reconciliation, and now `propagation` and `rows-transitions` at their prepared
seams. All follow design.md's *exhaustive fault placement*: because the
allocator is sticky (attempt `N` and every later attempt fail), an ascending
sweep that ends the first time preparation succeeds has covered every position,
and each probe is aborted so the transaction that publishes is the retry. The
common oracle is that a refusal publishes nothing (deep snapshot compare), the
retry lands exactly where an unfaulted run does, commit never reaches the
allocator, and `OutOfMemory` is the only refusal reported.

`descriptor_stream.zig` has no target of its own and does not need one: it is
reached throughout by `structural`, which mounts and edits real element trees
through the engine. Fuzzing it as a standalone byte decoder would mostly generate
states its in-process producer cannot emit. The genuinely untrusted byte
boundaries are `boundary.zig`, which has a target, and the command buffer, which
is decoded in JavaScript and is covered by the browser contract tests.

## The bar: a target must be able to fail

A target that has never rejected a deliberately broken engine is not evidence of
anything. Every target here has been mutation-tested — a defect injected into the
code under test, the corpus replayed, the defect reverted:

| Target | Mutants caught |
|---|---|
| `propagation` | 4 / 4 propagation, 5 / 5 fault injection |
| `rows-transitions` | 5 / 5 fault injection |
| `ownership` | 8 / 8 |
| `keyed-scopes` | 14 / 14 |
| `boundary` | 6 / 6 |
| `selectors` | 6 / 6 |
| `sparse-rows` | 7 / 7 reached (2 equivalent, see below) |
| `structural` | 2 / 2 reached, on the sampled sweep and the distilled corpus |
| `transactions` | 4 / 4 |

The boundary row is why this section exists. Three of those six originally
**survived**: deleting the duplicate-field-name, empty-record, or field-name
UTF-8 check left every oracle satisfied, because the target only ever asserted
that the parser stayed total and that valid trees parsed. Nothing it generated
could tell a parser that enforces those rules from one that does not. The fourth
angle — build a tree that breaks exactly one rule, require exactly that rule's
error — was added in response, and is the reason to mutate rather than to admire
a green run.

`sparse-rows` was built against these defects, one at a time: the direct
path visiting every candidate row (`rows_candidate_rows_visited` bound), a
swap-removal that leaves the moved survivor's membership stale, a stale
sibling delta trusted as direct (its ops are refused or its rows visited
through a path the model says was not taken), an in-place update not marked
changed, a selector membership never unregistered, a membership counter
rewriting the whole site, and the snapshot path re-creating every surviving
row instead of matching keys (identity oracle). Two further mutants were not
caught because nothing in the target's program space reaches them, and both
are equivalent there rather than gaps: ignoring the scope reuse barrier,
which only blocks reuse of a scope retired in the *same* generation while
every row claim precedes retirement in these transactions; and skipping the
early retirement of a direct delta's removed rows, which only matters when a
structural replacement in the same transaction overlaps them. A generated
program that disposes a branch and instantiates rows in one transaction would
reach the first; a nested replacement over a removed row would reach the
second.

The fault-injection rows count defects reachable only through a refused
preparation: a refusal that keeps its row claims or index reservations, an
unwind that leaks the half-built transition or overlay, a refused `combine`
that never drops the child values it already cloned, a preparation that stamps
a record or publishes the owner token or a metrics counter before commit, and a
commit that reaches the allocator. Two of them were caught only by fresh random
inputs at first, which is why `combine-refusal-must-drop-children` and
`fork-abort-claims-reserved-before-preflight` are now in the corpus.

When adding or changing an oracle, mutate the code it is meant to watch and
confirm the target notices. A mutation that no input reaches is a coverage gap
worth closing, not a mutation worth discarding.

The `selectors` row records the six defects it was built against: a retired
membership kept in the registry, a whole-registry visit at commit, staged
memberships not released when a list edit is refused, only the new key's
members dirtied on a selection change, a member dropped while joining an
existing bucket, and every membership staged twice. Two of those needed the
generator to change before the target could see them: the shared-bucket
mutant survived until readers could alias one input record (every select had
read its own `Ref`, so no two memberships ever shared a group), and the
refusal mutant survived until the fault sweep sampled the late third of a
transaction, where selector staging sits. The same rollback line on the branch
replacement path is not caught by this target or by the hand-written sweep
that guards it, which suggests that line never has anything to release; that
is an open observation, not a covered defect.

`selectors` also found one engine defect, kept visible rather than modelled:
a new reader over a live derived signal makes the staged collector re-run the
signal's transform and overwrite its committed cache before commit, and at
some refusal positions the produced value survives the rollback. The target's
refused-edit ledger check skips exactly the edits that trigger it and says so
in `expectRefusedEditLedger`; removing that carve-out is part of the fix.
The structural row was measured after the fault sweep went from exhaustive to
sampled (see the target's header), replaying the 405 committed inputs. Two
mutants in `engine.zig` were caught: dropping the collection release on the
each-generation refusal path (5 inputs, "refusal leaked Roc allocations") and
appending created rows at their parent's end instead of at their anchor (161
inputs, "render tree text order diverges from the model"). The same session
recorded what the corpus does *not* reach, which is the coverage gap the row
above does not show: reversing the stable-slot edit order handed to the Rows
store is reached by 227 inputs and survives, because slot order is
`rows-transitions`' model rather than this target's; and the render layout
plan (`layoutRegion`, `layoutSurvivor`, `apply`), the direct-delta row commit,
and the pure-permutation path are reached by none of the 405 inputs, so
mutants there survive unreached. Every `insertRootsBefore` call the corpus
makes carries at most one root, so row order in the committed corpus is
decided by anchors alone.

## The corpus is the product

`test/fuzzing/corpus/` holds inputs replayed by `fuzz.py check`, which the
pull-request CI job runs. Its README covers what belongs there and how to add
one. `.fuzz-out/` is scratch by contrast: large, machine-specific, and deleted by
`fuzz.py clean`.

Campaigns run in the scheduled `fuzz.yml` workflow rather than on pull requests,
because they are unbounded and too variable to gate a change on. They upload
their crashes and corpora, since both are otherwise lost with the runner.

### Carrying a campaign forward

Every campaign starts from the committed corpus, so whatever a campaign reached
and did not commit is searched for again next time. `fuzz.py distill <target>`
is how a queue becomes corpus: it traces the live `.fuzz-out/<target>` queues
together with the previous distillate under `afl-showmap`, keeps the smallest
set that still reaches every edge (the `afl-cmin` cover, done here because
`afl-cmin` pins a 64 KiB map these targets outgrow), refuses any survivor that
fails replay (a crash belongs in `add` beside its fix, not in a corpus that has
to stay green), and writes the rest as `distilled-<hash>` files. Content-hash names
make a re-distillation of the same queue a no-op diff; hand-named inputs are
never renamed or removed. `--tmin N` additionally shrinks the N largest
survivors with `afl-tmin`, bounded per input by `--tmin-timeout`.

The committed distillate is capped at 400 inputs and 1 MB per target
(`DISTILL_MAX_INPUTS`, `DISTILL_MAX_BYTES` in `fuzz.py`). The corpus is replayed
on every pull request and read by reviewers, so it must stay cheap and
diffable: 400 inputs is a few seconds of replay per target, and past 1 MB a
directory of opaque bytes is no longer something a review can look at. When
the edge cover is larger than the cap, survivors are kept in order of how many
still-uncovered edges each adds, and `distill` reports how many edges the cut
gives up.

### Budgeting a campaign

`fuzz.py run all --time T` gives every target the same T, which is the wrong
split. In a 28-minute campaign `propagation` completed 88 queue cycles,
`rows-transitions` 37 and `keyed-scopes` 5, and then found nothing new, while
`structural` - the only target that drives the whole engine, and where every
real bug so far has come from - completed none. `fuzz.py campaign --time T`
divides one total budget by the weights in `CAMPAIGN_WEIGHTS` instead: every
target gets a floor of two minutes so it re-covers its queue and confirms
nothing regressed, and the rest goes overwhelmingly to `structural`. The
weights live in that one table so changing the split is a one-line review.

## Notes

- `afl-cmin` does not work on macOS; use `afl-cmin.bash`.
- Stability below 90% means the target is not deterministic for a fixed input.
  Fix that before trusting any crash it reports — `fuzz.py status` warns about it.
- Differing addresses in a panic's stack trace are ASLR, not nondeterminism.
  Compare the target's own `--verbose` output.
