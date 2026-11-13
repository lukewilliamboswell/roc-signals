app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import WorkersApp

## The worker test app: `roc build --target=wasm32` gives the browser module
## (which the page and every worker instantiate) and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = WorkersApp.program

## The instance holds this store beside its site tree.
Store : {}
