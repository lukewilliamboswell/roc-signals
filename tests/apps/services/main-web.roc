app [Instance, main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import ServicesApp

## The browser-services test app, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = ServicesApp.program
