app [main] {
	pf: platform "../../platform/main.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.6.0/CQJyEgus7V9Wsoh8JHi5mbHXubm7woVbqFhCYLrd8sch.tar.zst",
}

import pf.Engine
import ExplorerApp

## Million-Row Explorer: `roc build --target=wasm32` gives the browser
## module and `roc build --target=x64musl` its native spec runner.
main : Engine.Program
main = ExplorerApp.program
