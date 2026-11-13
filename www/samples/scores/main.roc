app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Scores

## `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = Scores.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(Scores, ((Engine.Table(U64, Scores.Player), U64), ({ order : [Highest, Lowest], show : [Everyone, Team([Blue, Red])] }, ({ count : U64, start : U64 }, ({ count : U64, start : U64 }, Bool)))))
