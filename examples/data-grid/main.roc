app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import GridApp

## Data Grid: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import GridData

import GridStore

main : Engine.Program
main = GridApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(GridStore, (Engine.Table(U64, GridData.Row), (Str, (GridData.Sort, U64))))
