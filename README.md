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

## Try It Locally

Build and serve the static site with the examples:

```sh
python3 scripts/serve.py
```

Then open the local URL printed by the server. To use a fixed port:

```sh
python3 scripts/serve.py --port 8000
```

The examples live under [examples/](examples/). Each public example has its own
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

## Repository Layout

- [platform/](platform/) contains the Roc platform package and target host
  artifacts used by Roc builds.
- [src/](src/) contains the Zig engine, native host, wasm host, specs, and
  benchmark support.
- [examples/](examples/) contains maintained Roc example apps and native specs.
- [www/](www/) contains the Zola site, static JavaScript runtime, user docs, and
  example-page metadata.
- [scripts/](scripts/) contains the Python drivers and repository checks.
- [wip/NEXT_STEPS.md](wip/NEXT_STEPS.md) is the active backlog. Other files under
  [wip/](wip/) are focused design notes and research evidence that have not been
  folded into the enduring design.
