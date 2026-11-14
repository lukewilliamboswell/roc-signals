app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Recipes

## Build as a native spec runner or a browser module. index.html supplies the
## browser handlers; specs fake only their messages, using the same program.
main : Engine.Program
main = Recipes.program

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
