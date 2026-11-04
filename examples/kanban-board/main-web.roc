app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import KanbanApp

## Kanban Board, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = KanbanApp.program
