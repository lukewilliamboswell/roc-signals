app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import GridApp

## Data Grid, browser build.
main : Engine.Program
main = GridApp.program
