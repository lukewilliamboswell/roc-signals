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
given that a table carrying the cell's identity and start describes it.
`CheckMain` explores every state within small scopes and checks 31 rules.

`lake exe check gate` runs the scopes the exploration used, each with the
rules it is expected to fail. One scope fails today, by design of the
check: over the branching histories of a pure `Store` value, `kept`
accepts a copy from another history as the cell's own, and `recordSound`,
`recordCovers`, `inverseRestores` and `verEqStartMeansUnchanged` fail,
where `design.md` "Tables and views" requires any table but the one the
modifier received to be stored as a whole rewrite. The gate records that
expectation; the fix changes it to none, in the same commit as the Roc
change.

## Vector files

| File | Written by | Replayed by |
|---|---|---|
| `fuzz/structure/vectors.trace` | `turns`: `lake exe vectors structure` | `fuzz/structure` |
| `fuzz/structure/vectors-bad.trace` | `turns`, from the known-bad algorithms | `fuzz/structure`, which must reject each |
| `fuzz/table-changes/vectors.txt` | `tables`: `lake exe vectors write` | `fuzz/table-changes` |
| `fuzz/view-follow/vectors.txt` | `tables` | `fuzz/view-follow` |

Every file is text, one record per line, `#` starts a comment line, and
tokens are separated by spaces. Nobody edits a vector file by hand.

### Structure traces

```
trace <name>
variant <algorithm> <page|count|button> <step>     vectors-bad only
prog <node> ...
page <leaf> ...
step <k> | <leaf> ... | <n>
end
```

- `prog` is the tree, a list of the Roc generator's `Node` values in its
  own tag names: `(Show i)`, `(Guard i)`, `(Control i)`, `(Bump i)`,
  `(Bump2 i j)`, `(Pair i j)`, `(Watch k i)`, `(When i (yes...) (no...))`,
  `(Switch i (a...) (b...) (c...))`, `(Layer kind i (body...))` and
  `(Each i (body...))`.
- A leaf is what the page shows, in document order: a text's integer, a
  `Pair`'s text as `x~d~y` (the Roc page shows `pair x~d~y`), or a button
  as one `+` per write its click makes (`+` for `Bump`, `++` for `Bump2`).
  Wrapper elements, attributes and properties are not leaves.
- `step k` clicks the k-th live button in document order, counting from 0.
  After it come the page and the evaluations the turn makes by
  `Turns.Expect`: the kernel's count, with exact signatures. It counts the
  holes, `Pair` texts, selectors, list reads and `derive` inputs of the tree
  as `Turns.Structure` translates it. `Guard`, `Control` and `Watch` are
  left out, so it is not the engine's evaluation counter. `-` means none
  recorded.
- `variant` names the known-bad algorithm of `Turns.Incr` that observed the
  trace, and the first observation and step at which the reference rejects
  it. A count-only rejection needs a count model to be seen from Roc.

The trees follow the generator as `wip/reactivity-oracle/patches/value-model.patch`
leaves it: the valued mode (every state starts at 0 and is written by
clicks; a `resource` issues nothing and holds `pending`, its input plus 7), a
`When`, `Switch` or `Each` whose index is 128 or more reading two signals as
their sum, rows keyed by `row_keys`, and the typed levels of `level_below`.
`Turns.Structure` is written from that generator; when it changes,
`Turns.Structure` changes with it and the vectors are written again.

The file holds the structure target's four directed byte examples, decoded,
four hand-written trees, sixteen seeded trees and, for each known-bad
algorithm the others do not expose, the first seeded tree that does. One
algorithm has no vector: `pruneWakes` adds a pruned `derive`'s bit anyway,
and every `derive` the generator builds is injective, so none recomputes an
equal value. The generator cannot test pruning at a `derive`.

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
  modulo 3), `remove(k)`, `update_all` (adds 1 to every row) or `undo`
  (`apply(inverse)`).
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

- `cfg` is `rebuild_ratio` and `rebuild_floor`; the small values let a small
  table reach `rebuilt-many`.
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
