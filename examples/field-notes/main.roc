app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import NotesApp

## Field Notes: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

import Notes

main : Engine.Program
main = NotesApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, (Notes.Board, (Str, (Bool, (I64, (Engine.Outbox(Str), Engine.Outbox({})))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
