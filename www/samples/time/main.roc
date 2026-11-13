app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import TimeApp

main = TimeApp.program

## The instance holds this store beside its site tree.
Store : Engine.Stored([Demo], (I64, (Engine.Outbox({}), ([NotStamped, Waiting, Stamped(I64)], (U64, Str)))))
