app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import Debugging

## One program is used in the browser and by its native specs.
main : Engine.Program
main = Engine.program(|| Debugging.view({}))

## Validate the ordinary first mount while compiling.
mounted : U64
mounted = Engine.mounts(main)
