app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import NamespacesApp

## The ordinary-constructor fixture checks explicit names independently of markup
## lowering. The same entry supplies the native runner and browser module.
main : Engine.Program
main = NamespacesApp.program

## This fixture has local state only; no shared store is needed.
Store : {}

## Compile the ordinary default HTML root along with the fixture.
mounted : U64
mounted = Engine.mounts(main)
