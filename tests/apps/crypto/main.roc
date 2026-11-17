app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import CryptoApp

## Cryptographic primitives and key ownership, driven by paired native/Chrome specs.
main : Engine.Program
main = Engine.program(|| Engine.state(CryptoApp.initial, CryptoApp.view))

Store : {}

## Check the default first page while compiling the fixture.
mounted : U64
mounted = Engine.mounts(main)
