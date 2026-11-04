app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import GridApp

## Data Grid, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = GridApp.program
