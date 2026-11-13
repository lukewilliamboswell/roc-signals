app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Recipes

## Build as a native spec runner or a browser module. index.html supplies the
## browser handlers; specs fake only their messages, using the same program.
main : Engine.Program
main = Recipes.program
