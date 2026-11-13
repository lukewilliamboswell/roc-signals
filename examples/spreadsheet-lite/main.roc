app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import SheetApp

## Spreadsheet Lite: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Sheet

import SheetStore

main : Engine.Program
main = SheetApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(SheetStore, (Engine.Table(U64, Sheet.Row), (U64, ([Editing, Resting, Typing], (SheetStore.Keyboard, ([Formulas, Values], Sheet.Listing))))))
