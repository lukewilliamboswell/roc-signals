## Test support for roc-signals apps, independent of the engine: the `.scm`
## parser, the native spec runner, the command-stream oracle (`Dom`), the
## long-session soak and JSON output. Apps drive it through their `Program`,
## the record the hosts call, so nothing here depends on `Engine.roc`.
package [Dom, JsonOut, Scm, Soak, SpecRunner] {}
