# Fuzzing

Six targets, driven by `scripts/fuzz.py`. Run `python3 scripts/fuzz.py list` for
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
| `propagation` | dependency-ordered, glitch-free propagation and equality cutoffs | a slow evaluator that recomputes every node from the sources, with exact call and prune counts |
| `keyed-scopes` | keyed-row identity, scope retirement, reuse barriers, disposal | a key list plus a predicted scope id for every intern |
| `rows-transitions` | canonical stable-slot generations, lineage, abort, and retry | an ordered array of stable slots, exact keys, and values |
| `structural` | collect/prepare/commit atomicity under allocation failure | committed topology derived from the shape and the current list |
| `ownership` | retained-value and callable ownership across erased calls | a ledger of what each capability owns, checked every step |
| `boundary` | boundary schema and event extraction plan parsing | the grammar itself, plus one-rule-broken trees |

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
| `propagation` | 4 / 4 |
| `ownership` | 8 / 8 |
| `keyed-scopes` | 14 / 14 |
| `boundary` | 6 / 6 |

The boundary row is why this section exists. Three of those six originally
**survived**: deleting the duplicate-field-name, empty-record, or field-name
UTF-8 check left every oracle satisfied, because the target only ever asserted
that the parser stayed total and that valid trees parsed. Nothing it generated
could tell a parser that enforces those rules from one that does not. The fourth
angle — build a tree that breaks exactly one rule, require exactly that rule's
error — was added in response, and is the reason to mutate rather than to admire
a green run.

When adding or changing an oracle, mutate the code it is meant to watch and
confirm the target notices. A mutation that no input reaches is a coverage gap
worth closing, not a mutation worth discarding.

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
