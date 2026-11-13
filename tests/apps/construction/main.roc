app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import ConstructionApp

## Boot chooses a focused contract; the legal initial frame remains ordinary UI.
main : Engine.Program
main = Engine.program_boot({}, |boot| ConstructionApp.view(boot.url))

## Construction tests hold no shared store.
Store : {}

## The default route is a legal first page.
mounted : U64
mounted = Engine.mounts(main)
