app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import KanbanApp

## Kanban Board, browser build.
main : Engine.Program
main = KanbanApp.program
