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

[Blueprint](https://github.com/lukewilliamboswell/roc-blueprint) provides the
pinned development tools. `Blueprint.roc` declares them and the repository's
tasks, and `Blueprint.lock` records the SHA-256 of every download. Install the
`blueprint` release that the platform URL in `Blueprint.roc` names (0.8.0): with
Nix, `nix profile install github:lukewilliamboswell/roc-blueprint/0.8.0`, or
download the `blueprint-<system>` binary from that release and check it against
the release's `blueprint.sha256`. It supports x86-64 and AArch64 Linux and Apple
Silicon macOS. The environment needs no Nix: every pinned tool is a release
download, verified on every use. It provides:

- Zig 0.16.0,
- Node.js 23.9.0 (the Wasm effect-stack tests need `--experimental-wasm-jspi`),
- Binaryen's `wasm-opt`, version 133 (every linked browser app requires the
  `--stack-check` post-link pass),
- Zola 0.22.1,
- the Tailwind CSS 3.4.17 standalone CLI (the site uses the v3 configuration).

Install these yourself:

- Python 3.12 or later, as `python3`,
- Git,
- GitHub CLI (`gh`), authenticated for release operations and optional
  attestation inspection,
- AFL++, for fuzzing campaigns only (see [Fuzzing](#fuzzing)),
- the Roc compiler named by the `roc` header in `platform-web/main.roc`.

Run a task with `blueprint run <task>`, passing the script's own arguments after
`--`, or enter the environment with `blueprint shell` and run the commands in
this guide directly. `blueprint tasks` lists the tasks:

```sh
blueprint run minici                  # python3 scripts/minici
blueprint run hosted                  # python3 scripts/minici hosted
blueprint run test -- zig --jobs 2    # python3 scripts/test.py zig --jobs 2
blueprint run serve                   # python3 scripts/serve.py
```

Local scripts use `roc` from `PATH` by default. Override it with `ROC_BIN`, or
with `python3 scripts/test.py --roc-bin /path/to/roc`. The scripts also read
`ROC`, but Blueprint reads `ROC` too, as the compiler that evaluates
`Blueprint.roc`, and refuses one of another version; select the compiler under
test with `ROC_BIN` when running through Blueprint.

CI sets up the same environment with roc-automation's `actions/setup-blueprint`,
installs the pinned compiler with the official `roc-lang/setup-roc` GitHub
Action, and runs the same tasks. The repository does not build Roc itself. The
site build uses standalone command-line tools only; there is no npm dependency
or package manifest.

Update a tool by changing its recipe in `Blueprint.roc`, then run
`blueprint update <program>` and review the new digests in `Blueprint.lock`.

Pull requests and pushes to `main` run a bounded hosted source gate: Zig and
browser contracts, Roc checks and tests, Wasm builds and size budgets, fuzz
corpus replay, and ordinary native semantic specs. Change selection adds the
site job only when its inputs are affected. `Platform source` is the required
aggregate check. Exact archive creation and release-URL example smoke tests
belong to the release workflow, which validates the candidate before
publication. Pages deploys the supported release, not development builds from
ordinary pushes.

Compiler pins live in the platform header and every web example header,
including internal web fixtures. `.github/roc-nightly.json` selects all of them
for coordinated compiler updates; adding an example requires registering its
header there. Public web dependency URLs remain unchanged during these updates. Run
`python3 scripts/toolchain.py --check --roc-bin /path/to/roc` to validate the
selected roots and installed compiler. The nightly bot advances those pins while
preserving release URLs and automatically merges only a passing pin-only PR.

## CI intent and runner matrix

Use this section as the runner contract when changing CI. Keep workflow names,
build commands, change selection, and this matrix consistent. A job's operating
system identifies the boundary it can test; it does not select a release build.

| Workflow / job | When and purpose | Artifact and build mode | Evidence |
| --- | --- | --- | --- |
| `CI` / Hosted source tests | Affected PRs; all main pushes and manual CI runs | Current web/shared sources; development native checks, ReleaseSmall Wasm hosts and size-optimized Roc Wasm apps | Zig and JS contracts, Roc checks/tests, fuzz corpus replay, Wasm builds, native specs, size budgets |
| `CI` / Documentation and site | Affected PRs; all main pushes and manual CI runs | Current documentation and templates | Zola validation |
| `Web host inputs` | Explicit dispatch; validate and optionally publish independent host outputs | Complete web host set from current sources; final package uses Zig ReleaseSmall | Native/Wasm application checks and host archive packaging |
| Release workflow | Explicit dispatch; validate or publish the assembled product | Exact locked host and dependency releases | The package served from fresh caches and smoke-tested |

The intended profile policy is Debug for ordinary native development and
ReleaseSmall for web packages. ReleaseSafe is for optimized checks that retain
Zig's runtime safety checks, such as fuzzing. Application boundary validation
must remain active in every mode; `std.debug.assert` is not a production
contract check.

The hosted source gate retains production-mode Wasm builds and size budgets,
plus Debug/ReleaseSmall effect-stack checks. The current Roc Wasm backend
requires `--opt=size` for the maintained `two-row-types` fixture, and the Wasm
integration suite builds a temporary ReleaseSmall web bundle to stay within the compiler's
package-size limit. This is a documented exception to development-only PR builds;
it does not publish a release candidate. Full fault, benchmark, and coverage
campaigns remain explicit local suites. Dependency
producer workflows have their own recipe-specific triggers and probes; an
ordinary host or app edit does not rebuild third-party libraries.

Host producers run only by explicit dispatch. Dispatching on a branch validates
a candidate without publication; publishing requires `main` and the release
workflow's remaining gates. Ordinary CI never collects temporary debugger
artifacts or creates release bundles. Add a focused regression test or an
explicit investigation workflow when diagnosing a failure.

`test_ci_changes.py` protects job selection. Keep the checks tied to these
behavioral boundaries rather than copying entire workflow files into tests.

## Pre-commit CI check

Run the mini-CI entry point before committing:

```sh
python3 scripts/minici
```

It runs every locally reproducible CI area: selection checks, the complete web
and shared source suite, fuzz corpus validation, coverage on macOS, published
examples, release archive validation, and the documentation site. Hosted CI uses
the `hosted` mini-CI target for bounded pull-request feedback; the default local
run additionally covers the slower fault, benchmark, bundle, and coverage
campaigns. Platform-specific linking and archive checks still run on their
corresponding CI runners.

The source, smoke, and hosted gates also run one optimized paired Wasm benchmark
sample to catch reporting and runtime-registry drift. This checks semantic and
wire parity, not a timing threshold, followed by an untimed command-storage
retention and remount regression on the diagnostic artifact.
They also check Rows builder and parent-publication work, then run a bounded
allocation-scaling sample with independently retained generations. These gates
assert work and ownership; they do not impose machine-dependent timing limits.

During investigation, pass one or more target names, such as
`python3 scripts/minici hosted`, but run the complete command before
pushing.

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
python3 scripts/test.py wasm-bench --roc-bin /path/to/roc
python3 scripts/test.py native --native always
python3 scripts/test.py fault --native always
python3 scripts/test.py bundle --bundle always
python3 scripts/test.py bench --native always
python3 scripts/test.py size --roc-bin /path/to/roc
```

The browser contracts include a Wasm effect-stack fixture in both Debug and
ReleaseSmall modes. It checks overlapping suspensions, reverse-order completion,
interleaved host calls, and memory growth. Run it alone with
`zig build run-test-effect-stack`. This fixture requires Node with
`--experimental-wasm-jspi` support (verified with Node 23.9.0); the build target
passes the flag. It tests the suspension substrate, not the full Roc effect
semantics.

`python3 scripts/test.py browser` additionally builds the Roc action and HTTP
fixtures with the selected compiler and runs them through the browser runtime.
These linked tests cover fresh reads in effect chains, overlapping HTTP
completions, UTF-8 response ownership, and shutdown/remount while work is pending.
The `wasm` suite also runs the flight-search browser scenario after building that
application. It checks that sorting does not refetch and that application-owned
generations reject older completions in an A → B → A request sequence without
canceling the earlier effects. Mount smoke tests wait for suspended-effect
shutdown before asserting that retained host values have been released.

`size` builds the ReleaseSmall browser host and the fixed fixture set in
`test/size/fixtures.toml` as production Wasm, then fails if any fixture's raw
or gzip size exceeds `test/size/budgets.toml`. It requires the selected
compiler pin, because a different compiler produces different sizes. The
budgets are explicit reviewed numbers; do not regenerate them to absorb a
regression. `scripts/wasm_size.py` also compares two reports
(`--compare before.json after.json`) and records attribution companions
(`--symbols`); see `docs/profiling.md` for the measurement practice.

`wasm-bench` is the manual Node/V8 performance workflow for the complete
production-controlled path from a DOM-double event through Wasm and command
execution. It builds paired ordinary and instrumented ReleaseFast hosts, but
uses only the ordinary production artifact for timings; the instrumented
companion supplies exact allocation and shared-engine diagnostics after parity
checks. Wall time is deliberately non-gating. See `docs/profiling.md` for case
selection, comparison, and profiler workflows.

For focused retained-collection scaling, run `python3 scripts/rows_scaling.py
--roc-bin /path/to/roc`. The deterministic builder and parent-publication probes
are `python3 scripts/test_rows_builders.py` and
`python3 scripts/test_rows_parent_publications.py --roc-bin /path/to/roc`;
see `docs/profiling.md` for their allocation and semantic contracts.

`fault` is the slower deterministic host-allocation campaign. It first runs
the focused native SCM fixtures normally to record their runtime host allocation
counts, then runs each allocation coordinate as an isolated process through the same
`--jobs` worker pool used by native specs. Ordinary specs default to half the
logical CPUs. Cases marked `serial_native_spec` in a benchmark manifest run
alone, with no overlapping workers, so large structural fixtures stay within a
predictable memory envelope without making the rest of the suite serial. Those
entries may also set `native_spec_timeout_seconds` when their intentionally
large workload needs more than the ordinary per-spec timeout.

Ordinary SCM execution and the `native` suite do not enable fault sweeping:
fast semantic feedback is the default for application authors. The sweep is an
explicit `fault` suite, while this repository's full `all` suite and CI include
it for a deliberately small set of platform-owned fixtures. Any other example
can opt individual cases in by listing their ids (paths relative to the specs
directory, or globs over them) under `fault_specs` in
`www/data/examples.toml`; `keyed-selector-churn` opts in `small_churn.scm`, a small
copy of its structural cases sized so every coordinate replays quickly.
Application projects can use the same field when their graph or lifecycle
shape warrants the additional coverage. Fault injection does not add syntax or
behavior to the `.scm` case itself, and it is deliberately not part of
`zig build test`.

To replay a reported coordinate directly, copy the command printed after
`replay:`. The worker interface is:

```sh
app --host-run-spec-json --host-fail-on-allocation 7 path/to/case.scm
```

Roc allocator internals are excluded from host coordinates: their physical
resize/remap attempts can vary with process memory layout and cannot report
recoverable OOM. Host-origin fault placements inside a Roc callback are reported
as skipped by the recoverable campaign because the erased callback ABI cannot return OOM or
unwind ownership. Real allocation failure there is a fatal poison-and-trap
boundary. Infallible command calls, including observer commands after an earlier
step committed, likewise report `skipped_fatal_command`: the native recoverable
sweep does not inject at these positions and does not claim they recovered.
Other selected host allocations must refuse and retry successfully without
partial publication.

The Wasm suite separately builds the coordinated-writes fixture with test-only
allocator exports and sweeps every allocation in a write-plus-observer host call.
It verifies poison, a bounded diagnostic, empty publication buffers, unchanged
browser DOM, no unpublished effect execution, detached event listeners, and
allocation-free idempotent containment. Recovery uses a fresh instance. This
linked-app fatal campaign complements native refusal/retry tests; it does not
turn arbitrary native crashes into accepted outcomes. Roc-allocator fatal
boundaries also have focused linked-host tests.

Each test-driver invocation owns a unique directory under `.test-out/`, so
concurrent suites cannot delete or overwrite one another's artifacts. Use
`--keep-output` when debugging; the driver prints the retained directory. Pass
`--output-dir PATH` when a script needs a predictable, newly-created path.

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

`zig build build-test-hosts` builds our host and installs independently released
musl inputs from `dependencies.lock.json` into Roc's platform target layout.
It verifies cached or downloaded dependency archives against the reviewed size
and SHA-256 pins in `dependencies.lock.json`; it never rebuilds musl or accepts
existing local libraries as a fallback. Published attestations remain available
for external provenance inspection, but ordinary builds do not require GitHub's
attestation service:

- `platform-web/targets/x64mac/libhost.a`
- `platform-web/targets/arm64mac/libhost.a`
- `platform-web/targets/x64musl/libhost.a`
- `platform-web/targets/x64musl/crt1.o`
- `platform-web/targets/x64musl/libc.a`
- `platform-web/targets/arm64musl/libhost.a`
- `platform-web/targets/arm64musl/crt1.o`
- `platform-web/targets/arm64musl/libc.a`
- `platform-web/targets/wasm32/host.wasm`

Roc app executables built during tests are written under the invocation's
printed `.test-out/run-*` directory by `scripts/test.py`.

## Dependency artifact releases

### Web host inputs

The manually dispatched `Web host inputs` workflow builds the four native web
spec hosts and the Wasm browser host for an independent host release. Ordinary
pull requests do not run this producer. It tests native and Wasm application
paths, then packages five target-confined archives under one immutable `deps-web-hosts-<version>` release. Each archive
and its reviewed lock entry records both its exact SHA-256 and the shared narrow
host-input fingerprint. Application modules, examples, platform API files,
documentation, and release packaging do not change that fingerprint.

Platform releases consume `web-host.lock.json`. Ordinary source checks
build the hosts needed by their selected suites; they do not produce release
archives. GitHub attestations remain available for external provenance inspection, while ordinary admission uses the reviewed content
hashes without calling an attestation service. The independently released musl
startup objects and libc archives remain final linker inputs rather than web
host outputs.

### musl

The `Dependency releases` workflow builds musl from `dependencies/musl.json`,
tests the exact archives on Linux x86-64 and AArch64, and checks that a second
build produces the same bytes. Pull requests validate without publication.
An explicit dispatch on `main` with a new `deps-musl-<version>` tag publishes
those tested archives with signed GitHub build provenance and a consumer lock.
The workflow does not compile the platform host or a Roc application.

To exercise the producer locally on Linux x86-64 with Zig 0.16.0, Git, and Make:

```sh
python3 scripts/build_musl.py --target x64musl --output /tmp/musl-candidate
python3 scripts/test_musl_artifact.py /tmp/musl-candidate/musl-x64musl.tar --target x64musl
python3 -m unittest scripts/test_dependency_artifacts.py
```

Use a fresh output directory for each build. Local candidate testing establishes
link behavior; producer attestations provide optional external provenance evidence.
Review the published `dependencies.lock.json` before adopting its exact size and
SHA-256 pins. Fetch and verify a selected locked artifact with Python alone:

```sh
python3 scripts/dependency_artifacts.py --lock dependencies.lock.json --artifact musl-x64musl --output /tmp/verified-musl
```

The default download cache is `~/.cache/roc-signals/dependencies`; `--cache` selects
another directory. Digest verification also runs on cached bytes.
The output retains the selected lock and a directory for each artifact, containing
its manifest, target files, and license notices. Existing output directories are
rejected. There is no unsigned fallback or automatic dependency upgrade.

The root `dependencies.lock.json` is the platform's reviewed dependency selection.
To update it, merge the selected entries from a successful dependency release's
lock, preserve entries for other dependency families, and run
the native and exact-bundle tests. Ordinary host builds reuse the selected release.
The web bundler stages dependencies from newly verified archives, includes the
selected lock, per-target manifests and license notices, and ignores mutable
development copies or unexpected libraries under `platform-web/targets`.

Publication refuses an existing tag or release. If a run stops during publication,
inspect the existing tag, assets, and attestations, and recover the tested bytes;
do not overwrite the release or rebuild under its existing identity.
Keep GitHub release immutability enabled for this repository. The publication
command attaches all assets before publishing; publication then locks their bytes
and the tag. Historical releases created before immutability was enabled remain
mutable and must not be described as having that protection.

Pull-request CI selects affected jobs from the complete merge-base diff using
`scripts/ci_changes.py`. Web and shared changes run browser/native source
checks. Published-example and release archive checks
belong to explicit release validation.
Known documentation paths run the site check. Shared engine changes, build
infrastructure, compiler/dependency locks, and unknown paths select every area.
Renames count at both their old and new paths. Main-branch pushes and manual
validation still run every area, and release workflows retain their full gates.
The required `Platform source` check verifies the selection job and requires
success from every selected job; it accepts a skip only for an unselected area.
New commits cancel superseded PR CI runs, but do not cancel main or release runs.

## Coverage

Native host coverage is a diagnostic tool for finding major gaps in the Zig
runtime and host tests. It runs the existing `signals_shared` and
`signals_host` Zig test roots under kcov, then merges their line coverage into
one report. This keeps direct `src/signals/` unit coverage and host-driven
coverage visible together.

This workflow supports macOS and Linux arm64. Linux x86_64 is currently
disabled because kcov cannot reliably read Zig DWARF on that target; run the
coverage check on a supported runner rather than interpreting its refusal as
a completed coverage pass.

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
| `structural` | generated root of sibling and nested `each` and `when` sites plus a sequence of live edits, mounted and edited through the native host with allocation failure injected at one input-chosen attempt (or, for one input in sixteen, every attempt) | published topology and document order match the model, nothing published or leaked after a refusal, retry on the same engine succeeds, commit and teardown never allocate |
| `sparse-rows` | generated `each` sites over one slot-table cell, plus a history of canonical stable-slot edit batches described as direct deltas, snapshots, stale-sibling deltas, rollbacks, or selection changes, applied in one world as described and in a second world as snapshots only | store order, dense-table and membership consistency, row identity across edits, document order, world agreement, and per-edit bounds on `rows_candidate_rows_visited`, `rows_membership_entries_rewritten`, and `selector_registry_visits`, with refusal sweeps on the mount and every direct edit |
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
python3 scripts/fuzz.py campaign --time 2h -j 2
python3 scripts/fuzz.py distill structural
python3 scripts/fuzz.py status
```

`run` rebuilds first, adds the committed regression inputs to the local seed
corpus (using one minimal seed if there are no inputs), fuzzes, and then prints throughput,
edge count, stability, and any saved crash inputs. It exits non-zero when a crash
was saved. Corpora persist under `.fuzz-out/<target>/corpus`, because inputs
AFL++ found interesting last time are the cheapest way back into deep engine
states. Local and CI campaigns use the same seeding path. `--resume` continues a
previous session's queue rather than importing new seeds, and `clean` discards both.

Watch `stability`, which should sit near 100%. A lower number means the target is
not deterministic for a fixed input, which breaks the reference-model comparison
and must be fixed before any crash it reports can be trusted.

`campaign` is `run` with one total budget split by weight rather than the same
time per target: the subsystem targets saturate their queues in minutes, so
each gets a two-minute floor, and the rest goes to `structural`, the one target
that drives the whole engine. The weights are the `CAMPAIGN_WEIGHTS` table in
`scripts/fuzz.py`; the nightly `fuzz.yml` workflow runs a campaign.

`distill <target>` carries a campaign forward. It runs `afl-cmin` over the live
queues, refuses anything that fails replay, and writes a capped, content-hash
named set into `test/fuzzing/corpus/<target>/` for the next campaign to start
from and for `check` to replay. `test/fuzzing/README.md` explains the cap.

### Prerequisites

Fuzzing needs AFL++ on `PATH`; Blueprint's `fuzz` task expects it from the
machine, since AFL++ publishes no relocatable release:

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

Build the app-independent web hosts and create the platform bundle:

```sh
scripts/bundle.sh
# Build and serve the bundle:
scripts/bundle.sh --serve --port 8000
```

The script uses `ROC_BIN`, `ROC`, or `roc` from `PATH`; use the pinned compiler.
Archives and `bundles.json` default to `.test-out/bundles`. `BUNDLE_OUT_DIR` or
`--output-dir` changes that root, and `--no-build` reuses prepared hosts.

For the separate browser JavaScript artifact, run `python3 scripts/bundle_browser.py`.

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
python3 scripts/test.py wasm --keep-output --output-dir .test-out/inspect-wasm
node --no-maglev --experimental-wasm-jspi scripts/browser/mount_wasm_example.mjs .test-out/inspect-wasm/wasm/package-explorer.wasm package-explorer --telemetry-summary
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

Each generated Wasm artifact is validated with Node's WebAssembly compiler
before the build proceeds. A successful Roc compilation alone does not prove
that the browser can load the generated code; invalid artifacts fail the site
build with the affected file and validation diagnostic.

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

For public site content, documentation, or site config changes, run the browser
host and public apps production build without starting a server:

```sh
python3 scripts/serve.py --no-server --app-opt size
```

Routine Roc tests and native smoke builds use `--opt=dev` to keep feedback fast.
The pinned compiler's Wasm dev backend never re-selects a `Ui.when` branch it
has left ([roc-lang/roc#12560](https://github.com/roc-lang/roc/issues/12560),
reproduced in `repro/wasm-dev-when-reselect/`), so ordinary Wasm smoke builds
and `serve.py`'s default use `--opt=size` as a narrow workaround. Avoid
`--app-opt dev` for Wasm until then: it builds, but conditional views misbehave.
Switch those builds to `--opt=dev` once the pinned compiler contains the fix. Keep artifact validation
enabled; compiler exit status alone does not establish that a Wasm artifact is
valid. Production site builds use `--app-opt size`; both modes write `dist/`.

## Releases

Keep user-facing changes and migration instructions in `releases/unreleased.md`,
reviewed alongside the implementation. Before publishing, rename it to
`releases/<exact-release-tag>.md` (unprefixed SemVer, such as `0.2.0-rc1`),
replace the unreleased heading with that version, and name the explicit
source → target version in the migration section. Create a fresh unreleased file
when work on the next release begins. Published notes describe that upgrade;
do not rewrite them to follow later APIs. The site guides document the supported
API and link to releases rather than duplicating version-specific instructions.

Dispatch the release workflow (`.github/workflows/release.yml`) on `main` with
`release_tag` and `validate_only: false`.
The release guard explicitly permits exact-nightly bootstrap; it does not claim
a stable Roc compiler exists. Preparation records the final source SHA, downloads
and content-hash verifies the immutable web hosts and external linker inputs,
then runs `roc bundle`. It builds no Zig code. The result is one web platform
archive and `signals-examples.zip`, whose app headers name the final asset URL.
`signals-release.json` records those URLs, SHA-256 digests, sizes, input locks,
and the compiler pin.

To exercise preparation locally:

```sh
python3 scripts/release.py prepare --version 0.2.0-rc3
python3 scripts/release.py check
python3 scripts/release.py verify
```

Preparation requires a clean committed checkout so its source SHA identifies the
actual inputs. Output defaults to ignored `.release-out/` and must be empty;
retain an existing candidate when investigating or recovering a release. Each
smoke runner downloads the same candidate, serves the exact platform archive over
loopback, verifies every extracted app header, and runs the web smoke paths:
every web app builds for Wasm and uses the native spec host where available.
Only those already-tested bytes reach the single publishing job.
`validate_only: true` runs the complete flow without creating a tag or release.

Packaging changes do not rebuild the host. `web-host.lock.json` selects
immutable host releases whose narrow source fingerprints must match the
checkout; packaging and publication refuse a lock that does not.
`dependencies.lock.json` independently selects the external linker inputs.
Ordinary admission uses the recorded byte counts and SHA-256 hashes without an
attestation service. The publishing job additionally attests the exact bundle,
example archive, and release manifest for users who want external provenance.

Ordinary publication rejects any existing tag or release. After partial
publication, inspect the tag SHA and every existing asset against the retained
`signals-release.json` and original Actions artifacts. Preserve matching files;
upload only missing original assets through a reviewed recovery operation, verify
fresh downloads, then resume deployment/follow-up. Do not rerun preparation from
a moving branch, overwrite assets, or move a tag. If the original artifacts cannot
be recovered, prepare a new version rather than claiming the old identity.

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
setup accepts `initial-location`, `initial-visibility`, `initial-online`,
`local-storage`, `session-storage`, `manual-effects`, and the same scripted
HTTP answers accepted in test steps.

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
`examples-web/_fixtures/metric-semantics/`.

**Assert structural metrics exactly; bound engine-internal ones.** `rows_created`,
`rows_reused`, `rows_removed`, `scopes_created` and `scopes_disposed` are
semantic: they describe what the reconciler did, and an exact assertion is a
real regression test. `dirty_source_roots` counts internal work whose exact
value moves with unrelated engine changes — bound that with
`expect-metric-delta-at-most` so an unrelated improvement does not fail an
unrelated spec.

Do not assert `patches_emitted` in a spec. It aggregates every render command,
so its value moves with any change to how work is emitted rather than to how
much work is done, and the bounds drifted far enough from the real numbers to
stop meaning anything: they were removed rather than re-fitted. Patch counts are
still worth watching, but through the benchmark metrics, where a number that
moves is compared against its own history instead of against a constant someone
wrote down once.

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

### Readable HTTP fixtures

The hosted `Http` functions run synchronously inside an effect on the native
spec host, so their results are declared ahead of time, either in `setup` for
mount-time effects or in `steps` before the step that triggers the request. A
response stub answers the next request for its URL; a reject stub answers the
next request for any URL. Error kinds are `invalid-request`, `network`,
`timeout`, `too-large`, and `unavailable`; `timeout` requires empty detail.
Headers are optional:

```lisp
(stub-http "feed" :url "https://example.test/feed" :status 200 :body "{\"items\":[]}")
(stub-http "feed" :url "https://example.test/feed" :status 201
  :headers (("content-type" "text/plain")) :body "")
(stub-http-reject "feed" :kind timeout :detail "")
```

Fields may appear in any order; each documented field is required exactly
once unless marked optional. Unknown fields, duplicate fields, invalid types,
and oversized values reject the spec.

These stubs simulate results and perform no network IO. They establish
application response and state behavior; real `fetch` behavior needs the
browser contract tests. A supplied result does not assert the request payload
the app emitted. Test request construction as pure application logic. The
harness currently exposes pending effect counts, not request-body assertions.

Supported async and lifecycle commands:

- `(manual-effects)` (setup only)
- `(expect-pending-effects <count>)`
- `(run-effect <occurrence-id>)`
- `(tick-interval <period-ms>)`, `(tick-interval-if-active <period-ms>)`
- `(expect-interval <period-ms> <count>)`
- `(expect-cleanup "<cleanup-name>" <count>)`

Supported metric commands:

- `(mark-metrics)`
- `(expect-metric-delta <metric-name> <delta>)`
- `(expect-metric-delta-at-most <metric-name> <delta>)`

Quoted values are unescaped (`\n`, `\t`, `\\`, `\"`) for every command that
takes one, including `fill`, `change`, `select-option`, `key-down`, and the
`expect-text` / `expect-value` / `expect-attr` comparison values.

`expect-pending-effects` asserts an absolute count, not a delta. In manual
mode, `run-effect` executes one admitted occurrence's whole closure using the
installed service stubs. Choose occurrence order to test stale results; the
spec does not simulate suspension points inside an effect. The retired task
settlement and pending/canceled-task commands are rejected.

`real-click` dispatches `pointerdown -> pointerup -> click` through the
simulated propagation path, including capture/bubble, `self`, and stop policy.
Use it for nested controls where parent event flow matters; use `click` for a
direct unit click binding on one target. For buttons inside forms, omitted
`type` behaves as submit, `type="submit"` submits, and `type="button"` stays
click-only. Reset buttons dispatch app-managed prevent-default `reset` bindings.
Checkbox controls use the checked-change default path even without a click
handler. `submit` is for app-managed forms and requires a unit submit binding
from `Html.on_submit_prevent_default`. `custom-event` sends its detail argument
as `event.detail`, which reducers built with `State.update_detail` receive as text.

Common metric names include `dirty_source_roots`, `rows_reused`,
`rows_created`, `rows_removed`, `scopes_created`, `scopes_disposed`,
`stream_nodes_scanned`, `stream_nodes_scanned_events`,
`render_indexes_refreshed`, `active_intervals_synced`,
`active_graph_records_rebuilt`, `signal_record_table_rebuilt`,
`selector_members_dirtied`, `selector_registrations`,
`selector_memberships_released`, `selector_key_bytes_copied`,
`selector_registry_visits`, `retained_alloc_delta`,
`host_retained_alloc_delta`, and `host_retained_bytes_delta`. The authoritative
list lives in `src/spec/spec_runner.zig`.

## Benchmark Mode

The Python driver builds benchmark binaries under the printed run directory's
`bench-bin/` subdirectory when the bench suite runs. The default `all` suite
includes benchmarks on supported native hosts; use
`python3 scripts/test.py bench --native always --keep-output --output-dir .test-out/inspect-bench`
to retain a predictable copy for direct inspection. A built app binary also
accepts benchmark flags directly:

```sh
.test-out/inspect-bench/bench-bin/signals-data-grid-bench --host-bench-app --host-bench-name signals-data-grid --host-bench-iterations 100 --host-bench-samples 3 --host-entropy-seed 0 examples-web/data-grid/specs/initial-mount.scm
```

The driver supplies the same deterministic entropy seed as the native SCM
suite. The host initializes a fresh app per iteration, applies SCM setup and settles
mount-time effects through the same pre-step path as a semantic test, then
replays each typed operational command through the production `SpecRunnerCtx`
and its ordinary event/effect path. Before accepting measurements, the first
replay also executes every expectation and metric assertion in sequence. Later
warmup and sample iterations omit assertions because repeatable benchmark
operations can deliberately evolve data beyond the scenario's one-replay
expected values. Benchmark code attaches only timing and command-count
observation around operational commands. This keeps the benchmark exercising
and validating the behavior developers actually ship instead of a parallel
simulation of it.

The keyed fixture also has a production browser adapter under
`benchmarks/js-framework-benchmark/roc-signals-keyed/`. Build and verify it with:

```sh
cd benchmarks/js-framework-benchmark/roc-signals-keyed
npm ci
ROC_BIN=/path/to/roc npm run build-prod
npm run verify
```

This produces a ReleaseFast Wasm host, a Roc `--opt=speed` app, and
the matching shared runtime modules. The local verifier checks DOM structure
and keyed identity semantics; comparative browser timings and memory numbers
must come from the official js-framework-benchmark runner. See
`docs/profiling.md` and the adapter README for the copied-directory workflow and
known submission-policy gaps.

## Roc API Shape

Apps import:

```roc
import pf.Elem
import pf.Html
import pf.Signal
import pf.Ui
```

`Signal`, `Html`, and `Ui` build pure descriptor trees:

- `Signal.Signal(a)` is an opaque typed descriptor.
- `Ui.state` introduces local state through a closure binder.
- `Ui.when`, `Ui.switch`, and `Ui.each` introduce explicit dynamic scopes.
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
`Ui.each` changes are applied through local active-stream splices, row moves,
and affected event-binding refreshes rather than a full root rebuild.

`Ui.each` retains each immutable `Rows(item)` generation behind its app-compiled
capability. `Rows` owns key projection, cached exact keys, stable item slots,
and the transition from its immediate parent. The engine calls `describe`, then
`copy_delta` when that parent matches the site's committed generation, or
`copy_snapshot` for a fresh site, an explicit snapshot, or a nonmatching parent.
The callbacks write into bounded host sinks reserved before the copy; they do
not return temporary Roc lists of keys or items.

`compare_slots` and `clone_item` access typed items through the collection's
capability. The host does not inspect their layout or retain a typed item cell
for every row merely to reconcile keys. Candidate generations and row changes
stay provisional until an allocation-free commit publishes the structural
change. Use the Rows delta/snapshot work counters to distinguish sparse edits
from full snapshot reconciliation when testing update costs.

## Glue

Regenerate glue after changing exposed platform types or provided entrypoints:

```sh
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc src/signals platform-web/main.roc
zig fmt src/signals/roc_platform_abi.zig
```

Use the `ZigGlue.roc` from the same Roc commit named by the `roc` header in `platform-web/main.roc`. The host
uses the generated types' public `incref` and `decref` methods; generated helper
functions are implementation details and must not be made public by hand.
