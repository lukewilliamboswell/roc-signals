app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import OutboxApp

## The outbox test app: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = OutboxApp.program

## The instance holds this store beside its site tree.
Store : {}
