app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import StartupBuild

## Native producer and page execute this same deterministic catalogue.
main : Engine.Program
main = StartupBuild.program

## Validate both the cold frame and acknowledgement while compiling.
mounted : U64
mounted = Engine.mounts(main)
