app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import TypedApp

## The typed worker test app: `roc build --target=wasm32` gives the browser
## module and `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = TypedApp.program
