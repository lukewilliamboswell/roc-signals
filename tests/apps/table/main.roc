app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import TableApp

## The table test app: a table cell of the store drawn through
## `table_view`. `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = TableApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(TableApp, ((Engine.Table(U64, TableApp.Todo), U64), (Engine.Table(U64, TableApp.Todo), ({ order : [ByKey, ByKeyDown, ByQty], show : [All, Done, Few, Open] }, ({ count : U64, start : U64 }, ([Hidden, Shown], ([Hidden, Shown], ([Hidden, Shown], ([Hidden, Shown], ({ count : U64, start : U64 }, ({ left : U32, top : U32, turns : U64 }, (U64, (Engine.Outbox(U32), (Engine.Outbox(Str), List(U64)))))))))))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
