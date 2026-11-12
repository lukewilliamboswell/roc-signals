app [main] { pf: platform "../../../../platform/main.roc" }

import pf.Engine
import Jfb

## The js-framework-benchmark keyed table.
main : Engine.Program
main = Engine.program(|| Jfb.view({}))
