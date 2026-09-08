[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Roc Signals

Roc Signals is a Roc platform for building small reactive interfaces that can
run in a browser or under the native test host.

An app describes its UI with values, signals, and event handlers. The host keeps
that description alive, owns retained state, runs tasks, and patches only the
parts of the interface that changed.

## Start Here

The GitHub Pages site is the front door:

- [Roc Signals site](https://lukewilliamboswell.github.io/roc-signals/)

The maintained docs live under [www/content/docs/](www/content/docs/) and read in
this order:

| Doc | What it covers |
| --- | --- |
| [Guide](www/content/docs/guide.md) | What this is, the one idea, reading path |
| [Thinking in Signals](www/content/docs/thinking-in-signals.md) | The model, and how it maps to React/Solid/Svelte/Vue/Elm |
| [Getting Started](www/content/docs/getting-started.md) | Install, build, run in a browser, first native test |
| [Tutorial](www/content/docs/tutorial.md) | Build an app end to end, finishing with passing specs |
| [State, Events, and Forms](www/content/docs/state-and-events.md) | Local state, reducers, controls, validation |
| [Lists, Conditionals, and Components](www/content/docs/dynamic-structure.md) | Dynamic structure, keys, row-local state |
| [Effects, HTTP, and the Browser](www/content/docs/effects-and-browser.md) | Tasks, fetch, timers, routing, storage |
| [Structuring a Real App](www/content/docs/app-architecture.md) | How Conduit is organized |
| [Testing](www/content/docs/testing.md) | Spec language, deterministic async, work budgets |
| [Under the Hood](www/content/docs/under-the-hood.md) | Wire protocol, capabilities, performance model |
| [Reference](www/content/docs/reference.md) | Complete API surface |
| [Contributing](www/content/docs/contributing.md) | Local setup, tests, host artifacts, bundles, releases |

The platform architecture and host boundary notes live in [design.md](design.md).

## Use a release

Download `signals-starters.zip` from the [supported release](https://github.com/lukewilliamboswell/roc-signals/releases).
It contains the complete examples, native specs, browser runtime, and direct Roc
build commands. Install the exact compiler named in the application's `roc`
header. A platform archive already contains its host binaries; users need no
Zig build or repository checkout.

Public examples pin immutable platform/package release URLs. The nightly bot
updates their compiler pins and the development platform pin together, tests both
the released dependencies and current source, and automatically merges passing
pin-only updates. Failed updates remain open for investigation. A repair may need
a new release before the examples can accept that compiler.

The first release candidate for the new API is `0.2.0-rc1`; compiler compatibility
branches are not needed during this exact-nightly bootstrap. Package versions
are independent of Roc versions. See [nightly maintenance](.github/ROC_NIGHTLY.md).

## Develop locally

Build and serve the static site with the examples:

```sh
python3 scripts/serve.py
```

Then open the local URL printed by the server. To use a fixed port:

```sh
python3 scripts/serve.py --port 8000
```

The examples live under [examples-web/](examples-web/). Each public example has its own
directory with `main.roc`, any supporting modules, and a native test spec.

To run the validation suite:

```sh
python3 scripts/test.py
```

The scripts use `roc` from `PATH` by default. Override it with `ROC_BIN`, `ROC`,
or `--roc-bin /path/to/roc`.

## Coverage

Native host coverage is the main signal for risky engine behavior because it
exercises bind, initial eval, dirty propagation, structural patching, effects,
and the spec parser under one host.

Refresh the report with:

```sh
python3 scripts/coverage.py --format summary --top 40
```

Inspect uncovered source ranges without rebuilding kcov output:

```sh
python3 scripts/coverage.py --use-last-run --format lines --file src/signals/engine.zig --context 5
```

CI enforces both global coverage and per-file floors for the engine,
descriptor stream, native host, platform ABI, and spec parser. When adding
signal behavior, prefer host-level tests that go through real descriptor bind,
render apply, dirty propagation, task resolution, or interval ticks. Ratchet the
nearest per-file threshold when the new test closes meaningful uncovered risk;
do not chase panic-only, fatal handler, or OOM cleanup noise for its own sake.

## Performance

See [Profiling and Improving the Engine](docs/profiling.md) for the ReleaseFast
benchmark workflow, `perf` commands, allocation and scaling analysis, data-layout
guidance, and the validation expected for engine optimizations.

## Repository Layout

- [platform-web/](platform-web/) contains the Roc platform package and target host
  artifacts used by Roc builds.
- [src/](src/) contains the Zig engine, native host, wasm host, specs, and
  benchmark support.
- [examples-web/](examples-web/) contains maintained Roc example apps and native specs.
- [www/](www/) contains the Zola site, static JavaScript runtime, user docs, and
  example-page metadata.
- [scripts/](scripts/) contains the Python drivers and repository checks.

## Native GUI spike

This worktree also contains `platform-gui`, backed by the shared Zig engine and
an app-independent Rust GPUI host in `crates/gpui-host`. Common Roc modules
live in `platform-shared/`; the preparation script copies its modules into each platform’s root, with the
generated files gitignored and checked by SHA-256. `platform-web` is the
browser platform. Run `scripts/bundle.sh --serve` to build and serve both Roc
platform bundles, including a downloadable `Counter.roc` that builds with
`roc build Counter.roc`. The GUI spike currently targets Linux x64/Wayland.
See [contributing](www/content/docs/contributing.md#native-gui-platform-spike)
for prerequisites, local examples, and current limitations.
