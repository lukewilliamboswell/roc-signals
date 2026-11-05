app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import FormApp

## Form Builder, browser build.
main : Engine.Program
main = FormApp.program
