app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine

## No default-mount constant: this fixture distinguishes metadata from init.
main : Engine.Program
main = Engine.program_startup({}, Engine.entries({}, [{ path: "/", route: 0.U8 }]), |_route| crash "startup query unexpectedly initialized")
