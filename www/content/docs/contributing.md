+++
title = "Contributing"
description = "Working on the platform itself: tools, tasks, tests, docs, performance, compilers and releases."
weight = 21
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

The platform and tooling pin the published roc-parser 6.0.0-rc.3 package.
Roc downloads it automatically; no sibling parser checkout or setup task is needed.

Chrome is the machine's `google-chrome` for now, because blueprint cannot yet
unpack Chrome for Testing's zip archives; `Blueprint.roc` has the pinned
recipe ready.

## Layout

| Path | Contents |
|---|---|
| `platform/` | The platform (`main.roc`): the engine (`Core.roc`, with a table, its views and their ordered keys in `TableCore.roc`, `View.roc` and `Seq.roc`), the authoring API (`Engine.roc`, including its opaque `Table`, `Html.roc`, the plain layout payloads in `Layout.roc`, clipboard requests in `Clipboard.roc`, cryptographic requests and key handles in `WebCrypto.roc`, pure utility modules `Base64.roc`, `Order.roc` and `Url.roc`, checked browser-name and HTTP-method primitives in public `Web.roc`, `Worker.roc` with its payload format `Wire.roc`, and `Port.roc` with its message format `PortJson.roc`), the hosted effects a worker job calls (`Hosted.roc`, bound in both hosts and reached only through `Effects.roc`, which the platform root hands to the engine with each job, and `Files.roc`, whose `build!` opens a builder), the Wasm host (`host/host.zig`, with the typed heaps behind file handles in `host/resources.zig`), the browser runtime (`runtime.mjs`, its fact-reader helper `environment.mjs` and worker script `worker.mjs`), and the native spec runner (`SpecRunner.roc`, with its walks and soaks, `PicturePage.roc` for exact host-template ranges and static route projection, the `Scm.roc` parser, the `Dom.roc` oracle, `host/spec.zig` with its system services in `host/os_posix.zig` and `host/os_windows.zig`, and `host/kernel32.def`, the Windows host's imports). Also `main-fuzz.roc`, a package root over the same pure modules (all but `Files.roc`, `Effects.roc`, `Hosted.roc` and `Cli.roc`) that the platform's own fuzz targets depend on |
| `tests/` | Native lifetime contracts, browser contract tests and the apps they drive (`tests/apps/`, for example `store` for cells read and written at depth, `writes` for decisions, resets and `also`, `table` for a table and its table views, `remount` for `remount_on`, `files` for file handles, `file-effects` for operations on files, `ports` for ports, `worker-typed` for the task API, `deep-payload` for the payload's nesting bound, `prepared` for preparations, `tasks` for jobs that read and build files, `outbox` for posting requests and `gather` for one question split over several jobs, with the platform's fuzz targets of the effect channel and the controls beside their test apps as `fuzz-<subject>.roc`), the Chrome spec replay, and the release check helper |
| `fuzz/` | The platform's fuzz targets of the shared support (the spec, wire and port formats, generated site trees, and tables with their views) |
| `examples/` | The example apps, each with its specs, any fuzz targets of its own pure logic (`fuzz-<subject>.roc`), and any JavaScript of its own beside it (the port handlers of the Reading List, the Status Page and the Million-Row Explorer, `ports.mjs`; the simulated service of Conduit, Field Notes and the Status Page, `backend.mjs`; the Log Explorer's `log-timings` element, `timings.mjs`, the Status Page's `latency-feed-monitor`, `feed-monitor.mjs`, and the Million-Row Explorer's `query-meter`, `meter.mjs`); `examples/shared/` holds the JavaScript several examples load (the `plume-chart` and `worker-pool-panel` elements) |
| `cli/` | The source of `signals.roc`, the tool app authors run to create, serve, build and test an app (below) |
| `benchmarks/` | The js-framework-benchmark adapter |
| `scripts/` | Roc scripts behind the tasks; shared modules in `scripts/src/` |
| `www/` | This website; `www/samples/` holds every code sample the docs show, each a file `check` compiles and, for a sample app, tests |

A module added to `platform/` for apps to import is listed in three places:
`exposes` in `platform/main.roc`, the package's list in `platform/main-fuzz.roc`
unless it reaches a hosted function, and the release bundle's files in
`scripts/src/Release.roc`. `ApiDocs` reads the public modules from the
platform root, follows members inherited through aliases, and checks their
source comments and rendered documentation. A file added to the browser runtime is listed
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
| `blueprint run check -- [--without-fuzz] [--without-sizes] [--part K/N] [--plan [--builds]]` | The pull-request gate (below), every fuzz target's fixed examples included; `--without-fuzz` skips the fuzz targets, each with a `SKIP` line, as CI's Check job does beside its Fuzz smoke job; `--without-sizes` skips the examples' size report with a `SKIP` line, as CI's Check job does because its Site job reports the sizes of the modules it publishes; `--part K/N` runs part K of the parts CI's Check job runs in parallel (below); `--plan` prints what each part runs and builds and runs nothing, and `--builds` adds every build |
| `blueprint run check-slow` | Local only, never in CI: every fuzz target's fixed examples on its instrumented build, a walk of every app of 10,000 steps (`RUNNER --walk`), the native soak of each app's round-trip spec (`RUNNER --soak 48`, flat live allocations and bytes), and a long Chrome session per app |
| `blueprint run spec -- [--browser] [--filter GLOB] [--target TARGET] [APP...]` | Some apps' specs, natively and optionally in Chrome. The native runners are built for `TARGET` (`x64musl`, `arm64mac`, `x64mac` or `x64win`); without it, for the system the task runs on as `uname -sm` names it (`x64musl` where that names none), so a contributor's Mac runs them as they are. `check` always builds for `x64musl`, as CI does. A run whose filter selects no spec fails: a filter that matches nothing is a mistake |
| `blueprint run platform` | Build the platform's link inputs with the pinned Zig, including matching PIC musl startup and libraries, to build an app's `main.roc` by hand (a fuzz target needs none: `roc build --fuzz` fetches its roc-fuzz release) |
| `blueprint run jfb` | Build the js-framework-benchmark app as the benchmark measures it (`--opt=speed`) and check its operations in Chrome |
| `blueprint run workers-scaling` | Measure worker jobs in Chrome on both candidate shipping builds of the Worker Lab: correctness (its drawn picture included), the time to draw a picture by pool size, speedup by pool size, responsiveness, payloads, robustness sequences and memory, as tables for a pull request |
| `blueprint run startup-browsers -- [--with-deps]` | The small startup boundary corpus in Chromium, Firefox and WebKit: independent malformed-wire/native-state controls plus native prerendered HTML adopted by the same typed app compiled to Wasm. Builds only that app; the full SCM suite keeps its native/Chrome validation |
| `blueprint run fuzz-smoke -- [TARGET...]` | Every registered fuzz target's fixed examples on plain optimized native builds, or the named targets; `-- --shard K/N` runs shard K of N, as CI does; never explores |
| `blueprint run sizes -- [--runtime-only]` | Check shipped JavaScript Brotli sizes (gzip is reported); without the flag, also build and report each example's shipping module and development-only scripts |
| `blueprint run fuzz -- [--time S] [TARGET...]` | A fuzz campaign (600 s of exploration per target by default), local only: CI never runs one |
| `blueprint run api` | Build and audit the API reference alone, including methods inherited through public aliases, without rebuilding the site examples |
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

The published website is main: every push to main that passes CI's Check and
Fuzz smoke jobs deploys CI's `blueprint run site` build to GitHub Pages.

Builds go to `.build/`; set `ROC_SIGNALS_BUILD_DIR` to use another directory,
for example to run two tasks at once.

After Tailwind writes `www/static/signals.css`, the `site` task checks the
examples' class literals against that stylesheet: a string literal given as
the class argument of `Engine.class` or of any `Html` function that passes
one of its parameters to `Engine.class` (found in `platform/Html.roc`, so a
new constructor is checked with no other edit), and one given to a record
field named `class`, as an app's props carry it. Fixed `class` attributes in
explicit `Html.Markup` and `Svg.Markup` declarations and literal suffixes are
also checked with the pinned markup parser. Whole dynamic attribute holes
remain dynamic; ordinary strings containing HTML remain prose. Roc escapes,
markup character references and multiline strings retain their source lines.
An undefined class fails
the build with its source file and line. Complete static words around an
interpolation are checked. A class built by a function, or held in a value
under another name before it reaches a class argument, is not a literal at a
class position and remains the app's.

## What `check` runs

The API comparison discovers the latest published platform through GitHub's
release API. CI supplies its read-only token as `GH_TOKEN`; local runs can
also set `GH_TOKEN` when the anonymous API quota is exhausted. HTTP errors
fail with their status and a bounded response excerpt. Discovery and baseline
extraction failures fail the gate; the current source never replaces the
published baseline. A release `roc bump` cannot read as it shipped is compared
through one reviewed repair, recorded in `ApiDocs.baseline_repairs`: the gate
downloads the published bundle, refuses it unless its SHA-256 is the recorded
one, makes the repair's exact edits to its `main.roc` and says so in its
output. 0.5.0 is repaired by exposing `EngineOnly`, because `roc bump` cannot
extract an API whose signatures name a type from an unexposed module. A repair
kept after its release is no longer the latest fails the gate until it is
removed.

The working tree's side has the same limitation: `Wire.Sendable`'s `where`
clause names the unexposed `WorkerCodec` types (roc-lang/roc#13022), so
`roc bump` refuses the platform as it is. The gate compares it unrepaired
first; when the refusal names a `WorkerCodec` type, it compares a copy of
`platform/` whose root also exposes and imports `WorkerCodec`
(`ApiDocs.candidate_repair`, edits that must apply exactly once), says so in
its output, and so lists `WorkerCodec` as an added module the release does
not expose. Any other refusal fails the gate, and once the unrepaired
platform extracts, the kept repair fails the gate until it is removed.

The stages run in this order (`scripts/check_all.roc`). A problem does not
stop the later stages; every problem is printed as a `FAIL` line at the end,
and a stage that cannot run at all aborts the task after printing the
problems found before it.

1. Every script names the `roc-stable` nightly that `Blueprint.roc` pins,
   except `scripts/unicode_symbols.roc`, which `roc` builds and which names
   no compiler, and no other Roc file names a compiler; no two source paths differ only
   in letter case, which a checkout on macOS or Windows would merge; and
   every script a `Blueprint.roc` task starts (the first element of its
   `Run`) is tracked by git as executable (mode 100755), since most tasks
   never run in CI to show one that is not.
2. `roc fmt --check` over every Roc source.
3. Every file `www/data/examples.toml` names exists, and every example is in
   a section of the examples index.
4. Every fuzz target in the tree is registered in `Targets.fuzz_targets`, or
   skipped in `Targets.fuzz_skipped` with a reason that `check` prints as a
   `SKIP` line, and every registered file exists. Every app under
   `examples/` and `tests/apps/` with a `specs/` directory is named in
   `SpecSuite.apps` or `SpecSuite.test_apps`, every app they name has
   specs, and none is named twice, so no app's specs go unrun and none
   passes having checked nothing.
5. The shipped JavaScript's Brotli sizes against `scripts/src/runtime-sizes.tsv`:
   growth or shrinkage beyond 16 bytes fails, and so does a newly shipped
   file without a figure.
6. Both platform roots declare the same parser, Unicode and CBOR dependencies.
7. The API: every public `Engine` and `Html` symbol is documented, no Roc
   file but the platform's own fuzz targets names the internal engine package,
   and `roc bump` against the latest published platform bundle (above).
8. `roc test` on the platform, the engine package (`platform/main-fuzz.roc`)
   and the tool (`cli/`); on the `main.roc` of every example and test app,
   which runs the `expect`s of every module the app imports (the tests of
   its transitions); on every registered fuzz target's root
   (`Targets.fuzz_targets`), whose own `expect`s no build or replay of the
   target runs; together with the key- and declaration-type fixtures
   that must fail to compile naming their rule; the check that
   `cli/Bundle.roc` is what the release generates for a checkout; and on
   every root under `scripts/`, except a root that imports the platform
   package to drive its tests, which may not hold `expect`s of their own.
9. The platform's link inputs for every target; the declaration and request
   contracts, as the cases of two apps each built once
   (`tests/apps/key-contracts`, and `tests/key-contracts/oracle.roc.txt` for
   the native oracle's and the engine package's, which only a fixture may
   name): an instance booted at a case's path mounts that case alone, so
   each case is one run of its app's native runner on a spec that boots
   there and must end with the case's class, rule and exit code (and each
   app's root path must pass), and the platform app's cases are mounted
   from the one Wasm build by `tests/browser/key-contracts-browser.mjs`;
   `zig test` of the host's handle heaps (`platform/host/resources.zig`) and `dbg` buffer
   (`platform/host/dbg.zig`); a worker app's spec runner linked for macOS
   (`arm64mac`, `x64mac`) and Windows (`x64win`); and the fuzz targets' fixed
   examples (see [Fuzzing](#fuzzing)).
10. The docs samples (below).
11. The web platform and every spec-bearing app built for both runners, with
    the raw, gzip and Brotli sizes of each example module (built separately
    with `--opt=size`; in CI, by the Site job, which builds those modules
    to publish them) and of the debug scripts reported, without thresholds;
    then every app's specs natively and in Chrome. Each run of a runner must
    account for every spec it was given (see
    [Specs and contract tests](#specs-and-contract-tests)).
12. The native lifetime contracts: file handles across pages run in fixed
    orders in one runner process (`tests/native/file-lifetimes.mjs`), the
    native runner's `dbg` output (`tests/native/dbg-output.mjs`), and suite
    evidence validation (`tests/native/suite-evidence.mjs`).
13. A walk of 300 steps of every walked app in its native runner (below).
14. The check that the browser runner handles every form of the grammar and
    nothing else, and that a file its `choose-files` gives the app is read
    from disk (`replay.mjs --check-choose-files`: once its disk file is
    removed, a read, a slice and a worker's read of it fail).
15. Deliberately broken specs that both runners must reject, and a spec
    that breaks a contract, whose native crash the suite must report.
16. Every malformed declaration name refused identically before native
    execution and before browser emission.
17. The runtime's unit tests: the Roc scripts `scripts/test_parallel.roc`,
    `scripts/test_protocol.roc` and `scripts/test_worker_entries.roc`, the
    Node tests in `tests/runtime/` (among them the work monitor's
    aggregation and bounds) and `tests/fuzz/check-report-unit.mjs`, and the
    sparse-write allocation check of `tests/apps/write-scaling` on the
    development build its specs use and on a shipping (`--opt=size`)
    build.
18. The runtime's contract tests in Chrome (`Targets.browser_contracts!`, one
    script under `tests/browser/` each): the protocol facts, names,
    namespaces and Unicode classes against the native oracle; effects,
    controls, pointers, keys, dialogs, layout, services, the environment,
    persistence and transitions; an outbox posted twice in one turn; worker
    jobs, `dbg` and the work monitor; file handles, operations on files and their lifetimes in a
    table; preparations, ports with real handlers, reports, jobs that
    read and build files, and worker payloads at their nesting bound on a
    development build. Then the examples' journeys
    (`Targets.example_journeys!`): the worker scaling smoke on the Worker
    Lab, and the Reading List, the Status Page, the Log Explorer, the
    Million-Row Explorer and Conduit, each against the example's own
    JavaScript. With `--plotly FILE --measure-ms N`,
    `status-page-journey.mjs` also reports the stream's rates, the chart's
    JSON and the longest frame gap.
19. The js-framework-benchmark check, on a development build: it asks
    whether the keyed operations are right, which `blueprint run jfb` asks
    again of the `--opt=speed` build the benchmark measures.
20. The release dry run: the bundle, `runtime.mjs`, `environment.mjs` and
    `worker.mjs`, the `signals.roc` tool's package and app, the examples
    archive with every app mounted by its check helper, and the release
    notes.
21. The tool, end to end (`scripts/src/ToolCheck.roc`): the dry run's
    `signals.roc` run from empty directories as an author runs it, on the
    counter and on the Worker Lab, as six independent scenarios run in
    parallel, each a process of `scripts/tool_check.roc` (built once; run
    it with a scenario's name to repeat one). Every build there is the
    tool's own, the behaviour under test: about seven `--opt=size` builds
    (the counter's plain, `dbg` and two picture builds, two failing builds
    and the Worker Lab's) and the development runners of `test`. `init`, `test` and `build`; every failure
    it explains, each by its sentence (a misused command line, no
    `main.roc`, `index.html` or specs, a failing spec, a build error, no
    `roc` on the PATH, a compiler other than the release's); the built
    `dist/` mounting from a plain static server in Chrome with jobs running
    in workers (`tests/browser/tool-dist.mjs`); and `serve` in Chrome
    (`tests/browser/tool-serve.mjs`: a busy port, content types, the reload
    script, a reload after an edit, and the overlay for a build error, a
    mount refusal and an engine fault).

Every spec must pass in both runners; there are no expected failures.

Run with no option, `check` is the whole gate in one go. CI runs the same
stages as the parallel legs of its Check job, each `check -- --without-fuzz
--without-sizes --part K/N`, and a pull request requires the one job named
Check that passes only when every leg and the Site job (whose size report
stands for the skipped one) did. Where each stage runs is data in
`scripts/src/CheckPlan.roc`, never in the workflow: every stage above
belongs to exactly one part, except the per-app stages (each app's builds
for both runners, its specs, its short walk and its broken specs), which
every part runs for its own share of the apps of `SpecSuite.apps` and
`SpecSuite.test_apps`, so every app lands in exactly one part. Apps are
dealt by need: an app a part's own stages use (`CheckPlan.needs`: the
test apps of the native lifetime contracts, the runtime's unit and Chrome
contracts in one part, and the examples of the grammar check, the
examples' journeys and the release dry run in another) belongs to that
part, and the rest are dealt round-robin among `CheckPlan.spare_parts`.
A part prints a `SKIP` line for each stage
another part runs (`SKIP specs ...` never appears: every part runs it for
its apps), and a part given an N other than the plan's, or that would run
nothing, fails. Before its first stage that needs builds, a run makes, in
one bounded batch, the native runners and browser builds of its apps and
of what its stages need, with the `--opt=size` builds a stage checks
(write-scaling's allocation guard, and the module a compiler-keyed skip
runs specs on), so a slow shipping build runs beside the others; the tool's check runs in the release dry run's
part, from its copy. `CheckPlan.builds_made` lists every build a run
makes as its root, target and opt with the stages that use it (the
`signals.roc` tool's own builds of its apps excepted: compiling them is
what it checks). `check -- --plan` prints, for each part, its stages, its
apps, how many builds it makes at `--opt=dev` and `--opt=size`, and any
build another part also makes, then the whole gate's total and any build
it makes twice; `check -- --plan --builds` lists every build of every
part. Its pure `expect`s hold the plan to covering the whole gate (every
stage once, every app once, the whole gate with no option, a refusal for
a wrong or empty part) and to building each root, target and opt once:
once in the whole gate, in no two parts, and in the parts together
exactly what the whole gate builds.

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

Before executing a selected story or emitting its browser steps, the suite
runs `RUNNER --check-suite FILE.scm...` over every spec file for that app.
Each `:never-drawn`, `:never-written`, `:never-runs` or `:never-started`
subject must have positive evidence somewhere in that suite. A marker cannot
validate its own spelling; a name no story ever shows needs no negative
assertion. Stories still start independently, and filtering does not narrow
the files checked for evidence. This mode mounts nothing, reports one ordinary
result per file, and distinguishes parse failures from missing suite evidence.

Chrome replay fixes its page profile before navigation: a 1280 by 900 CSS-pixel
viewport, device scale factor 1, zero-width scrollbars and bundled IBM Plex Sans
and Mono fonts (`tests/browser/fonts/`, with their license). The fonts load
before the first step, including after cross-document navigation; a missing
font fails the replay. App-authored typography still applies. Scroll steps must
reach their exact requested offsets, and pointer `:at` steps must hit their
declared target under this profile; the native oracle gains no layout model.
`tests/browser/page-profile.test.mjs` starts from different device metrics and
checks the profile across repeated navigation. Geometry outside this profile
belongs in a browser contract with its dimensions stated explicitly.

CI runs the Log Explorer, Kanban Board, table test app and scores sample in
both runners on macOS Apple Silicon, macOS Intel and Windows through
`tests/native/selected-specs.mjs`. Those systems also run the debug apps and
the native debug output contract, including a worker child's stderr. The
complete app suites run in the Linux Check jobs; these selected portability
checks do not replace them.

Protocol checks compare the consumer metadata against observations of Core's
actual kind/policy constructors, property constructors and rows, HTTP option
encoders, namespace encoder, template compiler and child-container checks
(`scripts/test_protocol.roc`, with a wrong-number control for every row).
Core imports no consumer metadata. Opcode producer checks remain independent
wire fixtures. Lists without a Core counterpart have their own tests:
`keys-browser.mjs` checks every OutsideText input type, and
`boot-fault-unit.mjs` rejects every exclusion omission and fault-class row
swap while checking host codes 1–5 before declaration metadata exists.

The suite (`check`, `spec`, the docs samples) hands each runner exactly the
spec files it selected and judges the run as a whole
(`SpecSuite.judge`): every selected spec must have exactly one result line,
no other spec may have one, and the exit code must be the one the runner
returns for the lines it printed, 0 when all passed and 1 when one
reported a failure. This matters because the native runner prints a
spec's result only after the spec has run: an engine contract error, an
app's `crash` or a failed `expect` outside a worker job ends its process
with 70 or 71, and that spec and every later one in the invocation print
nothing. The suite then fails with the exit code and the specs left
without a result, instead of counting the specs before them as the whole
run. The emit step (`--emit-steps`) and the Chrome replay are judged the
same way: a spec the parser refuses is an `error` line and exit 1, which
the replay reports as failed; a replay that cannot start Chrome gives no
lines and fails naming every spec. A deliberately crashing spec
(`Checks.crashing_specs`, an outbox posted twice in one turn) keeps this
honest: run natively before the spec it was made from, it must end the run
with 70 and leave both without a result, and the replay must fail it with
the contract's message.

A setup file's name and type are the spec's input, independent of each
other: name and type it as the app's user would have it (`app.log` with
`text/x-log`, `data.bin` with `application/octet-stream`). The replay never
lets the system's table of file name extensions decide a chosen file's
type, and fails if the app's input holds anything but the declared files.

The first-page contracts build the `prerender` app for both runners and a
separate native fixture whose init deliberately crashes. Its `--picture-path`
query must succeed without init, while `--prerender` must reach that init. The
browser holds the real app's Wasm response, checks the parsed inert frame,
then checks replacement, interaction and authored inert preservation. Its
foreign-root fixture uses an explicit immediate HTML inert parent while the
paired spec keeps the actual SVG mount root. Pure template checks cover the
parent/descriptor edge, reserved owner facts and aggregate output bounds;
parent attributes are inserted only at a public parser opening-token boundary.
The raw startup contracts cover producer-owned inertness across failure, retry
and recovery. These legacy replacement contracts remain separate from the
annotated path. Its native contract app (`tests/fixtures/startup-build`) declares
home/tasks entries and initial Self/refusal follow-ups. `startup-producer.mjs`
checks declaration-only catalogue inspection, cold-frame capture, completed
acknowledgement and root/token refusals. The tool's end-to-end check builds every
declared entry by default, holds Wasm in Chrome, observes the cold page, then
checks retained nodes, later scope replacement, interaction and the nested
entry's shared asset receipt. A colliding declared output must leave the entire
published tree unchanged. The legacy Worker Lab must explicitly opt out before
its plain build runs real browser workers. A compiler-boundary edit injection
checks that the project inventory guard refuses publication and preserves the
same complete tree.

`blueprint run startup-browsers` is the additional engine-boundary gate. Its
test-only `playwright-core` 1.65.1 archive is SHA-256 locked in `Blueprint.lock`,
and its CLI installs the matching Chromium, Firefox and WebKit revisions in
Playwright's shared cache (`PLAYWRIGHT_BROWSERS_PATH` can select another cache).
Use `-- --with-deps` on Linux to install the browsers' system dependencies too,
as CI does. This adds no npm project or application runtime dependency. The
task builds `tests/apps/startup-corpus` natively and as Wasm, then runs that
producer/consumer corpus and the independently encoded startup controls in
each engine. Native pages, browser versions, retained-node/state observations
and per-corpus logs are kept in `.build/startup-browsers/` (under
`ROC_SIGNALS_BUILD_DIR` when set). CI uploads those artifacts and requires this
job in its aggregate Check result; it does not replay every SCM spec in three
engines.

The production workflow is `roc signals.roc build` from an app directory. It
reads the compiled finite entry catalogue and stages all annotated pages with
shared immutable assets. `--no-prerender` is the explicit plain-page path for a
legacy or custom loader; legacy `--picture URL...` remains replacement-only.
The original template's exact quoted `app.wasm`/`./app.wasm` loader reference
receives `?roc-build=<asset hash>` before rendering; app-emitted markup and
reserved annotations are never searched or rewritten. The native producer
publishes the cold frame, validating its acknowledgement separately without
performing hosted effects or providing their answers. It also starts a separate
binding instance and checks its cold plan through `Dom.bind_cold` and its real
acknowledgement before publication. The ordinary instance is dropped before
the binding instance starts; only plain oracle metadata survives between them.
This catches declaration-sensitive writers even when initially absent. Changes
to this producer or the native oracle retain applicable optimized roc-fuzz fixed-example replays
as well as native and browser contracts; frontend checks supplement those gates.

A change to the wire protocol changes the engine's encoder and decoders,
`platform/Dom.roc`, both hosts (`platform/host/host.zig`,
`platform/host/spec.zig`), `platform/runtime.mjs`, `platform/startup.mjs`, `platform/environment.mjs`, `platform/worker.mjs`,
the contract tests under `tests/` and Appendix B of `design.md` together,
and bumps the protocol version.

## App-facing or internal

Decide which reader an item serves before adding it. App-facing means
reachable through a module `platform/main.roc` exposes, including members of
wrapped or aliased types and types in public signatures. Write its comment
for an app author: purpose, use, contract and errors, in the guide's vocabulary.
Public signatures spell public names such as `Engine.File`. Wrap an internal
representation when its methods must remain internal, as `Engine.Table` does.
Every member inherited through an alias is part of the public API too.

Internal operations belong to an unexposed module's namespace, beside the
type they work on. Write for a contributor: invariants, ownership, cost,
boundary obligations and rationale. An operation only the engine may perform
must not be a member of a type an app can name. A witness argument does not
make a public member internal.

`check` audits source comments, generated API coverage and dependencies on
`platform/main-fuzz.roc`. Only registered platform fuzz targets may name that
internal package outside the platform and tooling. Type-error fixtures under
`tests/type-errors/` verify that apps cannot reach internal operations.
`blueprint run api` builds and audits the reference without building examples.
The release API comparison uses the actual published platform bundle, or its
one reviewed repair; extraction failures fail the comparison and do not count
as a compatible change.

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
directory with `specs/` whose specs fail natively or in Chrome, or that
holds no spec.

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
those calls 48 times and requires every cycle after a warm-up (`--warm N`,
two by default) to leave no allocation and no byte live. What is measured
is the engine's own: the live counters are read around each call into the
engine and summed over the cycle. An event is replayed to the place of its
listener in the drawn tree, the node's path of child indexes from the mount
root and the event type, found in the oracle's model of the page, which the
replay keeps from the commands outside the measure; so a card the round
trip adds and deletes, or a branch it opens and closes, is reached under
whatever id the cycle gave it. An answer the spec gave (an HTTP stub, a
worker job's answer, a port answer) is replayed as it was first given, to
the request at the same place among those in flight. A cycle whose page
has no node or no such listener at a recorded place, or no request at a
recorded place, is not a round trip, and the soak says so. Every replayed
call must also do the work its recorded call did: the same rows created
and removed, scopes created and disposed, turns, requests issued and
results delivered; a call that does other work fails the soak, naming the
cycle and the call, rather than measuring a different, often idle,
sequence. It is a leak check, never a baseline. Each
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
trips with flat Wasm pages and live allocations. A shorter run uses
`--events N --cycles N`; at least five cycles are required, with three for
warm-up and two nonempty measured halves. Measurements wait for pending
transition updates and animations to finish. It mounts the app with
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
posts (`fx-channel`, `tests/apps/effects/fuzz-channel.roc`), controlled inputs,
pointer gestures with held reports checked against an input-side model,
and more than 4,095 `each` sites (`controls`,
`tests/apps/controls/fuzz-controls.roc`), generated site trees
(`fuzz/structure`, whose pure mode also compares the page with a fresh
mount, so the settle check meets nestings no app contains), tables and
their views against a model that filters, sorts and windows the table from
scratch, over keyed writes, whole rewrites and events that write the table,
the query and the window together (`fuzz/table-view`), the `.scm`
parser (`fuzz/scm-parse`), boot sections (`fuzz/boot`, whose total decoder
accepts only the exact encoding of its decoded value or the empty default
shorthand), the worker wire format's decoder (`fuzz/wire`),
the port message format's decoder (`fuzz/port-json`), URL parsing, builders
and readers (`fuzz/url`), and DOM/Fetch name grammar (`fuzz/names`). Every
target that drives the engine runs the settle check after every step.

`fuzz/startup-placeholders` checks readiness and scoped replacement against a
separate list-based FIFO/lifetime model. Its histories include cold-frame
acknowledgement, zero in-flight capacity, false/true reappend, parent disposal
and remount, nested activation, local state, current values at late activation
and retained stale callbacks. It checks authored trees, exact text work and
registration commands, generation lifetimes, task counters and allocation
balance; it never reads the engine's queue to decide an expected outcome.

An example's targets check its own pure logic and import nothing of the
platform: `fuzz-<subject>.roc` beside the modules it imports, named for
what it checks (the CSV Converter's `fuzz-csv.roc`, the Spreadsheet's
`fuzz-formulas.roc`, the Million-Row Explorer's `fuzz-aggregates.roc`,
and Kanban's `fuzz-board.roc`, whose independent column-list model checks
drops, dense places, card identity and no edit for the current gap), each
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

Judge a target by its properties: state the rules the code must keep over
generated sequences, and check them against a reference model. Its oracles,
not its inputs, carry the value.

### What runs where

Every target is registered in `Targets.fuzz_targets`, and every run starts
from that registry. A target's fixed examples are its declared examples
and its saved regressions (`Fuzz.saved`, in the target's source); a replay
of them shows the target compiles, links and runs, and finds nothing new.
Finding new inputs is a campaign's job.

| Where | What runs | Build | How long |
|---|---|---|---|
| CI, every pull request and push to main | Fuzz smoke: every registered target's fixed examples, in six shards (`fuzz-smoke -- --shard K/6`), beside Check (`check -- --without-fuzz`, in parts) | Plain `--opt=speed` | Estimated from the figures below at 15 to 30 minutes a shard, the one with `structure` the longest; each shard is allowed 60 |
| `blueprint run check` | The same replays as CI's Fuzz smoke job, every target, in one run | Plain `--opt=speed` | Its compilers dominate: estimated at 25 to 40 minutes on an Apple-silicon Mac that compiles one target at a time |
| `blueprint run fuzz-smoke` | Every target's fixed examples, or those named, or one shard | Plain `--opt=speed` | As `check`'s, or a few seconds for one platform-free target |
| `blueprint run check-slow`, local only | Every target's fixed examples on the build a campaign explores | Instrumented `--fuzz` | About a third longer to compile than the plain builds |
| `blueprint run fuzz`, local only | A campaign: each selected target explores from its corpus under `.fuzz-out/` | Instrumented `--fuzz` | 600 s per target by default (`--time S`), plus its build |

CI never runs a campaign, on a schedule or otherwise, and never keeps a
corpus. Run one on your machine with
`blueprint run fuzz -- --time S [TARGET...]`; its corpora stay in
`.fuzz-out/<target>/corpus` between campaigns there. When a campaign finds a
failure, reduce it and add it to the target's examples with `Fuzz.saved`,
so every later replay, CI's included, keeps it fixed.

The costs behind those figures: on an Apple-silicon Mac, the 12
platform-free targets compiled instrumented in about 62 s together and
replayed in under 2 s; a batch of 13 targets that import the engine
package compiled instrumented in about 1,780 s and replayed in about 17 s,
and `structure`, the largest, compiled in 539 s plain against 717 s
instrumented. A target
that imports the engine package compiles the package itself, and a compiler
process is given 16 GiB, so a CI runner compiles one target at a time; the
shards are what run the compilers in parallel, and a CI runner is slower
than that Mac. That is too long to add to the Check job, which is why CI
runs the replays as a job of their own.

### No target is left out silently

Every fuzz run (`check`, `check-slow`, `fuzz-smoke`, `fuzz`) plans its
targets first (`scripts/src/FuzzPlan.roc`): each registered target is
either run or skipped with a reason, and the only reasons are these:

- it was not named, when the run was given target names;
- another shard runs it, when the run was given `--shard K/N`;
- `check -- --without-fuzz`: CI's Fuzz smoke job replays every target.

Each skipped target is printed as `SKIP <target>: <reason>`, and the run
ends with one line, `fuzz: N targets: R ran (P passed, F failed), S
skipped`. The run fails when R + S is not N, when a target it runs has no
result or two, or when a result names a target it did not run. A target
name that is not registered, a shard outside its total and a shard that
would receive no target are refused. A target that fails to build has
failed, and the others still build and run. No platform, missing tool or
compiler version skips a target, and nothing is skipped because its inputs
look unchanged: every run builds every target it runs afresh.

### The plain and the instrumented builds

The maintained targets pin roc-fuzz 0.6.2, which restores compatibility with
`nightly-2026-11-13-03dce41` after its stricter duplicate-name check. The
fixed-example inputs and public fuzz API are unchanged by that patch.

Fuzz builds print compiler phase timings. Use those alongside the replay
report to distinguish time spent compiling the optimized target from time
spent running its fixed examples.

For a fixed-example editing loop, run `blueprint run fuzz-smoke`, or select
whole applicable targets with `blueprint run fuzz-smoke -- controls fx-channel`.
It defaults to all entries in `Targets.fuzz_targets`, including the test-app
targets, and is what `check` and CI run. It builds the same roc-fuzz apps
at `--opt=speed` without coverage instrumentation, then runs their actual
`check` commands with the usual
30-minute per-invocation deadline, allocator observations, trace rules and
leak checks. Compiler, linker, replay and report failures fail the task.
It neither explores new inputs nor replaces an applicable fixed replay with
a compiler check or an `expect`.
Ordinary nonzero compiler, linker, replay and report outcomes are accumulated
while independent targets continue. Process spawn, polling, capture and
filesystem errors fail the batch immediately; that failure never claims all
selected targets were checked.

Its executables, compiler/check logs, roc-fuzz reports and `validation.json`
are under `.build/fuzz-smoke/<target>/` (or `ROC_SIGNALS_BUILD_DIR`). The
validator checks supervised preparation, the complete declared inventory,
saved input hashes, complete observations and traces, and zero outer live
allocations and bytes. It preserves U64 evidence without rounding. The build
metadata records the command, compiler version, entry and binary hashes; it
is not a dependency manifest or an executable cache. A matched-profile proof
also retains the complete frozen source and dependency manifests.

CI runs the plain builds on evidence: they compile in about three
quarters of the time (`structure`: 539 s against 717 s), and their reports
are validated in full, which the instrumented replays' pass line is not.
`check-slow` and `fuzz` keep their instrumented builds under
`.build/fuzz/`; campaigns never select the plain smoke executables. Keep the
covered final checks and guided campaigns: the plain profile does not test
coverage-generated machine code, so a change that could break the
instrumented build (a roc-fuzz or compiler update) runs `check-slow` before
it merges. The task prints compiler and fixed-replay
batch wall times separately, while each build log has compiler phase timings.
Those batch times include scheduling and are not individual target timings.
The small matched URL check established compatibility; it does not establish
a speed improvement for large engine targets.

Protocol consumer facts are checked against Appendix B. Runtime contracts
reject malformed declarations before init, compare every valid Unicode scalar
between the native oracle and Chrome, and check that one mounted module cannot
change another's protocol bindings. `protocol-facts` fixed replays check the
bounded declaration codec; compiler checks do not replace those replays.
Section 12 uses deterministic CBOR from the released roc-cbor 0.6.3 package.
Both platform roots pin the same content-addressed URL, checked by `check`.
The reader bounds bytes, depth and data items before its typed parse, and
checks all vocabulary limits before acceptance. A transport change bumps the
shared protocol and updates the independent malformed-declaration fixtures,
worker version guard and Appendix B together. Dependency source is not
vendored into the platform bundle; an offline build needs its compiler cache
warmed with the exact release.

`Order.roc` supplies pure sort values used by table-view plans and ordinary
Roc sorting. An example's platform-free fuzz modules keep their own ordered
types and import no platform package; the module mounting their table view
applies `Engine.sort_by` to the pure plan.

`fuzz/url` checks strict canonical parsing, decoded builders and readers, and
an independent fragment encoder. Conduit's platform-free `fuzz-routes` checks
decoded route parts; pure location tests and paired specs cover its fragment
layout and browser navigation.

## Performance

The platform's JavaScript ships with its comments, without a minifier. Its
recorded Brotli sizes are a review gate: run `blueprint run sizes -- --runtime-only`
to see current figures, update the affected line in
`scripts/src/runtime-sizes.tsv` with the source change, and explain the cost or
saving in the pull request. The tolerance is 16 bytes in either direction;
it is not growth headroom. `SpecSuite.runtime_files` is the checked inventory,
so every future runtime file needs a figure.

`blueprint run sizes` also prints raw, gzip and Brotli sizes for development-only
scripts and each catalogue example's `--opt=size` module. These have no size
threshold: debug scripts do not ship to production pages, and Wasm sizes follow
the floating Roc compiler as well as this repository. A failed module build is
still a failed check, because its required report is unavailable. Record the
compiler and report alongside a size-sensitive change. The compressor is Node's
zlib module, gzip level 9 and Brotli quality 11, over the exact file bytes; the
helper names the Node, Brotli and zlib versions it ran with.

Brotli is the checked figure because it is a function of the bytes alone on
every Node measured. Gzip is not: Node's official builds bundle Chromium's
zlib, whose level-9 output differs from the reference zlib a packaged Node
(such as Homebrew's) links: the same `runtime.mjs` bytes differ by tens of
bytes between the two, beyond the tolerance. A gzip figure would hold only on
the Node it was recorded with.

Compiler batches refill a vacant process slot as soon as a job finishes;
their logs and results retain input order. The default compiler concurrency
reserves memory per process by what it compiles (`Proc.Footprint`), using
the smaller of physical and constrained memory, and never exceeds
available CPUs: 4 GiB for an app's, a docs sample's or a fixture's
`roc check`, `roc test` or `roc build` at any `--opt` (the peaks measured
were 3.1 to 3.5 GB for development builds and 3.3 GB for a `--opt=size`
build), so a 16 GB CI runner compiles three at a time, and 16 GiB for a
fuzz target's, one at a time. This is scheduling headroom, not a
compiler memory guarantee. Set `ROC_SIGNALS_BUILD_JOBS` to a positive integer
to choose a different process limit; it is still capped by CPUs. Independent
task invocations have independent budgets, so coordinate them when sharing a
machine. Runtime replays use the CPU limit separately from compiler batches.

Measure the build that ships: `--opt=size` for the browser, as the website and
the soak build it. Test how a cost scales with a 10× larger input before
optimizing anything, since scaling problems dwarf constant factors. Browser
timing comes from the js-framework-benchmark adapter in `benchmarks/`.
Validate every change with the specs and the soaks. There are no exact
allocation baselines in the gates; allocation regressions show up as soak
growth or scaling.

`check` also runs a bounded ownership guard in
`tests/runtime/write-scaling.mjs`, over a development and a shipping
(`--opt=size`) Wasm build of `tests/apps/write-scaling`. After setup and one
warm-up, it compares the bytes requested by a keyed write of a table, a write
of one element of a list in a store cell and of one in local state, and a
small write, at two sizes. Allocation count alone misses a growing copy made
by one allocation. Each build asserts the writes that are in place in it and
prints each that still copies beside its compiler issue: in a shipping build
the table's rows (roc-lang/roc#12957), and in both a local state's value
(roc-lang/roc#13012). When a fix lands, move the write into the build's
asserted list in the script. The guard checks teardown too.

## Compilers

Fuzz examples and campaigns always attempt their requested targets. Compiler,
linker and runtime failures fail the task; no compiler version exempts fuzzing.

A compiler defect that blocks a check does not silently skip it. If automation
must route around one, the exemption matches the exact affected compiler
version and prints an explicit `SKIP` naming the upstream issue, so the next
nightly automatically retries the original work. Remove the branch once the
upstream fix is available; do not extend a skip to an unverified compiler
version.

A spec a compiler defect keeps from passing is skipped the same way, and
only through `scripts/src/CompilerSkips.roc`: each entry names the app, the
spec, the runner and build it skips in (Chrome on the development Wasm build
so far), the exact nightlies (`roc version` of the package compiler) it was
verified to fail on, and its upstream issue. The suite prints one `SKIP`
line per skipped spec, in `check` and `blueprint run spec` alike, counts it
as skipped (never passed) in the app's summary, and fails when an entry
names a spec the app does not have. A spec skipped on the development build
also runs in Chrome on an `--opt=size` build of its app, which it must pass.
Today that is the Files app's two handle-lifetime specs, for
[roc-lang/roc#13020](https://github.com/roc-lang/roc/issues/13020). To
remove a skip, delete its entry once a nightly fixes the defect, with the
note in `design.md`'s compiler limitations; a nightly not listed already
runs the spec.

The tooling compiler is `nightly-2026-11-14-a87808d`. The scripts that read
Roc source or markup import roc-parser, so `roc-stable` moves only to a
nightly the pinned parser release checks on; toolchains before
`nightly-2026-11-13-03dce41` cannot resolve the parser's nominal type
aliases. The scripts and the `signals.roc` tool use basic-cli 0.28.1, which
checks without warnings on the tooling compiler. `Blueprint.lock` records the
published archive digests for each supported system.

The repository follows roc-automation's three-compiler model:

| Compiler | Selected by | Used for |
|---|---|---|
| Blueprint's own | The `blueprint` release `Blueprint.roc` names | Evaluating `Blueprint.roc` |
| `roc-stable` | The nightly tag in `Blueprint.roc` | Running and checking the scripts under `scripts/`, except the keyboard oracle's exporter `scripts/unicode_symbols.roc`, which imports the platform and is built by `roc` |
| `roc`, the latest Roc nightly | Nothing: whatever `roc-lang/nightlies` published last | Checking, building and testing the platform, the examples, the tests and the docs samples |

The platform floats on purpose: the question each pull request answers is
whether it works with the compiler users install today. CI resolves the
latest nightly once per run and installs it as `roc` with
`roc-lang/setup-roc`; locally, install the current nightly as `roc`. No Roc
file outside `scripts/` names a compiler, and `check` fails if one does.

To move `roc-stable`, in one pull request:

1. Change the `Recipes.roc_nightly(...)` tag in `Blueprint.roc`.
2. Change the `roc` field of every script under `scripts/` that has one to the same tag;
   `check` fails until they match.
3. Run `blueprint update` and commit `Blueprint.lock`.
4. Run `blueprint run check`.

When a new nightly breaks the platform, CI says so on the next pull request;
fix it there, and remove any workaround whose upstream issue the nightly
fixes, with its row in `design.md`'s compiler limitations. The
nightly-compatibility workflow separately tests the latest release against
the latest nightly every day.

## Native crypto ABI

The native crypto result is checked field by field against
`platform/host/crypto_abi.zig`, generated by `roc glue` from the concrete
`platform/crypto-abi.roc` fixture. The fixture imports the real `Cli` hosted
signatures; the ordinary platform's generic store has no committed layout
before an app specializes it. `crypto_result.zig` checks field names, order,
offsets and field layouts, including both pointer widths.

After changing that seam, use the Zig glue script from the source tree of the
compiler being tested, then replace the generated artifact unchanged:

```sh
roc glue --opt=size /path/to/roc/src/glue/src/ZigGlue.roc .build/crypto-abi platform/crypto-abi.roc
cp .build/crypto-abi/roc_platform_abi.zig platform/host/crypto_abi.zig
zig build-obj platform/host/crypto_result.zig -target wasm32-freestanding -femit-bin=.build/crypto-abi32.o
zig build-obj platform/host/crypto_result.zig -femit-bin=.build/crypto-abi64.o
```

The native soak records derivation inputs, then derives the same mathematical
key afresh when replaying a key result. It retains no original key handle.
Its allocation measurement includes staging and consuming the fresh handle
list together, so an argument's release cannot look like an allocation gain.

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
- `runtime.mjs`, its `environment.mjs` fact readers and `worker.mjs`, served together;
- `signals-<hash>.tar.zst`, the `signals.roc` tool's package, and
  `signals.roc`, the small app an author downloads to run it: it names
  basic-cli and that package, and pins no compiler;
- `roc-signals-examples-<version>.zip`, each example's `main.roc` naming that
  bundle with its modules and specs, and the compatibility suite;
- `roc-signals-docs-<version>.zip`, the API docs;
- notes stating both compilers (the `roc` nightly that built and tested it,
  and `roc-stable`), to which the maintainer adds the narrative on GitHub
  before publishing.

For a version `X.Y.Z` the task also runs the API comparison with
`roc bump --expect X.Y.Z`, so a release whose number is smaller than its API
changes require (0.5.1 after a breaking change to 0.5.0) fails
before anything is published. A prerelease or the dry run claims no number
and is not compared there; `check` compares every pull request without one.

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

The debug contracts use `tests/apps/dbg`: ordinary paired specs cover its
handler, reader and task answers; `dbg-browser.mjs` separately asserts bounded
observations and fault/console behavior; `tests/native/dbg-output.mjs` rejects
extra settle-reader output. Its intentional fault controls exclude it from
walks; its round trip remains a native soak. Debug observations add no SCM
step. The host’s buffer is independently checked by `zig test platform/host/dbg.zig`.


The `unsafe-html` test app keeps imported descendants opaque in paired specs.
Its Chrome contract checks the browser parser, inline handlers, custom elements,
link click facts, stale queued targets and malformed payloads directly. Its round
trip is a native allocation soak. `structure` replays generated opaque-source
updates, row moves and disposal against fresh mounts and `Core.settled`; `links`
checks scheme policy against an independent model, with browser URL differentials
in the HTML contract. Picture refusal includes initially empty wrappers.
