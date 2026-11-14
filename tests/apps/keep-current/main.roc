app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import CurrentApp

main : Engine.Program
main = CurrentApp.program

## This instance has no shared store.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
