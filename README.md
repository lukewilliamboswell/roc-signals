# Roc Signals

A [Roc](https://www.roc-lang.org) platform for interactive browser apps. You
write the UI in pure Roc; a reactive engine, also in Roc, compiles with your
app to WebAssembly and updates exactly the DOM that depends on what changed.
There is no virtual DOM. A small JavaScript runtime applies the engine's
commands and performs the effects it requests. Slow work, from a pure
calculation to reading and building files, runs as worker tasks in Web
Workers that instantiate the same module.

Behaviour is specified in `.scm` specs that run natively in milliseconds and
replay in headless Chrome.

[Documentation](https://lukewilliamboswell.github.io/roc-signals/docs/guide/) ·
[Examples](https://lukewilliamboswell.github.io/roc-signals/examples/) ·
[Design](design.md)

## Try it

Install the current Roc nightly as `roc` and
[Blueprint](https://github.com/lukewilliamboswell/roc-blueprint), which
provides the pinned tooling (Zig, Node and the scripts' `roc-stable`), then:

```sh
blueprint run spec -- --browser kanban-board   # one example's specs, natively and in Chrome
blueprint run site -- --base-url http://127.0.0.1:8000/roc-signals
blueprint run serve                            # the docs and every example at http://127.0.0.1:8000/roc-signals/
```

[Getting Started](https://lukewilliamboswell.github.io/roc-signals/docs/getting-started/)
walks through writing, testing and running a first app.

## Repository

| Path | Contents |
|---|---|
| `platform/` | The engine (`Core.roc`), its authoring API (`Engine.roc`), the `Html` vocabulary, typed worker tasks (`Worker.roc`, `Wire.roc`), ports (`Port.roc`, `PortJson.roc`), the Wasm host, the browser runtime and its worker script, the native spec runner, and the engine package the platform's own fuzz targets depend on (`main-fuzz.roc`) |
| `cli/` | `signals.roc`, the tool app authors use to create, serve, build and test an app; each release bundles it |
| `examples/` | Example apps, each with its specs |
| `tests/`, `fuzz/` | Browser contract tests, the Chrome spec replay, fuzz targets of the shared support |
| `www/` | The documentation site |
| `scripts/` | The Roc scripts behind the Blueprint tasks |

`blueprint run check` is the pull-request gate. See
[Contributing](https://lukewilliamboswell.github.io/roc-signals/docs/contributing/).

## License

[UPL-1.0](LICENSE). The native spec runner links musl and Zig runtime
archives from roc-fuzz's release; see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
