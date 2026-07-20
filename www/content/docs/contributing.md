+++
title = "Contributing"
weight = 3
template = "page.html"
+++

# Contributing

This document is for people changing the platform, hosts, tests, or example
apps. For a user-oriented introduction, start with the
[Guide](@/docs/guide.md).

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
native semantic specs on macOS and Linux, validates the bundled platform on
macOS and Linux, and runs the benchmark suite on macOS and Linux.

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

For small documentation or evidence-note edits that do not change behavior or
coverage claims, run the lightweight tidy gate:

```sh
git diff --check
zig build run-check-tidy
```

`wip/NEXT_STEPS.md` is the active backlog. Keep completed phase notes,
benchmark snapshots, and retired findings in focused design/evidence notes or
git history instead. When a backlog or evidence-note edit changes a current-state
or coverage claim, run the focused gate named by the linked note.

## Zig Build Steps

Zig owns the platform host artifacts and Zig-only checks. It does not build Roc
app executables.

```sh
zig build build-test-hosts
zig build test
zig build run-test-browser
```

For focused Zig host unit work, filter Zig tests at build time:

```sh
zig build run-test-zig -Dtest-filter="signals host"
```

`zig build build-test-hosts` copies host artifacts into Roc's platform target
layout:

- `platform/targets/x64mac/libhost.a`
- `platform/targets/arm64mac/libhost.a`
- `platform/targets/x64musl/libhost.a`
- `platform/targets/x64musl/crt1.o`
- `platform/targets/x64musl/libc.a`
- `platform/targets/arm64musl/libhost.a`
- `platform/targets/arm64musl/crt1.o`
- `platform/targets/arm64musl/libc.a`
- `platform/targets/wasm32/host.wasm`

Roc app executables built during tests are written under `.test-out/` by
`scripts/test.py`.

## Coverage

Native host coverage is a diagnostic tool for finding major gaps in the Zig
runtime and host tests. It runs the existing `signals_shared` and
`signals_host` Zig test roots under kcov, then merges their line coverage into
one report. This keeps direct `src/signals/` unit coverage and host-driven
coverage visible together.

Run a fresh coverage pass from the repository root:

```sh
python3 scripts/coverage.py
```

Reuse the previous kcov output for faster inspection:

```sh
python3 scripts/coverage.py --use-last-run --top 20
python3 scripts/coverage.py --use-last-run --format lines --file engine --context 5
python3 scripts/coverage.py --use-last-run --format json --top 10
```

Coverage output is written under `kcov-output/native-host/`. The script prints a
ranked summary by uncovered line count; use the `lines` format to inspect the
actual uncovered source ranges before adding focused tests.

When coverage points at generated ABI ingestion, keep `roc_platform_abi.zig` as
the raw layout contract and add a small borrowed typed view above it instead.
Prefer seam-level tests for those typed views before adding broad host/spec tests;
that gives Zig exhaustive switches and named payload fields while preserving the
external ABI exactly.

When coverage points at large engine paths, first look for engine-adjacent logic
that can live in a focused `src/signals/` module, such as descriptor bookkeeping,
effect lifecycle state, or borrowed ABI views. Unit-test those seams directly and
keep host/spec tests for cross-module behavior. If a seam retains or releases
callable identity, allocate real retained Roc callables in tests instead of
using stack pointers or boxed `U64` stand-ins.

Run coverage after substantial changes to `src/signals/`, `src/native_host.zig`,
the native spec runner, the simulated DOM, allocation diagnostics, or host
runtime behavior. The coverage job is intentionally separate from
`python3 scripts/test.py` because kcov is slower and mainly useful when
investigating test gaps.

## Bundles

Build host artifacts first, then create a platform bundle:

```sh
zig build build-test-hosts -Doptimize=ReleaseSmall
scripts/bundle.sh
```

The bundle script uses `ROC_BIN`, `ROC`, or `roc` from `PATH`. By default it
writes the archive to the repository root. Set `BUNDLE_OUT_DIR` to choose a
different output directory. The Python bundle test writes archives under
`.test-out/bundles`.

To test an existing bundle archive instead of rebuilding one:

```sh
python3 scripts/test.py bundle --bundle always --bundle-ref path/to/bundle.tar.zst
```

The test driver refuses non-local platform URLs by default so development tests
exercise workspace changes. Use a local bundle path during development. When
intentionally verifying a published release URL, pass
`--allow-release-platform-url`.

The browser runtime checks the wasm exports before mounting. A runtime/bundle
skew fails early with a `Signals wire protocol version mismatch` or
`Signals wire protocol feature mismatch` error; deploy `www/static/signals.mjs`
and app wasm built from the same compatible platform release.

To inspect command-wire byte traffic for a built wasm app, keep wasm outputs and
mount an artifact with telemetry summarization:

```sh
python3 scripts/test.py wasm --keep-output
node scripts/browser/mount_wasm_example.mjs .test-out/wasm/service-ops-center.wasm service-ops-center --telemetry-summary
```

Repeat the mount command for each public wasm app when refreshing a public-app
telemetry snapshot.

## Static Site

Build and serve the static site with:

```sh
python3 scripts/serve.py
```

The helper builds ReleaseSmall host artifacts, generates
`www/static/signals.css` with the standalone Tailwind CLI, runs Zola into
`dist/`, creates a platform bundle under `dist/platform/`, builds public
example apps with `--target=wasm32 --opt=size` by default, and copies
downloadable source files under `dist/examples/<slug>/source/`.

Example source files in `dist/` have their local platform header replaced with
`SIGNALS_PLATFORM_URL` when set. Otherwise they point at
`extra.release_platform_url` from `www/config.toml`, falling back to the
generated GitHub Pages platform bundle URL. The wasm builds themselves use a
temporary local HTTP server for the freshly generated bundle, so development
builds do not depend on a published release.

Useful variants:

```sh
python3 scripts/serve.py --example service-ops-center --port 9001
python3 scripts/serve.py --app-opt dev
python3 scripts/serve.py --host-opt Debug
python3 scripts/serve.py --platform-url https://example.com/platform/release.tar.zst
python3 scripts/serve.py --no-server
```

For public site content, documentation, or site config changes, use the browser
host + public apps build gate in both Roc optimization modes without starting a
server. Run these commands sequentially because both write `dist/`:

```sh
python3 scripts/serve.py --no-server --app-opt dev
python3 scripts/serve.py --no-server --app-opt size
```

## Releases

The `Release` GitHub Actions workflow is manually triggered. Provide the exact
release tag to publish, matching the URL you intend to put in
`www/config.toml`; the workflow builds ReleaseSmall host artifacts, creates the
platform bundle, tests the downloaded bundle on Intel and Apple Silicon macOS
runners, then creates a GitHub release with the bundle attached.

## Spec Language

Native app specs use semantic locators rather than positional DOM indices. They
are app-facing semantic tests, not a browser emulator; keep browser-only event
ordering and rendering details in JavaScript/browser contract tests.

```txt
expect_visible role:heading name:"Team Checkout"
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

Supported action commands:

- `click <locator>`
- `real_click <locator>`
- `pointer_down <locator>`
- `pointer_up <locator>`
- `pointer_enter <locator>`
- `pointer_leave <locator>`
- `key_down <locator> "<key>" true|false`
- `focus <locator>`
- `blur <locator>`
- `composition_start <locator>`
- `composition_end <locator>`
- `change <locator> "<value>"`
- `select_option <locator> "<value>"`
- `custom_event <locator> "<event-name>" "<detail>"`
- `submit <locator>`
- `fill <locator> "<text>"`
- `check <locator>` and `uncheck <locator>`

Supported assertions:

- `expect_visible <locator>`
- `expect_absent <locator>`
- `expect_text <locator> "<text>"`
- `expect_value <locator> "<text>"`
- `expect_attr <locator> <attr-name> "<value>"`
- `expect_no_attr <locator> <attr-name>`
- `expect_checked <locator> true|false`
- `expect_disabled <locator> true|false`
- `expect_updates <locator> <count>`

Supported async and lifecycle commands:

- `resolve_task "<task-name>" "<payload>"`
- `resolve_stale_task "<task-name>" "<payload>"`
- `reject_task "<task-name>" "<payload>"`
- `tick_interval <period-ms>`
- `tick_interval_if_active <period-ms>`
- `expect_pending_task "<task-name>" <count>`
- `expect_canceled_task "<task-name>" <count>`
- `expect_interval <period-ms> <count>`
- `expect_cleanup "<cleanup-name>" <count>`

Supported metric commands:

- `mark_metrics`
- `expect_metric_delta <metric-name> <delta>`
- `expect_metric_delta_at_most <metric-name> <delta>`

`real_click` dispatches `pointerdown -> pointerup -> click` through the
simulated propagation path, including capture/bubble, `self`, and stop policy.
Use it for nested controls where parent event flow matters; use `click` for a
direct unit click binding on one target. For buttons inside forms, omitted
`type` behaves as submit, `type="submit"` submits, and `type="button"` stays
click-only. Reset buttons dispatch app-managed prevent-default `reset` bindings.
Checkbox controls use the checked-change default path even without a click
handler. `submit` is for app-managed forms and requires a unit submit binding
from `Html.on_submit_prevent_default`. `custom_event` sends its detail argument
as `event.detail`, which reducers built with `State.on_detail` receive as text.

Common metric names include `nodes_recomputed`, `patches_emitted`, `rows_reused`,
`rows_created`, `rows_removed`, `scopes_created`, `scopes_disposed`,
`stream_nodes_scanned`, `stream_nodes_scanned_events`,
`render_indexes_refreshed`, `active_intervals_synced`,
`active_graph_records_rebuilt`, `signal_record_table_rebuilt`,
`stale_task_results_ignored`, `retained_alloc_delta`,
`host_retained_alloc_delta`, and `host_retained_bytes_delta`. The authoritative
list lives in `src/spec/spec_runner.zig`.

## Benchmark Mode

The Python driver builds benchmark binaries under `.test-out/bench-bin` when the
bench suite runs. The default `all` suite includes benchmarks on supported native
hosts; use `python3 scripts/test.py bench --native always` to force the focused
bench gate. A built app binary also accepts benchmark flags directly:

```sh
.test-out/bench-bin/signals-service-ops-center-bench --bench-app --bench-name signals-service-ops-center --bench-iterations 100 --bench-samples 3 examples/service-ops-center/spec.txt
```

The host initializes a fresh app per iteration, applies the initial command
batch, then replays commands classified as benchmark actions in
`src/bench/benchmark.zig` (user actions, task results, and interval ticks).
Expectation and metric assertion commands remain the semantic correctness suite
used by `python3 scripts/test.py native`.

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
- `Ui.when` and `Ui.each_str` introduce explicit dynamic scopes.
- `Html` creates static markup, signal-backed text/attrs, and event bindings.

Apps no longer define erased value encode/decode boilerplate for row fixtures.
Typed values cross the host boundary as capability-owned `HostValue` cells.

## Host Boundary

The host calls `roc_ui_init` once, stores the returned boxed `Elem`, walks the
descriptor tree, evaluates signal expressions against host-owned state, applies
patches to the simulated DOM, and dispatches events through retained Roc
reducers. Branch and keyed-row scopes are disposed by the host when they leave
the active tree. Non-structural state changes patch only the dirty signal-backed
leaf sinks recorded in the retained descriptor stream. Structural `when` and
`each_str` changes are applied through local active-stream splices, row moves,
and affected event-binding refreshes rather than a full root rebuild.

## Glue

Regenerate glue after changing exposed platform types or provided entrypoints:

```sh
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc src/signals platform/main.roc
```
