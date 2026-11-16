app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Shop

## `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Cart

main : Engine.Program
main = Shop.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(Shop, ((Cart, Str), (Str, (U64, Engine.Outbox(U64)))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
