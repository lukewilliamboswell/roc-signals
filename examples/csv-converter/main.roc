app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import ConverterApp

## CSV Converter: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

main : Engine.Program
main = ConverterApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, (AppStore.Source, [JsonLines, Tsv]))
