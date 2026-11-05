app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import NotesApp

## Field Notes, browser build.
main : Engine.Program
main = NotesApp.program
