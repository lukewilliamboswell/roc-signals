app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import Notes

## `roc build --target=wasm32` gives the browser module and
## `roc build --target=x64musl` its native spec runner. The page passes the
## ports' handlers, `notes-ports.mjs`, when it mounts the module.
main : Engine.Program
main = Notes.program
