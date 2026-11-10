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
| `platform/` | The platform (`main.roc`): the engine (`Core.roc`), the authoring API (`Engine.roc`, `Html.roc`, `Worker.roc` with its payload format `Wire.roc`, and `Port.roc` with its message format `PortJson.roc`), the hosted effects a worker job calls (`Hosted.roc`, bound in both hosts), the Wasm host (`host/host.zig`, with the typed heaps behind file handles in `host/resources.zig`), the browser runtime (`runtime.mjs` and its worker script `worker.mjs`), and the native spec runner (`SpecRunner.roc`, the `Scm.roc` parser, the `Dom.roc` oracle, `host/spec.zig`). Also the fuzz platform (`fuzz.roc`, the vendored roc-fuzz modules and the soak walk) |
| `tests/` | Browser contract tests and the apps they drive (`tests/apps/`, for example `files` for file handles, `file-effects` for operations on files, `ports` for ports, `worker-typed` for the task API, `prepared` for preparations and `tasks` for jobs that read and build files), the Chrome spec replay, and the release check helper |
| `fuzz/` | Fuzz targets of the shared support; each app's own target is its `main-fuzz.roc` |
| `examples/` | The example apps, each with its specs, and with any JavaScript of its own beside it (the Reading List's port handlers, `ports.mjs`) |
| `benchmarks/` | The js-framework-benchmark adapter |
| `scripts/` | Roc scripts behind the tasks; shared modules in `scripts/src/` |
| `www/` | This site; `www/samples/` holds every code sample the docs show |

A module added to `platform/` for apps to import is listed in four places:
`exposes` in `platform/main.roc` and in `platform/fuzz.roc`, the release
bundle's files in `scripts/src/Release.roc`, and the API reference's modules
in `scripts/src/ApiDocs.roc`. A file added to the browser runtime is listed
in `SpecSuite.runtime_files` (`scripts/src/SpecSuite.roc`) and in
`RUNTIME_FILES` (`tests/browser/args.mjs`), which every copy site and
browser test reads.

An example is listed in `SpecSuite.apps`, so `check`, the release check
and the browser soak cover it, and in `www/data/examples.toml` with a page
under `www/content/examples/`. A file its page loads (a script, or the
module of port handlers its `ports` names) is copied beside its app by
`scripts/site.roc`. The soak's tables in `tests/browser/soak.mjs` give it a
round trip, and, for an app with ports, the module of its handlers. Its
fuzz target, if it has one, is listed in `Targets.fuzz_targets`.

## Tasks

These are the development environment's Blueprint tasks, not an app's
[worker tasks](@/docs/workers.md).

| Task | What it does |
|---|---|
| `blueprint run check` | The pull-request gate (below) |
| `blueprint run check-slow` | Every fuzz target's declared examples, the leak-checked native soaks with flat round trips, and a long Chrome session per app |
| `blueprint run spec -- [--browser] [--filter GLOB] [APP...]` | Some apps' specs, natively and optionally in Chrome |
| `blueprint run platform` | Fetch and build the platform's link inputs, to build an app's `main.roc` or `main-fuzz.roc` by hand |
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
   no other Roc file names a compiler.
2. `roc fmt --check` over every Roc source, and `roc test` on the test support
   and the scripts.
3. The test platform, and the examples of the fuzz targets in `fuzz/` (the
   `.scm` parser, the worker wire format, the port message format and generated site trees).
4. The docs samples (below).
5. Every app's specs natively and in Chrome, the check that the browser
   runner handles every form of the grammar, then a deliberately broken spec
   that both runners must reject.
6. The runtime's unit tests in Node (the work monitor's aggregation and
   bounds, `tests/runtime/`), then its contract tests in Chrome: effects,
   controlled inputs, worker jobs, the work monitor, a smoke of the worker
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
   and the Conduit journey against its scripted backend.
7. The js-framework-benchmark check.
8. The release dry run: the bundle, `runtime.mjs` and `worker.mjs`, the examples archive with
   every app mounted by its check helper, and the release notes.

Every spec must pass in both runners; there are no expected failures.

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

Every fuzz target is a [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz)
target on the repository's fuzz platform (`platform/fuzz.roc`: roc-fuzz's
own modules, vendored unchanged, with the engine's modules exposed beside
them). Targets decode arbitrary bytes into valid sessions and check them
against a model: keyed reconciliation, the effect channel's lifecycle
including worker jobs and port calls and subscriptions (`fx-channel`), the
worker wire format's decoder, the port message format's decoder
(`port-json`), and each app's
leak-checked random walk (the supersede test app's included; the Reading
List's plays its port handlers against a model store and checks that the
page shows what the store holds), and the Log Explorer's index, which a
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
`fuzz/`; `check-slow` replays every target's; `fuzz.yml` runs nightly
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

## Releases

A maintainer dispatches the `Release` workflow with a version. It builds the
assets with `blueprint run release` and creates a draft GitHub release with:

- the platform bundle, `<hash>.tar.zst`, which apps name as their platform:
  one platform whose `main.roc` builds for `wasm32` (the browser module) and
  `x64musl` (the native spec runner), with the link inputs of both;
- `runtime.mjs` and its worker script, `worker.mjs`, served beside it;
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
  browser and as the native spec runner, its specs, and a `main-fuzz.roc` on
  the repository's fuzz platform (roc-fuzz's entry cannot share the app's).
  The examples archive carries `main.roc`, the example's modules, its specs
  and its own files beside them: the JavaScript its author wrote (port
  handlers, a custom element), a page that mounts it, data it downloads.
- **The release workflow is hand-written** and publishes a draft whose notes
  are written on GitHub, rather than the shared package release workflow and
  notes under `docs/releases/`.
- **No SBOM yet.** Release SBOMs are tracked in
  [#171](https://github.com/lukewilliamboswell/roc-signals/issues/171).
