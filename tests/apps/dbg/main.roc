app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import DbgApp

## Browser and native runners consume the same program.
main : Engine.Program
main = DbgApp.program

## The ordinary default mount remains checked while compiling.
mounted : U64
mounted = Engine.mounts(main)
