app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import WriteScaling
main : Engine.Program
main = WriteScaling.program

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
