# A closure capturing a component's prop makes monotype lowering explode

Not yet filed upstream. Reproduced with Roc `nightly-2026-11-03-34bd006` on
x86_64 Linux.

`main.roc` is an app on `platform/main.roc`. Inside a component body (`col`),
the local closure `_slug = |prefix| cp.map(...)` captures the component's
prop `cp` and is never called. Next to it, an `each` iterates a list of
records (`Item : { title : Str }`).

```sh
roc check --no-cache repro/monotype-closure-capture/main.roc
```

takes about 120 s and peaks at about 6 GB of RSS, all of it in "Shared
Monotype Lowering" (`--timings`). Any one of these changes brings it to
0.3 s:

- delete the closure, or replace it with a value (`name = cp.map(...)`);
- make it a top-level function that takes `cp` as an argument;
- make the `each` iterate `List(Str)` instead of a list of records.

`--opt=dev` builds (native and `--target=wasm32`) take the same time, since
the cost is before code generation.

`examples/kanban-board/KanbanApp.roc` works around it with the top-level
`slug_of` (see the comment there); its check went from about 95 s to 0.25 s.
