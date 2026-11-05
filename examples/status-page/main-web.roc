app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import StatusApp

## Status Page, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = StatusApp.program
