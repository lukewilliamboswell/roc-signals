app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import MdApp

## Markdown Editor, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = MdApp.program
