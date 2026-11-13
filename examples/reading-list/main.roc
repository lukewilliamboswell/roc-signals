app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import ReadingApp
import ReadingList
import BookStorage

## Reading List: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner. The page passes the
## handlers of its ports, `ports.mjs`, when it mounts the module.
main : Engine.Program
main = ReadingApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(ReadingList, (Engine.Table(Str, BookStorage.Book), ([Loaded, Loading, Unreadable(Str)], ([Everything, Only(BookStorage.Shelf)], (BookStorage.NewBook, (Engine.Outbox({ author : Str, title : Str }), (Engine.Outbox(BookStorage.Book), (U64, (I64, (Engine.Outbox(List([Delete(Str), Put(BookStorage.Book)])), Str))))))))))
