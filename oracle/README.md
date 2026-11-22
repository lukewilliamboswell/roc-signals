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
| `fuzz/table-changes/vectors.txt` | `tables`: `lake exe vectors write` | `fuzz/table-changes/ChangeVectors.roc` |
| `fuzz/view-follow/vectors.txt` | `tables` | `fuzz/view-follow/FollowVectors.roc` |

Every file is text, one record per line, `#` starts a comment line, and
tokens are separated by spaces. Nobody edits a vector file by hand.

Each target imports its files as text and replays them two ways. A
top-level `expect` runs the target's Roc reference alone over every
vector (`roc test` on the target's root): the value model for
`structure`, the session model for each table target. The target's fixed
examples run every vector through the real code as well: the engine for
`structure` (mode 6), `TableCore` and `View` for the table targets
(mode 2). A vector the replay does not hold to fails with its name and
step (or seed and turn); a line that does not parse fails naming it.

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

```
vector <seed>
covers <class>, ...
start <key>:<row> ...
turn <modifier> ; <modifier> ...
  -> rows <key>:<row> ... | <record> | <version> <start>
keep
end
```

- A modifier is a function handed to the cell's generated modifier:
  `on <op> ...` changes the table it is given; `saved i <op> ...` ignores it
  and changes the i-th kept copy; `other i` is the i-th kept copy under
  another cell's identity; `fresh <key>:<row> ...` is `Table.from_list`. An
  op is `insert(k,v)`, `put(k,v)`, `replace(k,v)`, `update(k)` (adds 1,
  modulo the target's row space: 4 for `table-changes`, 8 for
  `view-follow`), `remove(k)`, `update_all` (adds 1 to every row, modulo
  the same) or `undo` (`apply(inverse)`).
- After each turn: the rows; the record as `keyed` followed by
  `<key>=was:<row>` or `<key>=absent` in the record's order, or
  `rewritten`; the table's write count and the count its changes began at.
- `keep` keeps a copy of the cell's table as it stands, for later `saved`
  and `other` modifiers.
- A class is the modifier's kind, the record it was handed (`turn-start`,
  `key-recorded`, `key-unrecorded`, `keyed` or `rewritten`) and what it left
  (`writes`, `no-write`, `rewritten`). A vector is the first history of a
  seeded series, over three keys and three row values, to reach a class.

### View follow

```
vector <seed>
covers <class>, ...
cfg <ratio> <floor>
table <key>:<row> ...
view <query> <start> <count>
turn <modifier> ; ... [; query <q>] [; window <start> <count>]
  -> how <how> | rows ... | <record> | <version> <start> | keys <key> ... | drawn <key> ... | <change> ...
keep
end
```

- `cfg` is `rebuild_ratio` and `rebuild_floor`. The file holds only
  `View.roc`'s own, 8 and 64, since the target replays the real `View`;
  a table of three keys never writes enough rows to rebuild under them,
  so no vector is `rebuilt-many` (the target's own seeded series, over 24
  keys, reaches it). The file's histories hold no `undo`, which the
  target's model does not describe.
- A query is 0 (every row, by row then key), 1 (rows of 1 or more, by row
  then key) or 2 (every row, by key descending); a window of count 1000
  draws every row.
- After a turn that reaches the site: how the view followed its table
  (`unchanged`, `absorbed`, `rebuilt-many`, `rebuilt-rewritten`), the
  table, the ordered keys of the whole view, the drawn keys, and the
  changes of the rows drawn: `left:k`, `entered:k@anchor`, `moved:k@anchor`
  (`anchor` is the key it goes before, or `end`) and `changed:k`.
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
