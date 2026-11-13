app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import CurrentApp

main : Engine.Program
main = CurrentApp.program

## This instance has no shared store.
Store : {}
