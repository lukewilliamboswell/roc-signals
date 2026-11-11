+++
title = "Contributing"
description = "Working on the platform itself: tools, tasks, tests, docs, performance, compilers and releases."
weight = 17
template = "page.html"
+++

# Contributing

This page is for people changing the platform, its tests, the examples or this
site. The architecture and its rules are in
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md);
repository-wide review guidelines are in `AGENTS.md`, and Roc conventions in
the [Roc Style Guide](https://gist.github.com/lukewilliamboswell/241a4e8adb7c89c7e0e02f1d303a8fa1).

## Tools

[Blueprint](https://github.com/lukewilliamboswell/roc-blueprint) provides
every tool but the package compiler. `Blueprint.roc` declares the scripts'
Roc nightly (`roc-stable`), Zig, Node, Zola, Tailwind and roc-docs, and the
tasks below; `Blueprint.lock` records the SHA-256 of every download. Install
the `blueprint` release that `Blueprint.roc` names (no Nix is needed) and the
current Roc nightly as `roc` (see [Compilers](#compilers)). `blueprint shell`
opens a shell with the tools on `PATH`.

Chrome is the machine's `google-chrome` for now, because blueprint cannot yet
unpack Chrome for Testing's zip archives; `Blueprint.roc` has the pinned
recipe ready.

## Layout

| Path | Contents |
|---|---|
| `platform/` | The platform (`main.roc`): the engine (`Core.roc`), the authoring API (`Engine.roc`, `Html.roc`, `Worker.roc` with its payload format `Wire.roc`, and `Port.roc` with its message format `PortJson.roc`), the hosted effects a worker job calls (`Hosted.roc`, bound in both hosts and reached only through `Effects.roc`, which the platform root hands to the engine with each job, and `Files.roc`, whose `build!` opens a builder), the Wasm host (`host/host.zig`, with the typed heaps behind file handles in `host/resources.zig`), the browser runtime (`runtime.mjs` and its worker script `worker.mjs`), and the native spec runner (`SpecRunner.roc`, the `Scm.roc` parser, the `Dom.roc` oracle, `host/spec.zig` with its system services in `host/os_posix.zig` and `host/os_windows.zig`, and `host/kernel32.def`, the Windows host's imports). Also `engine.roc`, a package root over the same pure modules (all but `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc`) that the fuzz targets depend on, and the walk they share (`Soak.roc`) |
| `tests/` | Browser contract tests and the apps they drive (`tests/apps/`, for example `files` for file handles, `file-effects` for operations on files, `ports` for ports, `worker-typed` for the task API, `prepared` for preparations, `tasks` for jobs that read and build files, `outbox` for posting requests and `gather` for one question split over several jobs), the Chrome spec replay, and the release check helper |
| `fuzz/` | Fuzz targets of the shared support; each app's own target is its `main-fuzz.roc` |
| `examples/` | The example apps, each with its specs, and with any JavaScript of its own beside it (the Reading List's port handlers, `ports.mjs`; the simulated service of Conduit, Field Notes and the Status Page, `backend.mjs`); `examples/shared/` holds the JavaScript several examples load (the `plume-chart` and `worker-pool-panel` elements) |
| `cli/` | `signals.roc`, the tool app authors run to create, serve, build and test an app (below) |
| `benchmarks/` | The js-framework-benchmark adapter |
| `scripts/` | Roc scripts behind the tasks; shared modules in `scripts/src/` |
| `www/` | This site; `www/samples/` holds every code sample the docs show |

A module added to `platform/` for apps to import is listed in four places:
`exposes` in `platform/main.roc`, the package's list in `platform/engine.roc`
unless it reaches a hosted function, the release bundle's files in
`scripts/src/Release.roc`, and the API reference's modules in
`scripts/src/ApiDocs.roc`. A file added to the browser runtime is listed
in `SpecSuite.runtime_files` (`scripts/src/SpecSuite.roc`) and in
`RUNTIME_FILES` (`tests/browser/args.mjs`), which every copy site and
browser test reads.

An example is listed in `SpecSuite.apps`, so `check`, the release check
and the browser soak cover it, and in `www/data/examples.toml` with a page
under `www/content/examples/`. Its entry there gives its section of the
examples index, its feature chips and, where it helps, a line saying what
to try, and names every file its page loads: its scripts, the module of
port handlers (`ports`), its simulated service (`backend`) and the data it
downloads (`data`), each a file in its own directory, or a script in
`examples/shared/` (`shared`). `scripts/site.roc` copies exactly the files
named there. An example that talks to a service brings that service as its
own `backend.mjs`, whose default export returns a request handler; the
site turns it into the mount's `fetch`, and the soak and journeys serve
the same file over HTTP rather than a copy. The soak's tables in
`tests/browser/soak.mjs` give it a round trip and, for an app with ports
or a backend, the module that answers them. Its native soak, a
round-trip spec under its `specs/`, is listed in `Slow.native_soaks`, and
its fuzz target, if it has one, in `Targets.fuzz_targets`.

## Tasks

These are the development environment's Blueprint tasks, not an app's
[worker tasks](@/docs/workers.md).

| Task | What it does |
|---|---|
| `blueprint run check` | The pull-request gate (below) |
| `blueprint run check-slow` | Every fuzz target's declared examples, the native soak of each app's round-trip spec (`RUNNER --soak 48`, flat live allocations and bytes), and a long Chrome session per app |
| `blueprint run spec -- [--browser] [--filter GLOB] [APP...]` | Some apps' specs, natively and optionally in Chrome |
| `blueprint run platform` | Fetch and build the platform's link inputs, to build an app's `main.roc` by hand (a `main-fuzz.roc` needs none: `roc build --fuzz` fetches its roc-fuzz release) |
| `blueprint run jfb` | Build the js-framework-benchmark app and check its operations in Chrome |
| `blueprint run workers-scaling` | Measure worker jobs in Chrome on both candidate shipping builds of the Worker Lab: correctness, speedup by pool size, responsiveness, payloads, robustness sequences and memory, as tables for a pull request |
| `blueprint run fuzz -- [--time S] [TARGET...]` | A fuzz campaign |
| `blueprint run site -- [--base-url URL]` | Build the site, the API docs and the example apps into `dist/` |
| `blueprint run serve -- [DIR] [--port N]` | Serve `dist/` at `127.0.0.1:8000/roc-signals/`, its published path, or `DIR` at the root |
| `blueprint run release -- --version V` | Build the release assets into `dist-release/` |

To browse the site locally:

```sh
blueprint run site -- --base-url http://127.0.0.1:8000/roc-signals
blueprint run serve
```

The published site is main: every push to main that passes `check` deploys
CI's `blueprint run site` build to GitHub Pages.

Builds go to `.build/`; set `ROC_SIGNALS_BUILD_DIR` to use another directory,
for example to run two tasks at once.

## What `check` runs

1. Every script names the `roc-stable` nightly that `Blueprint.roc` pins, and
   no other Roc file names a compiler; every file `www/data/examples.toml`
   names exists, and every example is in a section of the examples index.
2. `roc fmt --check` over every Roc source, `roc test` on the platform, the
   engine package (`platform/engine.roc`), the tool (`cli/`) and the
   scripts, and the check that `cli/Bundle.roc` is what the release
   generates for a checkout.
3. The platform's link inputs for every target, a worker app's spec runner
   linked for macOS (`arm64mac`, `x64mac`) and Windows (`x64win`) from them,
   and the examples of the fuzz targets in `fuzz/` (the `.scm` parser, the
   worker wire format, the port message format and generated site trees).
4. The docs samples (below).
5. Every app's specs natively and in Chrome, the check that the browser
   runner handles every form of the grammar, then a deliberately broken spec
   that both runners must reject.
6. The runtime's unit tests in Node (the work monitor's aggregation and
   bounds, `tests/runtime/`), then its contract tests in Chrome: effects,
   controlled inputs, an outbox posted twice in one turn, worker jobs, the work monitor, a smoke of the worker
   scaling measurement (correctness, robustness sequences and memory; no
   timing ratios), file handles and their release, operations on files
   (page reads, uploads to a local server, digests and file URLs, with their
   bounds, failures and lifetimes), preparations and the pool's
   placement of their tasks' jobs, a preparation that fails and what each
   of its tasks then answers, ports with real handlers
   (`ports-browser.mjs`: the mount check, delivery policies, the payload
   bound, bytes and files both ways, containment), jobs that read and build
   files (`tasks-browser.mjs`: the handles each instance holds after a job, a
   large transform with bounded worker memory, the output bound, termination
   and unmounting mid-job, the page's import stubs, inline mode, where a job
   that reaches no worker effect answers and one that does is unavailable
   without poisoning the page, downloads into files and real saves), the
   Reading List's own port handlers against real IndexedDB in two tabs
   (`reading-list-journey.mjs`), the Log Explorer's preparation over a
   generated 64 MiB log, with its times and memory (`log-explorer-journey.mjs`),
   and the Conduit journey against the example's own simulated backend
   (`examples/conduit/backend.mjs`).
7. The js-framework-benchmark check.
8. The release dry run: the bundle, `runtime.mjs` and `worker.mjs`, the
   `signals.roc` tool's package and app, the examples archive with every app
   mounted by its check helper, and the release notes.
9. The tool, end to end (`scripts/src/ToolCheck.roc`): the dry run's
   `signals.roc` run from empty directories as an author runs it, on the
   counter and on the Worker Lab. `init`, `test` and `build`; every failure
   it explains, each by its sentence (a misused command line, no
   `main.roc`, `index.html` or specs, a failing spec, a build error, no
   `roc` on the PATH, a compiler other than the release's); the built
   `dist/` mounting from a plain static server in Chrome with jobs running
   in workers (`tests/browser/tool-dist.mjs`); and `serve` in Chrome
   (`tests/browser/tool-serve.mjs`: a busy port, content types, the reload
   script, a reload after an edit, and the overlay for a build error, a
   mount refusal and an engine fault).

Every spec must pass in both runners; there are no expected failures.

`check` runs on Linux. Blueprint does not run on Windows or Intel macOS, so
CI proves the native spec runner on the other systems itself: a Linux job
builds the link inputs, and runners on macOS (Apple silicon and Intel) and
Windows build a small app's and the worker apps' spec runners with `roc` and
run their specs, then two specs that must fail (a crash expected with the
wrong fault class, and a job past the runner's 30 s bound). The same jobs
run the `signals.roc` tool from the checkout's `cli/` on a new app beside
`platform/`: `init`, `test` (with a spec that must fail), `build`, and
`serve` answering with the right content types. A change to `cli/` that
touches how it names files, starts programs or serves pages waits for those
jobs too. A change to
`platform/host/` that touches one system's file (`os_posix.zig` serves
Linux and macOS, `os_windows.zig` Windows) is tested there and nowhere else,
so it waits for those jobs.

## Specs and contract tests

Application-visible behaviour is specified in `.scm` files beside each app and
runs in both runners from one parser, `platform/Scm.roc`. An unknown step
is a parse error, and both runners implement every step, with Chrome as the
reference for what it means. The language is
documented in [Testing](@/docs/testing.md).

A change to the wire protocol changes the engine's encoder and decoders,
`platform/Dom.roc`, both hosts (`platform/host/host.zig`,
`platform/host/spec.zig`), `platform/runtime.mjs`, `platform/worker.mjs`,
the contract tests under `tests/` and Appendix B of `design.md` together,
and bumps the protocol version.

## Docs samples

Every Roc code block on this site comes from a file under `www/samples/`,
shown with the `sample` shortcode:

```text
{{/* sample(file="todos/Todos.roc", region="row") */}}
```

A region is the lines between `# region NAME` and `# endregion NAME`. `check`
fails on an inline Roc block in a docs page, a missing sample or region, a
sample that does not type-check, and a sample directory with `specs/` whose
specs fail natively or in Chrome.

## Fuzzing

Every fuzz target is an ordinary [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz)
app: a roc-fuzz release is its platform (`fz`), and the engine package,
`platform/engine.roc`, is its `pf`. An app's own modules say `import
pf.Engine`, and the shorthand is per app, so the same module gets the
platform in the app's `main.roc` and the package in its `main-fuzz.roc`. A
module that imports `Files` builds only on the platform, so an app whose
modules do fuzzes its pure parts. Targets decode arbitrary bytes into valid sessions and check them
against a model: keyed reconciliation, the effect channel's lifecycle
including worker jobs, port calls and subscriptions, a gather's jobs
settling at their positions and an outbox's posts (`fx-channel`), the
worker wire format's decoder, the port message format's decoder
(`port-json`), and each app's
leak-checked random walk (the supersede test app's included; the Reading
List's plays its port handlers against a model store and checks that the
page shows what the store holds), each with a long seeded walk among its
examples (`Soak.Session`), and the Log Explorer's index, which a
worker builds a chunk at a time, against a model that reads the whole
text. A walk has no host to run a job's effects, so a worker app's target answers its jobs with a stand-in made from the
app's pure function (`Task.stand_in`, walked with `Soak.walk_with`); its
tasks' bodies run in the specs. A stand-in cannot carry files (an input or
answer that holds a `File` is a contract error), so an app whose tasks take
or give files fuzzes its pure parts instead. Every target
that drives the engine also runs the settle check after every step: no
reader of a written layer may be left stale (see
[Testing](@/docs/testing.md#the-settle-check)). `fuzz/structure` generates
the site trees themselves, so the check meets nestings no app contains, and
in its pure mode compares the page with a fresh mount. `check` replays the
examples of the targets in
`fuzz/`; `check-slow` replays every target's, and soaks each app's
round-trip spec in the native runner (`--soak`, see
[Testing](@/docs/testing.md#soaking-a-round-trip)); `fuzz.yml` runs nightly
campaigns with the corpora in the Actions cache. When a campaign finds a
failure, reduce it and add it to the target's examples with `Fuzz.saved`, so
every later replay keeps it fixed.

## Performance

Measure the build that ships: `--opt=size` for the browser, as the site and
the soak build it. Test how a cost scales with a 10× larger input before
optimizing anything, since scaling problems dwarf constant factors. Browser
timing comes from the js-framework-benchmark adapter in `benchmarks/`.
Validate every change with the specs and the soaks. There are no exact
allocation baselines in the gates; allocation regressions show up as soak
growth or scaling.

## Compilers

The repository follows roc-automation's three-compiler model:

| Compiler | Selected by | Used for |
|---|---|---|
| Blueprint's own | The `blueprint` release `Blueprint.roc` names | Evaluating `Blueprint.roc` |
| `roc-stable` | The nightly tag in `Blueprint.roc` | Running and checking the scripts under `scripts/` |
| `roc`, the latest Roc nightly | Nothing: whatever `roc-lang/nightlies` published last | Checking, building and testing the platform, the examples, the tests and the docs samples |

The platform floats on purpose: the question each pull request answers is
whether it works with the compiler users install today. CI resolves the
latest nightly once per run and installs it as `roc` with
`roc-lang/setup-roc`; locally, install the current nightly as `roc`. No Roc
file outside `scripts/` names a compiler, and `check` fails if one does.

To move `roc-stable`, in one pull request:

1. Change the `Recipes.roc_nightly(...)` tag in `Blueprint.roc`.
2. Change the `roc` field of every script under `scripts/` to the same tag;
   `check` fails until they match.
3. Run `blueprint update` and commit `Blueprint.lock`.
4. Run `blueprint run check`.

When a new nightly breaks the platform, CI says so on the next pull request;
fix it there, and remove any workaround whose upstream issue the nightly
fixes, with its row in `design.md`'s compiler limitations. The
nightly-compatibility workflow separately tests the latest release against
the latest nightly every day.

## Compiler workarounds

A workaround for a compiler defect is narrow, sits beside a comment linking
its upstream `roc-lang/roc` issue, and is listed in `design.md`. File the
issue with a minimal reproduction before adding the workaround; the
reproduction lives in the issue, not in this repository.

## The `signals.roc` tool

`cli/` is a Roc package on basic-cli; `Signals.roc` reads the command line
and puts every failure into words, and one module serves each command
(`Init.roc`, `Serve.roc`, `Dist.roc` for `build`, `Specs.roc` for `test`).
The page script `serve` adds, `cli/dev-client.js`, is the tool's own: it
only watches the page, and nothing of it reaches `platform/` or `dist/`.

What a copy of the tool ships with is `cli/Bundle.roc`: the release's
version, platform URL and compiler, the spec runner's targets, the runtime
files it serves, and the files `init` writes, which are the documentation's
counter in `www/samples/counter/` (its region markers removed, and the
platform path in `main.roc` replaced by the release's URL). The release
generates its own `Bundle.roc` and bundles it with copies of those files;
the checked-in one is the development copy, which imports them from the
working tree, and `check` fails when it is not what the release would
generate. A new runtime file or scaffold file therefore needs only the
script's lists and a regenerated `cli/Bundle.roc` (`check` writes the
expected file beside the build).

The release dry run stages the package in `.build/release-tool/` and writes
the tool's app to `.build/release/signals.roc`. To run that copy by hand
against the working tree, as `check` does:

```sh
roc --replace-dep <the package URL signals.roc names> .build/release-tool/main.roc \
  path/to/signals.roc serve
```

with `ROC_SIGNALS_PLATFORM` set to the absolute path of `platform/main.roc`,
which makes every build the tool runs use the working tree's platform in
place of the release's.

## Releases

A maintainer dispatches the `Release` workflow with a version. It builds the
assets with `blueprint run release` and creates a draft GitHub release with:

- the platform bundle, `<hash>.tar.zst`, which apps name as their platform:
  one platform whose `main.roc` builds for `wasm32` (the browser module) and
  `x64musl`, `arm64mac`, `x64mac` and `x64win` (the native spec runner),
  with the link inputs of each;
- `runtime.mjs` and its worker script, `worker.mjs`, served beside it;
- `signals-<hash>.tar.zst`, the `signals.roc` tool's package, and
  `signals.roc`, the small app an author downloads to run it: it names
  basic-cli and that package, and pins no compiler;
- `roc-signals-examples-<version>.zip`, each example's `main.roc` naming that
  bundle with its modules and specs, and the compatibility suite;
- `roc-signals-docs-<version>.zip`, the API docs;
- notes stating both compilers (the `roc` nightly that built and tested it,
  and `roc-stable`), to which the maintainer adds the narrative on GitHub
  before publishing.

After a release, `nightly-compatibility.yml` builds the released examples with
the latest Roc nightly every day, using roc-automation's shared runner, and
keeps one tracking issue open while they fail.

## Departures from roc-automation

The repository follows the
[roc-automation](https://github.com/lukewilliamboswell/roc-automation) model,
with these deliberate exceptions:

- **Documentation lives on this site**, built with Zola, not in
  `docs/*.adoc`; roc-docs generates only the API reference. The site is the
  product's documentation surface.
- **Specs, not `tests/spec.json`, test the working tree.** The examples are
  browser apps; `.scm` specs run in both runners. The examples archive
  carries a `spec.json` only for the shared nightly runner.
- **Examples are directories** with a `main.roc`, which builds for the
  browser and as the native spec runner, its specs, and a `main-fuzz.roc`,
  a roc-fuzz app on the engine package (roc-fuzz's entry cannot share the
  app's).
  The examples archive carries `main.roc`, the example's modules, its specs
  and its own files beside them: the JavaScript its author wrote (port
  handlers, a custom element), a page that mounts it, data it downloads.
- **The release workflow is hand-written** and publishes a draft whose notes
  are written on GitHub, rather than the shared package release workflow and
  notes under `docs/releases/`.
- **No SBOM yet.** Release SBOMs are tracked in
  [#171](https://github.com/lukewilliamboswell/roc-signals/issues/171).
