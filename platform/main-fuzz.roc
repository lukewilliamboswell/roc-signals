## The root the platform's own fuzz targets use.
##
## A roc-fuzz target must be pure Roc with no effects of its own. roc-fuzz
## is the target's platform, and an app has exactly one platform, so nothing
## a target imports may reach a hosted function. The platform root beside
## this file (`main.roc`) cannot serve a target: it binds the hosted
## functions and needs its hosts. So this second root sits over the same
## files and offers, as a package, just the modules a target needs, every
## one of them pure: the engine, the authoring API, the table of a store
## with its view and ordered keys, the spec runner, the `Dom` oracle, the
## `.scm` parser, and the wire and port formats.
##
## Its only users are the platform's own targets: those under `fuzz/` (the
## spec, wire and port format parsers and generated site trees) and those
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
package [Core, Dom, Engine, Html, JsonOut, Port, PortJson, Scm, Seq, SpecRunner, Table, View, Wire, Worker] {}
