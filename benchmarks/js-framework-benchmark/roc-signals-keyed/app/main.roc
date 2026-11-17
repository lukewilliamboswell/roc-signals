app [main] { pf: platform "../../../../platform/main.roc" }

import pf.Engine
import Jfb

## The js-framework-benchmark keyed table.
main : Engine.Program
main = Engine.program(|| Jfb.view({}))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
