app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Search

## The browser build.
main : Engine.Program
main = Search.program
