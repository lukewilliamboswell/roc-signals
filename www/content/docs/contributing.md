+++
title = "Contributing"
description = "Working on the platform itself: tools, tasks, tests, docs, performance, compilers and releases."
weight = 20
template = "page.html"
+++

# Contributing

This page is for people changing the platform, its tests, the examples or this
website. The architecture and its rules are in
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md);
repository-wide review guidelines are in `AGENTS.md`, and Roc conventions in the
[Roc Style
Guide](https://gist.github.com/lukewilliamboswell/241a4e8adb7c89c7e0e02f1d303a8fa1).

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
| `platform/` | The platform (`main.roc`): the engine (`Core.roc`, with a table, its views and their ordered keys in `Table.roc`, `View.roc` and `Seq.roc`, and in `EngineOnly.roc` the value that keeps a table's bookkeeping out of an app's reach), the authoring API (`Engine.roc`, `Table.roc`, `Html.roc`, `Worker.roc` with its payload format `Wire.roc`, and `Port.roc` with its message format `PortJson.roc`), the hosted effects a worker job calls (`Hosted.roc`, bound in both hosts and reached only through `Effects.roc`, which the platform root hands to the engine with each job, and `Files.roc`, whose `build!` opens a builder), the Wasm host (`host/host.zig`, with the typed heaps behind file handles in `host/resources.zig`), the browser runtime (`runtime.mjs` and its worker script `worker.mjs`), and the native spec runner (`SpecRunner.roc`, with its walks and soaks, the `Scm.roc` parser, the `Dom.roc` oracle, `host/spec.zig` with its system services in `host/os_posix.zig` and `host/os_windows.zig`, and `host/kernel32.def`, the Windows host's imports). Also `main-fuzz.roc`, a package root over the same pure modules (all but `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc`) that the platform's own fuzz targets depend on |
| `tests/` | Browser contract tests and the apps they drive (`tests/apps/`, for example `store` for cells read and written at depth, `writes` for decisions, resets and `also`, `table` for a table and its table views, `remount` for `remount_on`, `files` for file handles, `file-effects` for operations on files, `ports` for ports, `worker-typed` for the task API, `prepared` for preparations, `tasks` for jobs that read and build files, `outbox` for posting requests and `gather` for one question split over several jobs, with the platform's fuzz targets of the effect channel and the controls beside their test apps as `fuzz-<subject>.roc`), the Chrome spec replay, and the release check helper |
| `fuzz/` | The platform's fuzz targets of the shared support (the spec, wire and port formats, generated site trees, and tables with their views) |
| `examples/` | The example apps, each with its specs, any fuzz targets of its own pure logic (`fuzz-<subject>.roc`), and any JavaScript of its own beside it (the port handlers of the Reading List, the Status Page and the Million-Row Explorer, `ports.mjs`; the simulated service of Conduit, Field Notes and the Status Page, `backend.mjs`; the Log Explorer's `log-timings` element, `timings.mjs`, the Status Page's `latency-feed-monitor`, `feed-monitor.mjs`, and the Million-Row Explorer's `query-meter`, `meter.mjs`); `examples/shared/` holds the JavaScript several examples load (the `plume-chart` and `worker-pool-panel` elements) |
| `cli/` | The source of `signals.roc`, the tool app authors run to create, serve, build and test an app (below) |
| `benchmarks/` | The js-framework-benchmark adapter |
| `scripts/` | Roc scripts behind the tasks; shared modules in `scripts/src/` |
| `www/` | This website; `www/samples/` holds every code sample the docs show, each a file `check` compiles and, for a sample app, tests |

A module added to `platform/` for apps to import is listed in four places:
`exposes` in `platform/main.roc`, the package's list in `platform/main-fuzz.roc`
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
or a backend, the module that answers them, and, for an app that needs
them to reach a steady state, steps run once before the first cycle
(`SCENES`: the Status Page pauses its live feed and fills its uptime
history). Its native soak, a
round-trip spec under its `specs/`, is listed in `Slow.native_soaks`;
`check` and `check-slow` walk it because it is in `SpecSuite.apps`; and a
target of its own logic, if it has one, is listed in
`Targets.fuzz_targets`.

The website build highlights Roc samples with the pinned `roc-parser` lexer before
Zola runs. `www/samples/` remains the source: generated escaped fragments in
`www/highlighted/` are ignored. Scheme-style `.scm` samples use an independent
display lexer for comments, strings, list heads, atoms and keyword arguments;
it never parses or validates spec behavior. HTML samples use another lossless
display lexer for tags, attributes, values, comments, declarations and character
references; script and style bodies remain plain text. Every token is escaped
before markup is added, so highlighted HTML cannot become page elements or run
scripts. Other sample languages remain escaped plain text. The checked files are also published under
`dist/samples/`. In both rendered Roc snippets and their downloadable copies,
checkout-relative package URLs are replaced with `<package release URL here>`;
the originals retain their local paths for compiler checks. Other text is
preserved. `sample_download` and `sample_url` resolve against the website base
URL so readers can fetch the samples without a repository checkout.
Chrome checks the rendered source and copying, system/light/dark preferences,
keyboard controls, every syntax color in both palettes, and text contrast on the
documentation and index pages. Theme preferences apply to site chrome; example
apps keep their authored colors. Screenshots are written to
`.build/site-screenshots/` for visual review.

The website's look is one stylesheet, `www/input.css`, and its rules are stated
at the top of that file: square corners, one-pixel rules and no shadows; IBM
Plex Sans for text and IBM Plex Mono capitals for labels; and one accent, kept
for what is live or actionable, so status colors mean only status. The first
half of the file is the design system the examples compose their UI from,
always drawn light. The second half is the `site-…` classes of the pages
around an app, in a light and a dark palette, each with its own syntax
colors. The fonts are files under `www/static/fonts/`, served with the website,
with their license beside them.

## Tasks

These are the development environment's Blueprint tasks, not an app's
[worker tasks](@/docs/workers.md).

| Task | What it does |
|---|---|
| `blueprint run check` | The pull-request gate (below) |
| `blueprint run check-slow` | Every fuzz target's declared examples, a walk of every app of 10,000 steps (`RUNNER --walk`), the native soak of each app's round-trip spec (`RUNNER --soak 48`, flat live allocations and bytes), and a long Chrome session per app |
| `blueprint run spec -- [--browser] [--filter GLOB] [APP...]` | Some apps' specs, natively and optionally in Chrome |
| `blueprint run platform` | Build the platform's link inputs with the pinned Zig, including matching PIC musl startup and libraries, to build an app's `main.roc` by hand (a fuzz target needs none: `roc build --fuzz` fetches its roc-fuzz release) |
| `blueprint run jfb` | Build the js-framework-benchmark app and check its operations in Chrome |
| `blueprint run workers-scaling` | Measure worker jobs in Chrome on both candidate shipping builds of the Worker Lab: correctness (its drawn picture included), the time to draw a picture by pool size, speedup by pool size, responsiveness, payloads, robustness sequences and memory, as tables for a pull request |
| `blueprint run fuzz -- [--time S] [TARGET...]` | A fuzz campaign |
| `blueprint run site -- [--base-url URL] [--tool-url URL]` | Build the website, the API docs and the example apps into `dist/`; check sample highlighting, copying, themes and contrast in Chrome |
| `blueprint run serve -- [DIR] [--port N]` | Serve `dist/` at `127.0.0.1:8000/roc-signals/`, its published path, or `DIR` at the root |
| `blueprint run release -- --version V` | Build the release assets into `dist-release/` |

To browse the website locally:

```sh
blueprint run site -- --base-url http://127.0.0.1:8000/roc-signals
blueprint run serve
```

When reviewing an unreleased API, add `--tool-url URL` to the site build to
link onboarding downloads to a matching candidate `signals.roc`. That tool must
name the candidate's platform and tool bundles at reachable URLs; changing the
website link alone does not make an older release compatible. The override is
written to `.build/site-config.toml`, leaving `www/config.toml` unchanged.
Without an override, onboarding links download the latest published release.

The published website is main: every push to main that passes `check` deploys
CI's `blueprint run site` build to GitHub Pages.

Builds go to `.build/`; set `ROC_SIGNALS_BUILD_DIR` to use another directory,
for example to run two tasks at once.

## What `check` runs

1. Every script names the `roc-stable` nightly that `Blueprint.roc` pins, and
   no other Roc file names a compiler; every file `www/data/examples.toml`
   names exists, and every example is in a section of the examples index.
2. `roc fmt --check` over every Roc source, `roc test` on the platform, the
   engine package (`platform/main-fuzz.roc`), the tool (`cli/`), the
   scripts, and the `main.roc` of every example and test app, which runs
   the `expect`s of every module the app imports (the tests of its
   transitions), and the check that `cli/Bundle.roc` is what the release
   generates for a checkout.
3. The platform's link inputs for every target, a worker app's spec runner
   linked for macOS (`arm64mac`, `x64mac`) and Windows (`x64win`) from them,
   and the examples of the fuzz targets in `fuzz/` (the `.scm` parser, the
   worker wire format, the port message format, generated site trees, and
   tables with their views) and of the examples' own targets.
4. The docs samples (below).
5. Every app's specs natively and in Chrome, a walk of 300 steps of every
   walked app in its native runner (below), the check that the browser
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
   (`reading-list-journey.mjs`), the Status Page's seeded latency stream
   through its port's bound, a stalled page, a dropped connection, pausing
   and hiding (`status-page-journey.mjs`; with `--plotly FILE
   --measure-ms N` it also reports the stream's rates, the chart's JSON and
   the longest frame gap), the Log Explorer's preparation over a
   generated 64 MiB log, its timeline and a click on it, and its own
   timings element, with its times and memory (`log-explorer-journey.mjs`),
   the Million-Row Explorer at two million orders with its own live feed
   (`million-row-explorer-journey.mjs`: shards kept by their workers, a
   drag, the feed's bound, one worker and inline), and the Conduit journey
   against the example's own simulated backend
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

## Where each kind of test lives

Each kind of test lives where its subject does:

| What is tested | How | Where |
|---|---|---|
| A pure function: a decision's writes, a component's operations, a format | A top-level `expect` | Beside the function, in its module |
| What an app shows and does, and how much work it costs | `.scm` specs, natively and in Chrome | `<app>/specs/` |
| The engine over long sessions of real apps | The spec runner's walk (`--walk`) and soak (`--soak`) | Nothing is written: they run over each app's `main.roc` and specs |
| The engine's rules over generated programs | The platform's roc-fuzz targets | `fuzz/`, and `fuzz-<subject>.roc` beside the `effects` and `controls` test apps |
| An example's own pure logic over generated inputs | The example's roc-fuzz targets | `fuzz-<subject>.roc` beside the example's modules |
| The host, the runtime and the worker script against the wire protocol | Contract tests | `tests/` |

No app has a `main-fuzz.roc`. An app's one entry point is `main.roc`, and
nothing in an example exists only so that a platform test can drive it.
`platform/main-fuzz.roc` is something else: the root of the engine package
that the platform's own fuzz targets import.

## Expects

A decision is a pure function from a reading to a list of writes, so a
transition across cells is checked by a top-level `expect` with no engine
and no browser: `store.after(writes)` applies the list as a turn applies
it, the same-cell rule included, and `read(cell)` reads a cell of the
result. A component's operations on its own type are tested the same way.
This is the test that sees a transition that left out a reset or wrote the
wrong cell of the right type; the settle check cannot, since it sees only
propagation. [Testing](@/docs/testing.md#decisions-as-functions) shows one.

`roc test <app>/main.roc` runs the `expect`s of an app and of every module
it imports, the platform's among them, since a checkout reaches the platform
by a path. `roc test --main=<app>/main.roc <app>/<Module>.roc` runs one
module's; a module that imports the platform needs `--main` to resolve it.
`check` runs the first form for every example and test app and for every
docs sample.

## Specs and contract tests

Application-visible behaviour is specified in `.scm` files beside each app and
runs in both runners from one parser, `platform/Scm.roc`. An unknown step
is a parse error, and both runners implement every step, with Chrome as the
reference for what it means. The language is
documented in [Testing](@/docs/testing.md).

For a setup file given through `choose-files`, choose an extension whose
MIME type Chrome recognizes on every supported system, such as `.txt`
with `text/plain` or `.csv` with `text/csv`. The chooser's `File.type`
comes from the system's filename mapping, and the replay must match it
against the declared type. Extensions such as `.log` and `.bin` have
different mappings across systems. Keep byte-processing fixtures portable
without changing their bytes or weakening that check; use runtime contract
tests with explicitly constructed `File`s for arbitrary MIME metadata.

A change to the wire protocol changes the engine's encoder and decoders,
`platform/Dom.roc`, both hosts (`platform/host/host.zig`,
`platform/host/spec.zig`), `platform/runtime.mjs`, `platform/worker.mjs`,
the contract tests under `tests/` and Appendix B of `design.md` together,
and bumps the protocol version.

## New capabilities

The platform builds a browser capability when real applications are expected
to need it, and never declines one for want of an example (`design.md`,
"When a capability is built"). What it requires is that the capability lands
whole. A pull request for a new capability contains:

- a stated use in real applications, and what an app must do today without
  it;
- an API in the platform's own vocabulary, with what it deliberately leaves
  out;
- bounds and the behaviour at each bound;
- a failure analysis: each thing that can go wrong, the layer that takes it
  and what happens (below);
- an Appendix B entry wherever it touches the wire;
- the same meaning in both spec runners, for every step that drives it. An
  input no runner can drive faithfully is named in `design.md`'s "The `.scm`
  spec language" and held by a contract test;
- a runtime contract test;
- a demonstration: an example upgraded to use it or, where no example fits,
  a test app with specs.

A capability that adds an engine sequence also adds it to a fuzz target
(see [Fuzzing](#fuzzing)).

The failure analysis is written against the seven layers of `design.md`'s
"How failure is controlled", in their order of preference: impossible to
write, a value the app must handle, a contract error at the narrowest
boundary, bounded, contained, checked by tests the design requires, and
left to the app's author. Every issue for a capability carries it as a
`## Failure` section, in this form:

```text
## Failure

| What can go wrong | Layer | What happens |
|---|---|---|
| One row for each mistake, outside failure, bound or platform fault | One of the seven names: the earliest layer that takes it | What the author or the user then sees: the compile error, the result, the diagnostic, the behaviour at the bound |
| A row for each thing left to the author | Left to the app's author | What happens. **Justified:** what is left, why no earlier layer can reasonably catch it, and what the author has in its place: the test that sees it or the rule that avoids it |

Covered by: the fuzz target, walk or contract test behind each "Checked by tests the design requires" row.
```

An issue is not ready while a "Left to the app's author" row has no
justification, or while a row breaks a firm rule: a contract error for a
rule the compiler can carry, or a poison at a bound that follows the app's
data. An issue that changes only documents carries no such section.

## Docs samples

Every Roc code block on this website comes from a file under `www/samples/`,
shown with the `sample` shortcode:

```text
{{/* sample(file="todos/Todos.roc", region="row") */}}
```

A region is the lines between `# region NAME` and `# endregion NAME`; the
marker lines never render, so one region can sit inside another. Each
marker is the whole end of its line, so a region `row` ends at
`# endregion row` and not at the `# endregion row-state` of a region inside
it. `check`
fails on an inline Roc block in a docs page, a missing sample or region, a
sample that does not type-check or whose `expect`s fail, and a sample
directory with `specs/` whose specs fail natively or in Chrome.

A sample is either one file that is a whole app (`www/samples/state.roc`)
or a directory laid out as an app is: its modules, a `main.roc` that binds
the program, and `specs/`. Prefer a directory for anything a page says
behaves in some way, so that a spec holds the page to it, and give a
sample's decisions the `expect`s the page shows
(`roc test www/samples/<app>/main.roc` runs them, and so does `check`). The counter in
`www/samples/counter/` is also what `signals.roc init` writes, so a change
to it is a change to every new app.

## Walks and soaks

The native spec runner walks an app: `RUNNER --walk STEPS [--seed N]
FILE.scm...`, where the runner is the app's `main.roc` built for the
system's native target. It mounts the app with the first file's setup, then
takes STEPS seeded steps. Each is a user event on a live control (from the
live DOM, disabled controls skipped; for text, half the time a value a spec
types into that control, otherwise one of a fixed pool) or, while the
browser has one to do, a service: answering a pending request, ticking a
live interval, changing visibility or connectivity for a live subscription,
or delivering a message a spec emits on a port. A worker job runs for real
in a child process, as a spec runs it, unless the walk loses it with a
fault class, times it out or leaves it pending; every other request is
answered from what the files' steps give: an HTTP request with an HTTP response
staged for its URL (else its path), a 503 or a timeout; a port call with an
answer given that port, a throw or its timeout. After every step the settle
check must pass (see [Testing](@/docs/testing.md#the-settle-check)) and the
counters must agree with the commands; after the walk no allocation, byte
or file handle may be left live. A failure names the step and the last six
things the walk did. The walk needs nothing written for an app, so every
app with specs is walked: `check-slow` walks each (`Slow.walks`: 10,000
steps from seed 7 on a runner built at `--opt=speed`, the Markdown Editor
five times for 2,000), and `check` 300 steps on the runner it built for the
specs. The four test apps whose pages offer a contract error or a focus loop
on purpose (`workers`, `ports`, `outbox`, `controls`) are not walked: a walk reaches that error and
the instance is poisoned, as it must be. The walk is the spec runner's, so
it is in every app's runner and needs no target, entry point or harness of
its own; the scripts run it over each app, and an app author can run it
over theirs ([Testing](@/docs/testing.md#walks)).

A spec that takes the app back to where it started is a round trip, and the
native runner soaks it: `RUNNER --soak 48 specs/round-trip-NAME.scm` runs
the spec once, recording every call its steps make into the engine after
its last `mark-metrics` (after the mount when there is none), then replays
those calls 48 times on the engine alone and requires every cycle after a
warm-up (`--warm N`, two by default) to leave no allocation and no byte
live. An answer the spec gave (an HTTP stub, a worker job's answer, a port
answer) is replayed as it was first given, to the request at the same place
among those in flight; a cycle that leaves no request there is not a round
trip, and the soak says so. It is a leak check, never a baseline. Each
example but the CSV Converter keeps one round-trip spec
(`round-trip-*.scm`), which `check` runs as an ordinary spec in both
runners and `check-slow` soaks (`Slow.native_soaks`). A soak records an
answer that carried files with their handles, to replay it, so while the
spec runs under `--soak` the runner itself holds those files: an
`expect-files` after such an answer fails under the soak although it passes
as an ordinary spec, so check that the app lets its files go in another
spec, not in the round trip.

`check-slow` also runs a long session of every example in Chrome
(`tests/browser/soak.mjs`): a seeded walk without a fault, then 30 round
trips with flat Wasm pages and live allocations. It mounts the app with
`manualWork`, so its worker jobs wait to be answered, and its tables give
each app a round trip and, for an app with ports or a backend, the module
that answers them.

## Fuzzing

Every fuzz target is an ordinary [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz)
app, whose platform (`fz`) is a roc-fuzz release. There are two kinds.

The platform's own targets import the engine package,
`platform/main-fuzz.roc`, as `pf`; they are its only users. They live under
`fuzz/`, one directory each with a `main.roc`, and as `fuzz-<subject>.roc`
beside the two test apps whose engine sequences they generate. They decode
arbitrary bytes into valid programs and check the engine against a model:
the effect channel's lifecycle including worker jobs, port calls and
subscriptions, a gather's jobs settling at their positions and an outbox's
posts (`fx-channel`, `tests/apps/effects/fuzz-channel.roc`), controlled inputs
and more than 4,095 `each` sites (`controls`,
`tests/apps/controls/fuzz-controls.roc`), generated site trees
(`fuzz/structure`, whose pure mode also compares the page with a fresh
mount, so the settle check meets nestings no app contains), tables and
their views against a model that filters, sorts and windows the table from
scratch, over keyed writes, whole rewrites and events that write the table,
the query and the window together (`fuzz/table-view`), the `.scm`
parser (`fuzz/scm-parse`), boot sections (`fuzz/boot`, whose total decoder
accepts only the exact encoding of its decoded value or the empty default
shorthand), the worker wire format's decoder (`fuzz/wire`)
and the port message format's decoder (`fuzz/port-json`). Every target that
drives the engine runs the settle check after every step.

An example's targets check its own pure logic and import nothing of the
platform: `fuzz-<subject>.roc` beside the modules it imports, named for
what it checks (the CSV Converter's `fuzz-csv.roc`, the Spreadsheet's
`fuzz-formulas.roc`, the Million-Row Explorer's `fuzz-aggregates.roc`), each
against a model, a round trip or an invariant over generated sequences. The
logic a target reaches is therefore in modules that import nothing from
`pf`: a component's module imports the platform for its view, so operations
worth fuzzing belong in a domain module the component uses. An example
whose logic depends on the platform's types (the Worker Lab, the Status
Page, the Reading List) has none; its `expect`s, its specs and its walk
cover it. App authors learn this kind from
[Testing](@/docs/testing.md#fuzzing-your-own-logic).

Coverage-guided exploration of event sequences over the example apps is
not something either kind does: the walks are seeded, not guided. Guided
exploration meets the engine through generated programs (`structure`) and
the effect channel's model (`fx-channel`).

`check` replays the examples of the targets in `fuzz/` and of the
examples' own; `check-slow` replays every target's; `fuzz.yml` runs nightly
campaigns of every target in `Targets.fuzz_targets` with the corpora in the
Actions cache. When a campaign finds a failure, reduce it and add it to the
target's examples with `Fuzz.saved`, so every later replay keeps it fixed.
Judge a target by its properties: state the rules the code must keep over
generated sequences, and check them against a reference model. Its oracles,
not its inputs, carry the value.

## Performance

Measure the build that ships: `--opt=size` for the browser, as the website and
the soak build it. Test how a cost scales with a 10× larger input before
optimizing anything, since scaling problems dwarf constant factors. Browser
timing comes from the js-framework-benchmark adapter in `benchmarks/`.
Validate every change with the specs and the soaks. There are no exact
allocation baselines in the gates; allocation regressions show up as soak
growth or scaling.

## Compilers

For `nightly-2026-11-11-7679cc5` only, automation prints explicit `SKIP`
messages for compiler-blocked work.
[roc-lang/roc#12976](https://github.com/roc-lang/roc/issues/12976) crashes
optimized builds of every maintained example, so the website and `signals.roc
build` use `--opt=dev`, with a warning that the artifacts are larger and slower.
Native and browser specs, short walks and native soaks still run. Optimized long
walks, shipping browser soaks and full worker scaling do not run; development
artifacts are not performance or shipping allocation evidence. The release notes
disclose these limits.

Fuzz examples and campaigns also report `SKIP` on that nightly: roc-fuzz
0.6.0's Linux libraries predate the [PIE requirement](https://github.com/roc-lang/roc/pull/12949),
and its engine targets also reach the optimizer crash. Restore them with
PIC roc-fuzz inputs and the optimizer fix. Windows CI always attempts the
current CLI init and retains its output in `.build/cli-init.log`, printing
it before classification. Only a failed init containing a nonempty subset of
the three captured basic-cli 0.28 diagnostics (`Locale:253:11`, `Locale:291:11`, or `Path:739:1`), each once
and with every error, cause and summary accounted for, may quarantine the remaining
CLI journey on that exact nightly ([basic-cli#555](https://github.com/roc-lang/basic-cli/issues/555)).
CI has reproduced the Locale failures with basic-cli 0.27 and 0.28; the
underlying cause remains unproven. Successful init continues the full journey, and
other failures remain fatal. Windows native specs and worker failure
checks remain enabled; remove the quarantine when basic-cli#555 is resolved.

Every exemption matches that exact compiler version, so the next nightly
automatically retries the original work. Remove these branches once the
corresponding upstream fixes are available; do not extend a skip to an
unverified compiler version.

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
The tool's basic-cli dependency in `cli/main.roc` supplies PIE-compatible
native inputs ([basic-cli#549](https://github.com/roc-lang/basic-cli/pull/549)).
It is separate from the scripts' platform dependency, which must remain
compatible with the pinned `roc-stable`.
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

- **Documentation lives on this website**, built with Zola, not in
  `docs/*.adoc`; roc-docs generates only the API reference. The website is the
  product's documentation surface.
- **Specs, not `tests/spec.json`, test the working tree.** The examples are
  browser apps; `.scm` specs run in both runners. The examples archive
  carries a `spec.json` only for the shared nightly runner.
- **Examples are directories** with a `main.roc`, which builds for the
  browser and as the native spec runner, its specs, and any roc-fuzz
  targets of its own pure logic (`fuzz-<subject>.roc`; roc-fuzz's entry
  cannot share the app's).
  The examples archive carries `main.roc`, the example's modules, its specs
  and its own files beside them: the JavaScript its author wrote (port
  handlers, a custom element), a page that mounts it, data it downloads.
- **The release workflow is hand-written** and publishes a draft whose notes
  are written on GitHub, rather than the shared package release workflow and
  notes under `docs/releases/`.
- **No SBOM yet.** Release SBOMs are tracked in
  [#171](https://github.com/lukewilliamboswell/roc-signals/issues/171).
