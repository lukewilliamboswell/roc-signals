app [main] {
	pf: platform "../../platform/main.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.6.0/CQJyEgus7V9Wsoh8JHi5mbHXubm7woVbqFhCYLrd8sch.tar.zst",
}

import pf.Engine
import StatusApp

## Status Page: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Status

import StatusStore

main : Engine.Program
main = StatusApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(StatusStore, (U64, (U64, (Bool, ((Status.Check, (Status.Check, (Status.Check, Status.Check))), (Status.Feed, List(Status.Round)))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
