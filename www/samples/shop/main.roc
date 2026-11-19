app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Shop

## `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Cart

main : Engine.Program
main = Shop.program

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
