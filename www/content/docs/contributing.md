+++
title = "Contributing"
description = "Working on the platform itself — toolchain, test driver, coverage, bundles, and releases."
weight = 12
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
python3 scripts/test.py roc-test
python3 scripts/test.py wasm
python3 scripts/test.py native --native always
python3 scripts/test.py fault --native always
python3 scripts/test.py bundle --bundle always
python3 scripts/test.py bench --native always
```

`fault` is the slower deterministic host-allocation campaign. It first runs
the focused native SCM fixtures normally to record their runtime host allocation
counts, then runs each allocation coordinate as an isolated process through the same
`--jobs` worker pool used by native specs.

Ordinary SCM execution and the `native` suite do not enable fault sweeping:
fast semantic feedback is the default for application authors. The sweep is an
explicit `fault` suite, while this repository's full `all` suite and CI include
it for a deliberately small set of platform-owned fixtures. Application
projects can opt selected cases into an explicit fault run when their graph or
lifecycle shape warrants the additional coverage. Fault injection does not add
syntax or behavior to the `.scm` case itself, and it is deliberately not part
of `zig build test`.

To replay a reported coordinate directly, copy the command printed after
`replay:`. The worker interface is:

```sh
app --run-spec-json --fail-on-allocation 7 path/to/case.scm
```

Roc allocations and host allocations inside a Roc callback are reported as
skipped because the current ABI cannot return OOM from that boundary. Other
selected allocations must either be absorbed by the allocator, or refuse and
retry successfully without partial publication. Roc-allocator and
fatal-boundary campaigns are tracked separately.

Use `--keep-output` when debugging generated artifacts under `.test-out/`.

For small documentation edits that do not change behavior or coverage claims,
run the lightweight tidy gate:

```sh
git diff --check
zig build run-check-tidy
```

Track active work in issues and pull requests. Temporary spike notes should not
be merged; fold enduring conclusions into `design.md`, maintained documentation,
tests, or local code comments, then remove the notes.

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

## Known-failure ratchet

The example spec suites run to completion - every wasm mount and every native
spec, each in its own process - and the run is judged at the end against
`test/known-failures.txt`, the list of specs currently expected to fail:

- a failure that is not listed is a regression and fails the run;
- a listed spec that now passes also fails the run, until its line is removed;
- `python3 scripts/test.py ... --update-known-failures` removes the lines that
  passed. It never adds one.

So the list only shrinks by fixing things. Accepting a new failure means adding
its line by hand with a comment saying why, where a reviewer will see it. Keys
are `native <example>/<spec>.scm` and `wasm <example>`; filters and shards only
judge the specs that actually ran. `--fail-fast` still stops at the first
failing example when you want a quick signal.

## Fuzzing

Fuzz targets live in `test/fuzzing/`, one file per target, and are built through
[zig-afl-kit](https://github.com/bhansconnect/zig-afl-kit) against a system
AFL++.

Most of them are not byte fuzzers. The engine is a deterministic state machine
whose interesting failures come from *sequences* of individually reasonable
operations, so those targets decode the fuzzer's bytes into a valid program - a
signal graph, a run of source updates, a list of keyed-row edits - and then check
the engine against a deliberately slow reference model that recomputes
everything from scratch. Random bytes fed directly to the engine would be
rejected at the boundary long before reaching the behavior worth testing.

| Target | Shape | What it checks |
| --- | --- | --- |
| `propagation` | generated DAG plus update sequence | dependency order, glitch freedom, equality cutoffs, diamond deduplication, one evaluation per node per generation |
| `keyed-scopes` | generated row edits and branch flips | key identity across insert/remove/reorder, scope retirement, reuse barriers, complete disposal |
| `structural` | generated initial root of sibling and nested `each` sites, mounted through the native host with allocation failure injected at a chosen or every preparation attempt | published topology matches the model, nothing published after a refusal, retry on the same engine succeeds, commit and teardown never allocate |
| `ownership` | generated capability and value routing | retained-value and callable ownership balance, rejection of mismatched routing |
| `boundary` | raw bytes | schema and extraction-plan parsing: truncation, trailing bytes, invalid UTF-8, duplicate fields |

The engine-driving targets reach the engine through `native_host.fuzz_fixtures`,
the same fixture kit the native host tests use. The fuzz build compiles the
native host with the `fuzz_fixtures` build option so that test-only machinery
is available outside `zig test`.

`python3 scripts/fuzz.py` drives all of this. It owns the target list, the
corpus layout, the AFL++ environment variables, and crash triage, so none of
that has to be remembered or retyped:

```sh
python3 scripts/fuzz.py list
python3 scripts/fuzz.py run propagation --time 10m
python3 scripts/fuzz.py run all --time 5m -j 4
python3 scripts/fuzz.py status
```

`run` rebuilds first, seeds an empty corpus, fuzzes, and then prints throughput,
edge count, stability, and any saved crash inputs. It exits non-zero when a crash
was saved. Corpora persist under `.fuzz-out/<target>/corpus`, because inputs
AFL++ found interesting last time are the cheapest way back into deep engine
states; `--resume` continues a previous session, and `clean` discards both.

Watch `stability`, which should sit near 100%. A lower number means the target is
not deterministic for a fixed input, which breaks the reference-model comparison
and must be fixed before any crash it reports can be trusted.

### Prerequisites

Fuzzing needs AFL++ on `PATH`:

```sh
sudo apt install afl++   # or: brew install afl++
```

Without it, the build still succeeds and produces the repro executables only, so
a crash found on a fuzzing machine stays reproducible everywhere:

```sh
python3 scripts/fuzz.py build --no-afl
```

The underlying build steps are `zig build build-fuzz` for the repro executables
and `zig build build-fuzz -Dfuzz` to also link the AFL++ persistent-mode
executables.

### Reproducing a crash

`status` lists saved crash inputs and the command to replay each one. The repro
executables need no AFL++ and print the generated program and the operation
sequence that led to the failure:

```sh
python3 scripts/fuzz.py repro propagation .fuzz-out/propagation/out/primary/crashes/<file> --verbose
```

Shrink a large input first:

```sh
python3 scripts/fuzz.py minimize propagation <crash-file>
```

Then turn the minimized case into a focused Zig test beside the seam it broke,
or a native semantic spec if the failure is application-visible, and fix the
engine. The crash file itself is not the regression test; a fuzzer finding is
only finished once the invariant it violated is asserted somewhere permanent.

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
node scripts/browser/mount_wasm_example.mjs .test-out/wasm/package-explorer.wasm package-explorer --telemetry-summary
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
python3 scripts/serve.py --example package-explorer --port 9001
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

```lisp
(test "checkout succeeds"
  (steps
    (expect-visible (role heading :name "Team Checkout"))
    (fill (label "Email") "team@example.com")
    (expect-value (label "Email") "team@example.com")
    (check (label "Accept terms"))
    (expect-checked (label "Accept terms") true)
    (click (role button :name "Place order"))))
```

Put each independent case in its own `*.scm` file under the app's
`specs/` directory. The driver discovers files recursively and gives each one a
fresh app process. Keep pre-mount state in an optional `(setup ...)` form;
setup accepts only `initial-location`, `initial-visibility`, `initial-online`,
`local-storage`, and `session-storage`.

### Writing specs that do not rot

**Locate dynamic text by identity, not by content.** A `text:` locator matches
on rendered content, so it couples the locator to the value: change the value
and the element stops resolving, and the failure reads "no element has text ..."
rather than showing a diff. Give the element a `test_id` instead:

```roc
Html.paragraph_s_attrs(status, [Html.test_id("sync-status")])
```

```lisp
(expect-text (test-id "sync-status") "Synced 3 notes")
```

Note that `(expect-text (text "X") "X")` — the same string as both locator and
expected value — asserts only that an element with that text exists. It is
`(expect-visible (text "X"))` written the long way, and it cannot report a
value mismatch. Prefer a `test-id` locator with the value as the expectation.

**`dirty_source_roots` counts sources, not derived nodes.** It is 1 for almost
every interaction no matter how deep the graph. Use `derived_calls_into_roc`
(one per `map`/`map2`/`combine` evaluation) as the fine-grained budget, and
`propagation_prunes` to show an equality cutoff fired. See
`examples/_fixtures/metric-semantics/`.

**Assert structural metrics exactly; bound engine-internal ones.** `rows_created`,
`rows_reused`, `rows_removed`, `scopes_created` and `scopes_disposed` are
semantic: they describe what the reconciler did, and an exact assertion is a
real regression test. `patches_emitted` and `dirty_source_roots` count internal
work whose exact value moves with unrelated engine changes — bound those with
`expect-metric-delta-at-most` so an unrelated improvement does not fail an
unrelated spec.

**To see what actually rendered**, assert a deliberately wrong value on the
enclosing region. `expect-text` falls back to the concatenated descendant text
of a container that has no text of its own, so the failure prints the real
content:

```lisp
(expect-text (role region :name "Your Region") "PROBE")
```

Supported locators:

- `(role <role> :name "<accessible name>")`
- `(label "<label>")`
- `(text "<exact text>")`
- `(test-id "<id>")`

Supported action commands:

- `(click <locator>)`, `(real-click <locator>)`
- `(pointer-down <locator>)`, `(pointer-up <locator>)`
- `(pointer-enter <locator>)`, `(pointer-leave <locator>)`
- `(key-down <locator> "<key>" true|false)`
- `(focus <locator>)`, `(blur <locator>)`
- `(composition-start <locator>)`, `(composition-end <locator>)`
- `(change <locator> "<value>")`, `(select-option <locator> "<value>")`
- `(custom-event <locator> "<event-name>" "<detail>")`
- `(submit <locator>)`, `(fill <locator> "<text>")`
- `(check <locator>)` and `(uncheck <locator>)`

Supported assertions:

- `(expect-visible <locator>)`
- `(expect-absent <locator>)`
- `(expect-text <locator> "<text>")` — compares the element's own text; for a
  container with no text of its own, compares the concatenated descendant text
  instead, so a region can be asserted by its rendered content
- `(expect-value <locator> "<text>")`
- `(expect-attr <locator> <attr-name> "<value>")`
- `(expect-no-attr <locator> <attr-name>)`
- `(expect-checked <locator> true|false)`
- `(expect-disabled <locator> true|false)`
- `(expect-updates <locator> <count>)`

Supported async and lifecycle commands:

- `(resolve-task "<task-name>" "<payload>")`
- `(resolve-stale-task "<task-name>" "<payload>")`
- `(reject-task "<task-name>" "<payload>")`
- `(tick-interval <period-ms>)`, `(tick-interval-if-active <period-ms>)`
- `(expect-pending-task "<task-name>" <count>)`
- `(expect-canceled-task "<task-name>" <count>)`
- `(expect-interval <period-ms> <count>)`
- `(expect-cleanup "<cleanup-name>" <count>)`

Supported metric commands:

- `(mark-metrics)`
- `(expect-metric-delta <metric-name> <delta>)`
- `(expect-metric-delta-at-most <metric-name> <delta>)`

Quoted values are unescaped (`\n`, `\t`, `\\`, `\"`) for every command that
takes one, including `fill`, `change`, `select-option`, `key-down`, and the
`expect-text` / `expect-value` / `expect-attr` comparison values.

`expect-pending-task` asserts an absolute count, not a delta. To prove that an
interaction did *not* start a request while another is in flight, assert that
the count is unchanged and that `expect-canceled-task` is still 0.

`resolve-stale-task` requires a previously canceled request for that task name;
without one the host reports `fake stale task result had no matching canceled
request`. Force a supersede first.

`real-click` dispatches `pointerdown -> pointerup -> click` through the
simulated propagation path, including capture/bubble, `self`, and stop policy.
Use it for nested controls where parent event flow matters; use `click` for a
direct unit click binding on one target. For buttons inside forms, omitted
`type` behaves as submit, `type="submit"` submits, and `type="button"` stays
click-only. Reset buttons dispatch app-managed prevent-default `reset` bindings.
Checkbox controls use the checked-change default path even without a click
handler. `submit` is for app-managed forms and requires a unit submit binding
from `Html.on_submit_prevent_default`. `custom-event` sends its detail argument
as `event.detail`, which reducers built with `State.on_detail` receive as text.

Common metric names include `dirty_source_roots`, `patches_emitted`, `rows_reused`,
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
.test-out/bench-bin/signals-data-grid-bench --bench-app --bench-name signals-data-grid --bench-iterations 100 --bench-samples 3 examples/data-grid/specs/initial-mount.scm
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
zig fmt src/signals/roc_platform_abi.zig
```

Use the `ZigGlue.roc` from the same Roc commit named by `.roc-version`. The host
uses the generated types' public `incref` and `decref` methods; generated helper
functions are implementation details and must not be made public by hand.
