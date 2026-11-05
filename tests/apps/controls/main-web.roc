app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import ControlsApp

## The controlled-input test app, browser build.
main : Engine.Program
main = ControlsApp.program
