app [Instance, main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Search

## The browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = Search.program
