app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import MdApp

## Markdown Editor, browser build.
main : Engine.Program
main = MdApp.program
