app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import MdApp

## Markdown Editor: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

main : Engine.Program
main = MdApp.program

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
