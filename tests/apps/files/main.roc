app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import FilesApp

## The files test app: `roc build --target=wasm32` gives the browser module
## and `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = FilesApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(FilesApp, (List(Engine.File), Str))
