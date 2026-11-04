app [Instance, main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import ControlsApp

## The controlled-input test app, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = ControlsApp.program
