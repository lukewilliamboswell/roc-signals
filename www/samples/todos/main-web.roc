app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Todos

## The browser build.
main : Engine.Program
main = Todos.program
