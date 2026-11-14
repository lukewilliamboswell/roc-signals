app [main] {
	pf: platform "../../platform/main.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.6.0/CQJyEgus7V9Wsoh8JHi5mbHXubm7woVbqFhCYLrd8sch.tar.zst",
}

import pf.Engine
import pf.Worker
import ExplorerApp

## Log Explorer: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import Log

import LogStore

import TimelineChart

main : Engine.Program
main = ExplorerApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(LogStore, ([Chosen(Engine.File), NoLog], ([Overview, Search, Viewer], ({ filter : [Everything, Only(Log.Level)], text : Str }, ((U64, (U64, (U32, LogStore.Geometry))), (Log.Viewport, (Engine.Outbox(U32), (TimelineChart.Theme, ([Generating(U64), Idle], [NoNote, NotACount, NotWritten(Worker.Error(Engine.FileError))])))))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
