app [Instance, main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Counter

## The browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = Counter.program
