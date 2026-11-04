app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import FormApp

## Form Builder, browser build.
Instance : Engine.App

main : Engine.Program(Instance)
main = FormApp.program
