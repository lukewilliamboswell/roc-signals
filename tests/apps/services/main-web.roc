app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import ServicesApp

## The browser-services test app, browser build.
main : Engine.Program
main = ServicesApp.program
