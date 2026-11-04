app [Instance, main] { pf: platform "../platform-roc/main.roc" }

import pf.Engine
import FxApp

## Effect-channel test app, browser build (in-flight bound 3, as the fuzz model).
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program_boot({ storage_keys: [], max_inflight: 3 }, |_| FxApp.main({}))
