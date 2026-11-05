app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Counter

## The browser build.
main : Engine.Program
main = Counter.program
