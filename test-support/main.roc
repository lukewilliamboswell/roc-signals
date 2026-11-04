## Engine-independent test support: the `.scm` parser and JSON output.
##
## `SpecRunner.roc` lives beside these modules but is not part of the package:
## it needs the engine's `Dom.roc` oracle and the test platform's `Cli`, so it
## is compiled with each app's native spec build.
package [Scm, JsonOut] {}
