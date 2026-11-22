## The root the platform's own fuzz targets use.
##
## A roc-fuzz target must be pure Roc with no effects of its own. roc-fuzz
## is the target's platform, and an app has exactly one platform, so nothing
## a target imports may reach a hosted function. The platform root beside
## this file (`main.roc`) cannot serve a target: it binds the hosted
## functions and needs its hosts. So this second root sits over the same
## files and offers, as a package, just the modules a target needs, every
## one of them pure: the engine with its read signatures and write sets, the
## authoring API, the table of a store with its view and ordered keys, the
## spec runner, the `Dom` oracle, the `.scm` parser, and the wire and port
## formats.
##
## Its only users are the platform's own targets: those under `fuzz/` (the
## spec, boot, wire and port format parsers and generated site trees) and those
## beside the test apps under `tests/apps/` that drive the engine (the
## effect channel's model and the controls). A target there is an ordinary
## roc-fuzz app:
##
##     app [target] { fz: platform "<roc-fuzz release>", pf: "../../platform/main-fuzz.roc" }
##
## Apps do not use it. An app tests its behaviour with `.scm` specs through
## its `main.roc`, the spec runner walks it (`--walk`), and an example that
## fuzzes its own pure modules does so with roc-fuzz alone, apart from the
## platform. This package is not published.
##
## A worker job's hosted effects reach the engine as values the platform
## root hands it (`Effects.roc`), which is what keeps the modules listed
## here pure. `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc` belong
## to the platform alone and are not listed.
package [Base64, Clipboard, Core, Dom, Engine, EntryRoutes, Html, JsonOut, Layout, MarkupLiteral, Order, Port, PortJson, Protocol, ProtocolFacts, Reconcile, Scm, Seq, Sig, SpecRunner, Svg, TableCore, Url, View, Web, WebCrypto, Wire, Worker, WorkerCodec] { cbor: "https://github.com/lukewilliamboswell/roc-cbor/releases/download/0.6.3/J3xX4n61WoMZKK3tdWTnZBdKaVbi8SvXvmtC5i3qDAER.tar.zst", parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.5/822J9njyNR1vgyX1KG4ck496dBx3AnLfvn2zHXn15Ksw.tar.zst", unicode: "https://github.com/roc-lang/unicode/releases/download/4.3.3/AJfFMmhvmbgn7THAF1E1sofC3dZaVWPFmVV7GH8Bc7k7.tar.zst" }
