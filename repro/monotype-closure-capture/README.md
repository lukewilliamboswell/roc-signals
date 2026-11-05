# An unused capturing closure makes monotype lowering blow up

Upstream: https://github.com/roc-lang/roc/issues/12869

Reproduced with Roc `nightly-2026-11-03-34bd006` on x86_64 Linux.

`Repro.roc` is a standalone type module. It needs no platform:

```sh
roc check --no-cache repro/monotype-closure-capture/Repro.roc
```

This takes 15-20 s and about 380 MB of RSS, almost all of it in "Shared
Monotype Lowering". Deleting the unused `_unused = |_x| rows` closure in `col`
brings it to 0.01 s. So does any one of these changes:

- make `Item` a `Str` instead of a record, tuple or tag union;
- drop the `where [item.is_eq ...]` clauses;
- delete `view`, so nothing instantiates `col`.

The cost grows faster than exponentially with the number of self-recursive
`Repro.inst` call sites, and with the number of match branches they are
spread across. With 2 branches, going from 4 to 5 calls per branch takes the
check from 0.27 s to 18 s. With one call per branch, going from 5 to 6
branches takes it from 0.48 s to 17 s. The issue has the full tables.

The engine's `each_inst` closure has this shape: about 8 self-calls spread
across 3 match arms. In `examples/kanban-board/KanbanApp.roc`, a local helper
closure that captured the column prop took that check to about 100 s and
6 GB. The top-level `slug_of` works around it.
