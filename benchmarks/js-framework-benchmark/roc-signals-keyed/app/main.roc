app [main] { pf: platform "../../../../platform/main.roc" }

import pf.Engine
import Jfb

## The js-framework-benchmark keyed table on the Roc-owned engine.
main : Engine.Program
main = Engine.program(|| Jfb.view({}))
