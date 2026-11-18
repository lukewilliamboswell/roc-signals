app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine

entries = Engine.entries({}, [{ path: "/", route: {} }])

## This writer is absent in the ordinary frame but has constructor-sensitive
## meaning if present. Plain construction is valid; retained binding refuses it.
main : Engine.Program
main = Engine.program_startup({}, entries, |_| Engine.element("div", [Engine.attr_presence("is", Engine.const(Absent))], [Engine.text("plain construction")]))

mounted : U64
mounted = Engine.mounts(main)
