# Roc Signals

A [Roc](https://www.roc-lang.org) platform for interactive browser apps. You
write the UI in pure Roc; a reactive engine, also in Roc, compiles with your
app to WebAssembly and updates exactly the DOM that depends on what changed.
A signal is a read-only value whose state dependencies are declared when it
is built. There is no virtual DOM. A small JavaScript runtime applies the engine's
commands and performs the effects it requests. Slow work, from a pure
calculation to reading and building files, runs as worker tasks in Web
Workers that instantiate the same module.

State lives in three places: a store of cells the whole app shares, read at
any depth of the view; tables of rows edited by key and drawn through
sorted, filtered windows; and local state that belongs to one piece of the
view. Shared state is written by decisions, pure functions that return
their writes, so the engine learns what changed from the write and never by
comparing values.

Decisions are tested as functions with `expect`. Behaviour is specified in
`.scm` specs that run natively in milliseconds and replay in headless
Chrome.

[Documentation](https://lukewilliamboswell.github.io/roc-signals/docs/guide/) ·
[Examples](https://lukewilliamboswell.github.io/roc-signals/examples/) ·
[Design](design.md)

## Roc Signals and Joy

[Joy](https://github.com/niclas-ahden/joy), by Niclas Åhdén, is another
Roc framework for web apps, and it makes different trade-offs. A Joy app
follows the Elm architecture: a `Model`, a `Msg`, and `init`, `update`,
`render` and `subscriptions`. Each event is a message to `update`; `render`
then builds the view again from the new model, and Joy's host, written in
Rust, compares it with the previous view to find what to change in the DOM.
`lazy` skips a part of the view whose inputs did not change. Joy's HTML
package also renders the same views to a string on a server, towards its
goal of full-stack apps written in Roc. The two have much in common: the UI
is pure Roc compiled to WebAssembly, effects are described as data, a small
JavaScript runtime applies the changes to the DOM and performs those
effects, and both build with Roc's nightly compiler and expect their APIs
to keep changing.

Choose Joy when you want that model: all of an app's state in one value, one
function that changes it and a view that is a function of it. It is small,
and familiar to anyone who knows Elm. Choose it too when a server should
render the same views, which Roc Signals does not do: it is a client-side
runtime. Choose Roc Signals when you want an update to go only to the parts
of the page that read what it wrote, and accept more to learn for it: a view
that runs once, and state divided so that every write says what it touched.
It also brings tables of rows edited by key, worker tasks for slow work, and
specs that run natively against the same engine and replay in Chrome.

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
| `platform/` | The engine (`Core.roc`, with tables and their table views in `TableCore.roc`, `View.roc` and `Seq.roc`), its authoring API (`Engine.roc`), the `Html` vocabulary, ordered sort values (`Order.roc`), typed worker tasks (`Worker.roc`, `Wire.roc`), ports (`Port.roc`, `PortJson.roc`), the Wasm host, the browser runtime and its worker script, the native spec runner, and the engine package the platform's own fuzz targets depend on (`main-fuzz.roc`) |
| `cli/` | `signals.roc`, the tool app authors use to create, serve, build and test an app; each release bundles it |
| `examples/` | Example apps, each with its specs and, where its pure logic has a rule worth stating, a fuzz target of that logic (`fuzz-<subject>.roc`) |
| `tests/`, `fuzz/` | Browser contract tests and the apps they drive, the Chrome spec replay, and the platform's own fuzz targets |
| `www/` | The documentation site; `www/samples/` holds every code sample the docs show |
| `scripts/` | The Roc scripts behind the Blueprint tasks |

`blueprint run check` is the pull-request gate. See
[Contributing](https://lukewilliamboswell.github.io/roc-signals/docs/contributing/).

## License

[UPL-1.0](LICENSE). The native spec runner links musl and Zig runtime
archives from roc-fuzz's release; see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
