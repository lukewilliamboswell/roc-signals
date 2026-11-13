app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import FormApp

## Form Builder: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

import Designer

import Form

main : Engine.Program
main = FormApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, ((Engine.Table(U64, Form.Field), U64), (Form.Answers, (U64, (Designer.Confirm, (Engine.Outbox(Str), (Bool, (Bool, Engine.Outbox(Str)))))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
