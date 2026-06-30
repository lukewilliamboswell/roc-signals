+++
title = "Contributing"
weight = 3
template = "page.html"
+++

# Contributing

This document is for people changing the platform, hosts, tests, or example
apps. For a user-oriented introduction, start with [`GUIDE.md`](GUIDE.md).

## Prerequisites

Install:

- Zig 0.16.0,
- Python 3,
- Node.js,
- Zola,
- the Tailwind CSS standalone CLI,
- Roc.

Local scripts use `roc` from `PATH` by default. Override it with `ROC_BIN`,
`ROC`, or `python3 scripts/test.py --roc-bin /path/to/roc`.

CI uses the official `roc-lang/setup-roc` GitHub Action. The repository does not
build Roc itself. The site build uses standalone command-line tools only; there
is no npm dependency or package manifest.

## Test Driver

Run the full suite from the repository root:

```sh
python3 scripts/test.py
```

The default suite builds the platform hosts, runs Zig checks and unit tests,
runs browser JavaScript contract tests, runs `roc check`, builds wasm apps, runs
native semantic specs on macOS, validates the bundled platform on macOS, and
runs the benchmark suite on macOS.

Useful targeted suites:

```sh
python3 scripts/test.py zig
python3 scripts/test.py browser
python3 scripts/test.py roc-check
python3 scripts/test.py wasm
python3 scripts/test.py native --native always
python3 scripts/test.py bundle --bundle always
python3 scripts/test.py bench --native always
```

Use `--keep-output` when debugging generated artifacts under `.test-out/`.

## Zig Build Steps

Zig owns the platform host artifacts and Zig-only checks. It does not build Roc
app executables.

```sh
zig build build-test-hosts
zig build test
zig build run-test-browser
```

`zig build build-test-hosts` copies host artifacts into Roc's platform target
layout:

- `platform/targets/x64mac/libhost.a`
- `platform/targets/arm64mac/libhost.a`
- `platform/targets/wasm32/host.wasm`

Roc app executables built during tests are written under `.test-out/` by
`scripts/test.py`.

## Bundles

Build host artifacts first, then create a platform bundle:

```sh
zig build build-test-hosts
scripts/bundle.sh
```

The bundle script uses `ROC_BIN`, `ROC`, or `roc` from `PATH`. By default it
writes the archive to the repository root. Set `BUNDLE_OUT_DIR` to choose a
different output directory. The Python bundle test writes archives under
`.test-out/bundles`.

## Static Site

Build and serve the static site with:

```sh
python3 scripts/serve.py
```

The helper builds the host artifacts, generates `www/static/signals.css` with
the standalone Tailwind CLI, runs Zola into `dist/`, creates a platform bundle
under `dist/platform/`, builds public example apps with `--target=wasm32`, and
copies downloadable source files under `dist/examples/<slug>/source/`.

Example source files in `dist/` have their local platform header replaced with
`SIGNALS_PLATFORM_URL` when set. Otherwise they point at the configured GitHub
Pages platform bundle URL. The wasm builds themselves use a temporary local
HTTP server for the freshly generated bundle, so development builds do not
depend on a published release.

Useful variants:

```sh
python3 scripts/serve.py --example ops-dashboard --port 9001
python3 scripts/serve.py --app-opt dev
python3 scripts/serve.py --platform-url https://example.com/platform/release.tar.zst
python3 scripts/serve.py --no-server
```

## Spec Language

Native app specs use semantic locators rather than positional DOM indices:

```txt
expect_visible role:heading name:"Checkout wizard"
fill label:"Email" "team@example.com"
expect_value label:"Email" "team@example.com"
check label:"Accept terms"
expect_checked label:"Accept terms" true
click role:button name:"Place order"
```

Supported locators:

- `role:<role> name:"<accessible name>"`
- `label:"<label>"`
- `text:"<exact text>"`
- `test_id:"<id>"`

Supported commands:

- `click <locator>`
- `fill <locator> "<text>"`
- `check <locator>` and `uncheck <locator>`
- `expect_visible <locator>`
- `expect_absent <locator>`
- `expect_text <locator> "<text>"`
- `expect_value <locator> "<text>"`
- `expect_checked <locator> true|false`
- `expect_disabled <locator> true|false`
- `expect_updates <locator> <count>`

## Benchmark Mode

The Python driver builds benchmark binaries under `.test-out/bench-bin` and runs
them automatically in the default macOS suite. A built app binary also accepts
benchmark flags directly:

```sh
.test-out/bench-bin/signals-ops-dashboard-bench --bench-app --bench-name signals-ops-dashboard --bench-iterations 100 --bench-samples 3 examples/ops-dashboard/spec.txt
```

The host initializes a fresh app per iteration, applies the initial command
batch, then replays only action commands (`click`, `fill`, `check`, `uncheck`).
Expectation commands remain the semantic correctness suite used by
`python3 scripts/test.py native`.

## Roc API Shape

Apps import:

```roc
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui
```

`Signal`, `Html`, and `Ui` build pure descriptor trees:

- `Signal.Signal(a)` is an opaque typed descriptor.
- `Ui.state` introduces local state through a closure binder.
- `Ui.when` and `Ui.each` introduce explicit dynamic scopes.
- `Html` creates static markup, signal-backed text/attrs, and event bindings.

Apps no longer define `NodeValue` encode/decode boilerplate for row fixtures.
`NodeValue` is still an internal platform representation until confined erasure
removes it from the platform API.

## Host Boundary

The host calls `roc_ui_init` once, stores the returned boxed `Elem`, walks the
descriptor tree, evaluates signal expressions against host-owned state, applies
patches to the simulated DOM, and dispatches events through retained Roc
reducers. Branch and keyed-row scopes are disposed by the host when they leave
the active tree. Non-structural state changes patch only the dirty signal-backed
leaf sinks recorded in the retained descriptor stream; structural `when`/`each`
changes still rebuild the active stream while subtree-level DOM patching is
finished.

## Glue

Regenerate glue after changing exposed platform types or provided entrypoints:

```sh
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc src/signals platform/main.roc
```
