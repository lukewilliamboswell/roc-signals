app [Instance, main] { pf: platform "../../platform-roc/main.roc" }

import pf.Engine
import Jfb

## The js-framework-benchmark keyed table on the Phase 2 unified engine.
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program(|| Jfb.view({}))
