app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.WebCrypto

# region requests
## These parameters are part of the saved envelope, chosen by the application.
## A deployment can cap the cost with maxCryptoIterations at mount.
derive : { password : Str, salt : List(U8) } -> Engine.Ask(WebCrypto.Key, WebCrypto.Error)
derive = |input| WebCrypto.derive_key({ password: input.password, salt: input.salt, iterations: 600000, hash: Sha256 })

## The platform generates a fresh 12-byte IV for every encryption. The project
## id is authenticated along with the ciphertext, without becoming plaintext.
seal : WebCrypto.Key, Str -> Engine.Ask(WebCrypto.Sealed, WebCrypto.Error)
seal = |key, message| WebCrypto.encrypt(key, { plaintext: message.to_utf8(), associated: "project-42".to_utf8() })

## Wrong passwords, changed ciphertext and changed associated data all answer
## NotAuthentic. No plaintext is returned until authentication succeeds.
open : WebCrypto.Key, WebCrypto.Sealed -> Engine.Ask(List(U8), WebCrypto.Error)
open = |key, envelope| WebCrypto.decrypt(key, { iv: envelope.iv, ciphertext: envelope.ciphertext, associated: "project-42".to_utf8() })

# endregion requests

## The UI stores a key only while this session is unlocked. A key cannot be
## serialized as part of the persisted envelope.
Session : [Locked, Unlocked(WebCrypto.Key)]

# region ownership
## An application locks by writing its key-holding cell or state without the
## key. Once no value holds it, Roc releases the browser key automatically.
lock : Session -> Session
lock = |_session| Locked

# endregion ownership

main : Engine.Program
main = Engine.program(|| Html.p("Use the typed requests in an effect site.", ""))

Store : {}

## The sample's first frame creates no cryptographic work.
mounted : U64
mounted = Engine.mounts(main)
