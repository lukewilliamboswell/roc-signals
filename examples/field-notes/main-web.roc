app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import NotesApp

## Field Notes, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = NotesApp.program
