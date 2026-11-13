app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import ConduitApp

## Conduit: `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner.
import AppStore

import CommentForm

import Comments

import Pages

import Session

import Story

main : Engine.Program
main = ConduitApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored(AppStore, (Session, (Str, (Engine.Outbox(Str), (Session, (Pages.Model, (Story, (Comments, CommentForm))))))))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
