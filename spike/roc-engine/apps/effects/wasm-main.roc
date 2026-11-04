app [Instance, main] { pf: platform "../platform-roc/main.roc" }

import pf.Engine
import FxApp

Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program(|| FxApp.main({}))
