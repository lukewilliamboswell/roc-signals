app [main] { pf: platform "../../platform/main.roc" }

import pf.Base64
import pf.Engine
import pf.Html

# region codec
## Keep a binary envelope in a text-only place, such as browser storage.
saved_envelope : Str
saved_envelope = Base64.encode([0, 255, 128, 1])

## A stored value is external input: handle malformed base64 before decoding
## the envelope itself. Base64 preserves bytes; it does not authenticate them.
read_envelope : Str -> Try(List(U8), [NotBase64])
read_envelope = |stored| Base64.decode(stored)

# endregion codec

main : Engine.Program
main = Engine.program(|| Html.p(saved_envelope, ""))

Store : {}

## The persisted text round-trips to the exact binary envelope.
expect read_envelope(saved_envelope)? == [0, 255, 128, 1]

## Check the default first page while compiling the sample.
mounted : U64
mounted = Engine.mounts(main)
