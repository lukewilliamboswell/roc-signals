app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import FxApp

## The effect-channel test app, browser build.
main : Engine.Program
main = FxApp.program
