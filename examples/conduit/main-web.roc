app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import ConduitApp

## Conduit, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = ConduitApp.program
