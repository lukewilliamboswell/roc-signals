app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import SheetApp

## Spreadsheet Lite, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = SheetApp.program
