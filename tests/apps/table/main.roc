app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import TableApp

## The table test app: a table cell of the store drawn through
## `table_view`. `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = TableApp.program
