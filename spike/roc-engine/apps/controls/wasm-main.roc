app [Instance, main] { pf: platform "../platform-roc/main.roc" }

import pf.Engine
import ControlsApp

## Controlled inputs / focus / containment test app, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program(|| ControlsApp.main({}))
