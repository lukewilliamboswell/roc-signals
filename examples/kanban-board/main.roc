app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import KanbanApp

## Kanban Board: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

import Board

import Kanban

main : Engine.Program
main = KanbanApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, (Engine.Table(Str, Kanban.Card), (Str, (Str, Board.Drag))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
