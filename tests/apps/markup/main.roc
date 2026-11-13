app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import MarkupApp

main : Engine.Program
main = MarkupApp.program

Store : {}

## Check the ordinary default page through the platform's own driver.
mounted : U64
mounted = Engine.mounts(main)
