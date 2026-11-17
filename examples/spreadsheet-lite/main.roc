app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import SheetApp

## Spreadsheet Lite: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Sheet

import SheetStore

main : Engine.Program
main = SheetApp.program

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
