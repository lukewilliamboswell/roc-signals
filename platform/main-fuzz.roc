## The root the fuzz targets use.
##
## A roc-fuzz target must be pure Roc with no effects of its own. roc-fuzz
## is the target's platform, and an app has exactly one platform, so nothing
## a target imports may reach a hosted function. The platform root beside
## this file (`main.roc`) cannot serve a target: it binds the hosted
## functions and needs its hosts. So this second root sits over the same
## files and offers, as a package, just the modules a target needs, every
## one of them pure: the engine, the authoring API, the spec runner, the
## `Dom` oracle, the `.scm` parser, the walk, and the wire and port formats.
##
## A fuzz target is then an ordinary roc-fuzz app:
##
##     app [target] { fz: platform "<roc-fuzz release>", pf: "../../platform/main-fuzz.roc" }
##
## The shorthand is per app, so an app's own module that says
## `import pf.Engine` gets the platform in the app's `main.roc` and this
## package in its `main-fuzz.roc`.
##
## A worker job's hosted effects reach the engine as values the platform
## root hands it (`Effects.roc`), which is what keeps the modules listed
## here pure. `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc` belong
## to the platform alone and are not listed, so an app module that imports
## `Files` cannot be fuzzed whole; its target fuzzes its pure parts. This
## package is not published.
package [Core, Dom, Engine, Html, JsonOut, Port, PortJson, Scm, Soak, SpecRunner, Wire, Worker] {}
