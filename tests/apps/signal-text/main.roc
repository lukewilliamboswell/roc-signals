app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import LiteralApp

main : Engine.Program
main = LiteralApp.program
