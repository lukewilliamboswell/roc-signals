app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import PrerenderApp

## The first-picture fixture is an ordinary app with an ordinary native runner.
main : Engine.Program
main = PrerenderApp.program

## Its default first page is checked during compilation like every test app.
mounted : U64
mounted = Engine.mounts(main)
