app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import WriteScaling
main : Engine.Program
main = WriteScaling.program

## The store lives beside the site tree throughout the instance's lifetime.
Store : Engine.Stored(WriteScaling, (Engine.Table(U64, WriteScaling.Row), U64))

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
