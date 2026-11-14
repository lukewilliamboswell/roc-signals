app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import StoreApp

## The store test app: `roc build --target=wasm32` gives the browser module
## and `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = StoreApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(StoreApp, ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), ((I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64))))))))), (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, (I64, I64)))))))))))))))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
