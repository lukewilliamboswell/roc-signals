# Roc Signals

A [Roc](https://www.roc-lang.org) platform for interactive browser apps. You
write the UI in pure Roc; a reactive engine, also in Roc, compiles with your
app to WebAssembly and updates exactly the DOM that depends on what changed.
There is no virtual DOM. A small JavaScript runtime applies the engine's
commands and performs the effects it requests.

Behaviour is specified in `.scm` specs that run natively in milliseconds and
replay in headless Chrome.

[Documentation](https://lukewilliamboswell.github.io/roc-signals/docs/guide/) ·
[Examples](https://lukewilliamboswell.github.io/roc-signals/examples/) ·
[Design](design.md)

## Try it

Install [Blueprint](https://github.com/lukewilliamboswell/roc-blueprint), which
provides the pinned Roc nightly, Zig and Node, then:

```sh
blueprint run spec -- --browser kanban-board   # one example's specs, natively and in Chrome
blueprint run site -- --base-url http://127.0.0.1:8000
blueprint run serve                            # the docs and every example at http://127.0.0.1:8000
```

[Getting Started](https://lukewilliamboswell.github.io/roc-signals/docs/getting-started/)
walks through writing, testing and running a first app.

## Repository

| Path | Contents |
|---|---|
| `platform/` | The engine (`Engine.roc`), the `Html` vocabulary, the Wasm host, the browser runtime, and the native test platform |
| `examples/` | Eight example apps, each with its specs |
| `test-support/`, `tests/`, `fuzz/` | The spec parser and native runner, browser contract tests, fuzz targets |
| `www/` | The documentation site |
| `scripts/` | The Roc scripts behind the Blueprint tasks |

`blueprint run check` is the pull-request gate. See
[Contributing](https://lukewilliamboswell.github.io/roc-signals/docs/contributing/).

## License

[UPL-1.0](LICENSE). The native test platform adapts roc-fuzz; see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
