app [Instance, main] { pf: platform "../platform-roc/main.roc" }

import pf.Engine
import ConduitApp

## Conduit, browser build: boot with the URL and the two session keys.
Instance : Engine.App

main : Engine.Program(Instance)
main = Engine.program_boot({ storage_keys: ["conduit.jwt", "conduit.username"], max_inflight: 32 }, ConduitApp.main)
