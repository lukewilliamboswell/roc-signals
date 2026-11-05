app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import ConduitApp

## Conduit, browser build.
main : Engine.Program
main = ConduitApp.program
