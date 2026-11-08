app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Todos

## `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = Todos.program
