app [Instance, main] { pf: platform "../../../../platform/main.roc" }

import pf.Engine
import Jfb

## The js-framework-benchmark keyed table on the Roc-owned engine.
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program(|| Jfb.view({}))
