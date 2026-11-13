app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import MdApp

## Markdown Editor: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

main : Engine.Program
main = MdApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, (Str, (U64, (AppStore.SavedRevision, (AppStore.Elsewhere, (Engine.Outbox({}), (Engine.Outbox({}), (Engine.Outbox(AppStore.CopyFormat), (Engine.Outbox({}), (AppStore.DraftStatus, (AppStore.CopyStatus, (AppStore.DraftStatus, [False, True]))))))))))))
