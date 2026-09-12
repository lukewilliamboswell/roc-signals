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
| `propagation` | dependency-ordered, glitch-free propagation and equality cutoffs | a slow evaluator that recomputes every node from the sources, with exact call and prune counts |
| `keyed-scopes` | keyed-row identity, scope retirement, reuse barriers, disposal | a key list plus a predicted scope id for every intern |
| `rows-transitions` | canonical stable-slot generations, lineage, abort, and retry | an ordered array of stable slots, exact keys, and values |
| `structural` | collect/prepare/commit atomicity under allocation failure | committed topology derived from the shape and the current list |
| `selectors` | selector memberships, fused keyed selects, and `when` on selected values under structural change | the exact document, the live membership multiset, the selector work counters, and the graph's adjacency and routes, all from the shape and the current `(list, selection)` |
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
| `selectors` | 6 / 6 |

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

## The corpus is the product

`test/fuzzing/corpus/` holds inputs replayed by `fuzz.py check`, which the
pull-request CI job runs. Its README covers what belongs there and how to add
one. `.fuzz-out/` is scratch by contrast: large, machine-specific, and deleted by
`fuzz.py clean`.

Campaigns run in the scheduled `fuzz.yml` workflow rather than on pull requests,
because they are unbounded and too variable to gate a change on. They upload
their crashes and corpora, since both are otherwise lost with the runner.

## Notes

- `afl-cmin` does not work on macOS; use `afl-cmin.bash`.
- Stability below 90% means the target is not deterministic for a fixed input.
  Fix that before trusting any crash it reports — `fuzz.py status` warns about it.
- Differing addresses in a panic's stack trace are ASLR, not nondeterminism.
  Compare the target's own `--verbose` output.
