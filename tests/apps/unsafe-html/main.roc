app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import HtmlApp

main : Engine.Program
main = Engine.program_boot({}, |boot| HtmlApp.view_at(boot.url))

## This instance has no shared store.
Store : {}

## Check the ordinary mount, independently of picture support.
mounted : U64
mounted = Engine.mounts(main)
