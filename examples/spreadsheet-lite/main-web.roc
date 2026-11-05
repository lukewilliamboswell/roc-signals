app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import SheetApp

## Spreadsheet Lite, browser build.
main : Engine.Program
main = SheetApp.program
