# The reference models

This directory holds the reference semantics of the engine, written in
Lean 4, and the programs that write the test vectors the Roc fuzz targets
replay. `design.md` "Testing Architecture" says what the reference is for;
this file says what is here, how to run it and what the vector files mean.

Both projects use core Lean and `Std` only, with no Lake dependency, so
they build offline. `lean-toolchain` pins the Lean release for both: elan
reads it from the parent directory of each project.

## Running it

```sh
blueprint run oracle
```

builds both projects, runs each project's fixed checks (`lake exe check
gate`), checks the structure vectors against the reference, writes every
vector file again under `.build/oracle/` and fails if any differs from the
checked-in one, or if a proof uses `sorry`. It needs `lake` on the `PATH`
(install [elan](https://github.com/leanprover/elan)); without it the task
fails and names `oracle/lean-toolchain`. It is local only: CI does not
install Lean, and `check` does not run it. A clean run takes about two
minutes, most of it the two gates.

By hand, in `oracle/turns` or `oracle/tables`: `lake build`, then
`lake exe check` and `lake exe vectors` with no arguments for their usage.

## `turns`: what a turn means

| Module | What it is | Trusted for |
|---|---|---|
| `Turns.Kernel` | Programs as data: expressions, handlers, sites | What a program reads and computes; that a handler's writes compose in order |
| `Turns.Spec` | The reference: the page from scratch, a turn as "apply the writes, render again" | What a turn means. This decides a disagreement, unless `design.md` says otherwise |
| `Turns.Expect` | A second specification: the readers a turn must evaluate, what each must see, the texts set and the scopes created | How much a turn may do. Its evaluation count is the kernel's, not the engine's counter |
| `Turns.Incr` | The incremental algorithm of `design.md`, with ten switchable defects | Nothing: it is what the checks are measured on |
| `Turns.Props` | The rules one turn of an algorithm must keep against the two specifications | The rules |
| `Turns.Gen` | The kernel's own generator, wider than the Roc one | |
| `Turns.Structure` | The Roc structure generator's `Node` type, its byte decoder, and what each node means in the kernel | Which trees the Roc side can generate |
| `Turns.Trace` | The structure vector format and a checker of a trace against the reference | |
| `Turns.Proof` | A proof of P3 (a turn leaves every hole and `derive` consistent) for the static fragment, under any signature abstraction | The theorems, about its own model of the fragment |
| `Turns.ProofLink` | A test that the proof's model and `Turns.Incr` agree on static programs | |

`lake exe check gate` runs: every program within small bounds and 20,000
seeded random programs at two signature abstractions, which must break no
rule under the design's algorithm; the same seeded series under each
known-bad algorithm, which must be caught; and the proof link.

## `tables`: a table's changes and its views

`Tables.Table` and `Tables.View` transliterate `platform/TableCore.roc`,
the table cell's generated modifier in `platform/Core.roc`, `platform/View.roc`
and the table view site's `Changed`, line for line, with the Roc line ranges
cited. They follow the code as it is, defects included. `Tables.Spec` states
what the record and a view mean; `Tables.Proof` proves that the operations,
the turn boundary and `kept` keep the record describing the turn's start,
given that a table carrying the cell's identity and start, still in its
recording phase, describes it. `CheckMain` explores every state within small
scopes and checks 31 rules.

`lake exe check gate` runs a fixed set of scopes, each with the rules it is
expected to fail. None fails: over the branching histories of a
pure `Store` value, two histories share the cell's identity and can reach
one count with different rows, and `kept` takes as the cell's own only a
table still in the recording phase its modifier put it in, as `design.md`
"Tables and views" requires. One more scope runs the seeded `noPhase`
defect, `kept` judging by identity and count alone, over those histories,
and must fail `recordSound`, `recordCovers`, `inverseRestores` and
`verEqStartMeansUnchanged`. Branching with copies saved mid-turn is refused:
a pure `Store` builds its writes before the turn, so no such copy reaches
another history.

## Vector files

| File | Written by | Replayed by |
|---|---|---|
| `fuzz/structure/vectors.trace` | `turns`: `lake exe vectors structure` | `fuzz/structure/Vectors.roc` |
| `fuzz/structure/vectors-bad.trace` | `turns`, from the known-bad algorithms | `fuzz/structure/Vectors.roc`, which must reject each |
| `fuzz/table-changes/ChangeVectors.roc`, its `vectors` list | `tables`: `lake exe vectors write` | `fuzz/table-changes/FuzzTableChangesProperty.roc` |
| `fuzz/view-follow/FollowVectors.roc`, its `vectors` list | `tables` | `fuzz/view-follow/FuzzViewFollowProperty.roc` |

The structure traces are text, one record per line, `#` starts a comment
line, and tokens are separated by spaces. The table vectors are Roc
values: `lake exe vectors write` reads each module up to its line
`\tvectors =`, keeps that part (the types and their comments) as it is,
and writes the list after it, so the module's types state the format and
the compiler checks every vector against them. Nobody edits a vector file,
or a vector list, by hand.

Each target replays its vectors two ways. A
top-level `expect` runs the target's Roc reference alone over every
vector (`roc test` on the target's root): the value model for
`structure`, the session model for each table target. The target's fixed
examples run every vector through the real code as well: the engine for
`structure` (mode 6), `TableCore` and `View` for the table targets
(mode 2). A vector the replay does not hold to fails with its name and
step (or seed and turn); a trace line that does not parse fails naming
it.

### Structure traces

```
trace <name>
variant <algorithm> <page|count|button> <step>     vectors-bad only
prog <node> ...
page <leaf> ...
step <k> | <leaf> ... | <n>
end
```

- `prog` is the tree, a list of the Roc generator's `Reference.Node`
  values in its own tag names: `(Show i)`, `(Guard i)`, `(Control i)`,
  `(Bump i)`, `(Bump2 i j)`, `(Pair i j)`, `(Watch k i)`,
  `(When sel (yes...) (no...))`, `(Switch sel (a...) (b...) (c...))`,
  `(Layer kind i (body...))` and `(Each sel (body...))`, where a selector
  `sel` is `(One i)` or `(Two i j)`.
- A leaf is what the page shows, in document order: a text's integer, a
  `Pair`'s text as `x~d~y` (the Roc page shows `pair x~d~y`), a row's
  text as `key:item`, or a button as one `+` per write its click makes
  (`+` for `Bump`, `++` for `Bump2`). Wrapper elements, attributes and
  properties are not leaves.
- `step k` clicks the k-th live button in document order, counting from 0.
  After it come the page and the evaluations the turn makes by
  `Turns.Expect`: the kernel's count, with exact signatures. It counts the
  holes, `Pair` texts, selectors, list reads and `derive` inputs of the tree
  as `Turns.Structure` translates it. `Guard`, `Control` and `Watch` are
  left out, so it is not the engine's evaluation counter. `-` means none
  recorded.
- `variant` names the known-bad algorithm of `Turns.Incr` that observed the
  trace, and the first observation and step at which the reference rejects
  it. The Roc value model compares pages only, so it must reject a `page`
  or `button` trace at exactly that step and accept a `count` trace by the
  page. The Roc count model (`fuzz/structure/Counts.roc`) replays every
  step's count with the kernel's definition and must agree on every
  vector and reject a `count` trace at exactly its step; the same model,
  with the engine's definition, holds the engine's counter to each click.

The trees follow the generator in `fuzz/structure/Reference.roc` and
`FuzzStructureProperty.roc` in its valued modes: every state starts at 0
and is written by clicks; a `resource` issues nothing and holds `pending`,
its input plus 7; a selector reads one value or the sum of two; an index
counts from the start below 128 and from the end at 128 and above
(`place`); a `derive` layer computes `2x + 1` or, for odd `kind // 5`,
`x // 2`, which can leave its value unchanged; rows are `rows_of`'s
`key:item` pairs, whose items change under a kept key; and the typed
levels of `level_below`. The decoder includes the biased `two_writes`
shape. `Turns.Structure` is written from that generator; when it changes,
`Turns.Structure` changes with it and the vectors are written again.

The file holds the structure target's eight valued byte examples, decoded,
five hand-written trees, sixteen seeded trees and, for each known-bad
algorithm the others do not expose, the first seeded tree that does.
Every known-bad algorithm has a vector; `pruneWakes`, which wakes the
readers of a `derive` that recomputed an equal value, is seen by the count
alone, as are `twoPassOuter` and `noJoinKeep` on these trees.

### Table changes

Each vector is a `ChangeVectors.Vector`: its seed, its starting rows and
its turns, after a comment naming the classes it is the first to reach.

- A modifier is a function handed to the cell's generated modifier:
  `On(ops)` changes the table it is given; `Saved(i, ops)` ignores it and
  changes the i-th kept copy; `Other(i)` is the i-th kept copy under
  another cell's identity; `Fresh(rows)` is `Table.from_list`. An op is
  `Insert(k, v)`, `Put(k, v)`, `Replace(k, v)`, `Update(k)` (adds 1,
  modulo the target's row space: 4 for `table-changes`, 8 for
  `view-follow`), `Remove(k)`, `All` (`update_all`: adds 1 to every row,
  modulo the same) or `Undo` (`apply(inverse)`).
- A turn's outcome is the rows; the record, `Keyed` with each key and
  `Was(row)` or `Absent` in the record's order, or `Rewritten`; the
  table's write count and the count its changes began at.
- `keep: Bool.True` keeps a copy of the cell's table as it stands after
  the turn, for later `Saved` and `Other` modifiers.
- A class is the modifier's kind, the record it was handed (`turn-start`,
  `key-recorded`, `key-unrecorded`, `keyed` or `rewritten`) and what it left
  (`writes`, `no-write`, `rewritten`). A vector is the first history of a
  seeded series, over three keys and three row values, to reach a class.

### View follow

Each vector is a `FollowVectors.Vector`: its seed, the rebuild thresholds
(`ratio`, `floor`), the table's starting rows, the view's query and
window, and its turns, after a comment naming the classes it reaches.
Modifiers and records are those of `table-changes`.

- The thresholds are `rebuild_ratio` and `rebuild_floor`. The list holds
  only `View.roc`'s own, 8 and 64, since the target replays the real
  `View`; a table of three keys never writes enough rows to rebuild under
  them, so no vector is `rebuilt-many` (the target's own seeded series,
  over 24 keys, reaches it). The histories hold no `Undo`, which the
  target's model does not describe.
- A query is 0 (every row, by row then key), 1 (rows of 1 or more, by row
  then key) or 2 (every row, by key descending); a window of count 1000
  draws every row. A turn's `query` and `window` are `Ok` of the new one
  when the turn changes it, or `Err(Same)`.
- A turn's outcome is how the view followed its table (`Unchanged`,
  `Absorbed`, `Rebuilt(Many)`, `Rebuilt(Rewritten)`), the table, the
  ordered keys of the whole view, the drawn keys, and the changes of the
  rows drawn: `Left(k)`, `Entered`, `Moved` (each with the key it goes
  before, `Row(k)`, or `End`) and `Changed(k)`.
- A class is how the view followed and one kind of change (or `none`).

A table vector is written only from a single history, as a mounted instance
has one, so none asserts the branching-history outcome the gate expects to
fail.

## Changing a meaning

A change to what a turn, a table or a view means lands in one pull
request, in this order: `design.md`; the Lean model here; the Roc reference
in the fuzz target; the vector files, written again by `blueprint run
oracle`. A Lean model that disagrees with the engine is resolved by changing
whichever is wrong, never by editing a vector.
