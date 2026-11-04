app [Instance, main] { pf: platform "../platform-roc/main.roc" }

import pf.Engine
import GridApp

## Data Grid on the p4 engine, browser build (size measurement).
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program(|| GridApp.main({}))
