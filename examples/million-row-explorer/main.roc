app [main] {
	pf: platform "../../platform/main.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.6.0/CQJyEgus7V9Wsoh8JHi5mbHXubm7woVbqFhCYLrd8sch.tar.zst",
}

import pf.Engine
import ExplorerApp

## Million-Row Explorer: `roc build --target=wasm32` gives the browser
## module and `roc build --target=x64musl` its native spec runner.
import Explorer

import Orders

main : Engine.Program
main = ExplorerApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(Explorer, (Orders.Filter, (Orders.Filter, ([Live, Paused], (U32, ({ dropped : U32, orders : U64, tally : Orders.Tally }, Str))))))
