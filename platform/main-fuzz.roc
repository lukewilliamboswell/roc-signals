## The engine as a package, beside the platform root (`main.roc`) over the
## same files, for the fuzz targets. A fuzz target is an ordinary roc-fuzz
## app: roc-fuzz is its platform, and this package gives it the engine,
## the authoring API, the spec runner, the `Dom` oracle, the `.scm` parser,
## the walk and the wire and port formats:
##
##     app [target] { fz: platform "<roc-fuzz release>", pf: "../../platform/engine.roc" }
##
## The shorthand is per app, so an app's own module that says
## `import pf.Engine` gets the platform in the app's `main.roc` and this
## package in its `main-fuzz.roc`.
##
## Every module here is pure. A worker job's hosted effects reach the
## engine as values the platform root hands it (`Effects.roc`), and
## `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc` belong to the
## platform alone, so an app module that imports `Files` cannot be fuzzed
## whole; its target fuzzes its pure parts. The package is not published.
package [Core, Dom, Engine, Html, JsonOut, Port, PortJson, Scm, Soak, SpecRunner, Wire, Worker] {}
