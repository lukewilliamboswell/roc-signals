+++
title = "Contributing"
description = "Working on the platform itself: tools, tasks, tests, docs, performance, the compiler pin and releases."
weight = 12
template = "page.html"
+++

# Contributing

This page is for people changing the platform, its tests, the examples or this
site. The architecture and its rules are in
[design.md](https://github.com/lukewilliamboswell/roc-signals/blob/main/design.md);
repository-wide review guidelines are in `AGENTS.md`, and Roc conventions in
`style.md`.

## Tools

[Blueprint](https://github.com/lukewilliamboswell/roc-blueprint) provides
every tool. `Blueprint.roc` declares the pinned Roc nightly (`roc-stable`),
Zig, Node, Zola, Tailwind and roc-docs, and the tasks below; `Blueprint.lock`
records the SHA-256 of every download. Install the `blueprint` release that
`Blueprint.roc` names; no Nix is needed. `blueprint shell` opens a shell with
the tools on `PATH`.

Chrome is the machine's `google-chrome` for now, because blueprint cannot yet
unpack Chrome for Testing's zip archives; `Blueprint.roc` has the pinned
recipe ready.

## Layout

| Path | Contents |
|---|---|
| `platform/` | The web platform (`main.roc`, `Engine.roc`, `Html.roc`, `host/host.zig`, `runtime.mjs`) and the native test platform (`test.roc` and the roc-fuzz modules) |
| `test-support/` | The `.scm` parser (`Scm.roc`), the native spec runner, the `Dom.roc` oracle and the soak walk |
| `tests/` | Browser contract tests and the apps they drive, the Chrome spec replay, and the release check helper |
| `fuzz/` | Fuzz targets of the shared support; each app's own target is its `main-fuzz.roc` |
| `examples/` | The example apps, each with its specs |
| `benchmarks/` | The js-framework-benchmark adapter |
| `scripts/` | Roc scripts behind the tasks; shared modules in `scripts/src/` |
| `www/` | This site; `www/samples/` holds every code sample the docs show |

## Tasks

| Task | What it does |
|---|---|
| `blueprint run check` | The pull-request gate (below) |
| `blueprint run check-slow` | Every fuzz target's declared examples, the leak-checked native soaks with flat round trips, and a long Chrome session per app |
| `blueprint run spec -- [--browser] [--filter GLOB] [APP...]` | Some apps' specs, natively and optionally in Chrome |
| `blueprint run platform-test` | Fetch and build the test platform's host, to build a `main-test.roc` by hand |
| `blueprint run jfb` | Build the js-framework-benchmark app and check its operations in Chrome |
| `blueprint run fuzz -- [--time S] [TARGET...]` | A fuzz campaign |
| `blueprint run site -- [--base-url URL]` | Build the site, the API docs and the example apps into `dist/` |
| `blueprint run serve -- [DIR] [--port N]` | Serve `dist/` (or `DIR`) on `127.0.0.1:8000` |
| `blueprint run release -- --version V` | Build the release assets into `dist-release/` |

To browse the site locally:

```sh
blueprint run site -- --base-url http://127.0.0.1:8000
blueprint run serve
```

Builds go to `.build/`; set `ROC_SIGNALS_BUILD_DIR` to use another directory,
for example to run two tasks at once.

## What `check` runs

1. Every script names the `roc-stable` nightly that `Blueprint.roc` pins.
2. `roc fmt --check` over every Roc source, and `roc test` on the test support
   and the scripts.
3. The test platform, and the `scm-parse` fuzz target's examples.
4. The docs samples (below).
5. Every app's specs natively and in Chrome, then a deliberately broken spec
   that both runners must reject.
6. The runtime contract tests in Chrome: effects, controlled inputs, and the
   Conduit journey against its scripted backend.
7. The js-framework-benchmark check.
8. The release dry run: the bundle, `runtime.mjs`, the examples archive with
   every app mounted by its check helper, and the release notes.

An expected failure is listed with its reason in `scripts/src/SpecSuite.roc`
and must keep failing; one that starts passing fails the suite.

## Specs and contract tests

Application-visible behaviour is specified in `.scm` files beside each app and
runs in both runners from one parser, `test-support/Scm.roc`. An unknown step
is a parse error; a runner that cannot honour a step fails it. The language is
documented in [Testing](@/docs/testing.md).

A change to the wire protocol changes the engine's encoder,
`test-support/Dom.roc`, `platform/runtime.mjs`, the contract tests under
`tests/` and Appendix B of `design.md` together, and bumps the protocol
version.

## Docs samples

Every Roc code block on this site comes from a file under `www/samples/`,
shown with the `sample` shortcode:

```text
{{/* sample(file="todos/Todos.roc", region="row") */}}
```

A region is the lines between `# region NAME` and `# endregion NAME`. `check`
fails on an inline Roc block in a docs page, a missing sample or region, a
sample that does not type-check, and a sample directory with a `main-test.roc`
whose specs fail natively or in Chrome.

## Fuzzing

Fuzz targets decode arbitrary bytes into valid sessions and check them
against a model: keyed reconciliation, the effect channel's lifecycle, and
each app's leak-checked random walk. `check` replays the parser target's
examples; `check-slow` replays every target's; `fuzz.yml` runs nightly
campaigns with the corpora in the Actions cache. When a campaign finds a
failure, reduce it and add it to the target's examples with `Fuzz.saved`, so
every later replay keeps it fixed.

## Performance

Measure the build that ships: `--opt=size` for the browser, as the site and
the soak build it. Each app's fuzz target has `bench-N` examples that mount N
items and measure single transactions with allocation counters; compare a 10×
larger N before optimizing anything, since scaling problems dwarf constant
factors. Browser timing comes from the js-framework-benchmark adapter in
`benchmarks/`. Validate every change with the specs and the soaks. There are
no exact allocation baselines in the gates; allocation regressions show up as
soak growth or scaling.

## The compiler pin

The repository pins one Roc nightly, `roc-stable`, and builds everything with
it: scripts, the platform, the examples and the tests. To move to a newer
nightly, in one pull request:

1. Change the `Recipes.roc_nightly(...)` tag in `Blueprint.roc`.
2. Change the `roc` field of every script under `scripts/` to the same tag;
   `check` fails until they match.
3. Run `blueprint update` and commit `Blueprint.lock`.
4. Run `blueprint run check` and `blueprint run check-slow`, and fix what the
   new compiler breaks.
5. Remove any workaround whose upstream issue the new nightly fixes, and its
   row in `design.md`'s compiler limitations.

The nightly-compatibility workflow tells you when a release stops building on
the latest nightly; it never changes the pin itself.

## Compiler workarounds

A workaround for a compiler defect is narrow, sits beside a comment linking
its upstream `roc-lang/roc` issue, and is listed in `design.md`. File the
issue with a minimal reproduction before adding the workaround; the
reproduction lives in the issue, not in this repository.

## Releases

A maintainer dispatches the `Release` workflow with a version. It builds the
assets with `blueprint run release` and creates a draft GitHub release with:

- the platform bundle, `<hash>.tar.zst`, which apps name as their platform;
- `runtime.mjs`;
- `roc-signals-examples-<version>.zip`, the examples naming that bundle, with
  the compatibility suite;
- `roc-signals-docs-<version>.zip`, the API docs;
- notes stating the compiler used, to which the maintainer adds the narrative
  on GitHub before publishing.

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
- **One pinned compiler for everything.** The engine's speed and code size
  depend on specific compiler behaviour (see `design.md`'s compiler
  limitations), so the platform and examples are tested with `roc-stable`,
  not the latest nightly. The nightly workflow covers the latest nightly
  against releases.
- **Specs, not `tests/spec.json`, test the working tree.** The examples are
  browser apps; `.scm` specs run in both runners. The examples archive
  carries a `spec.json` only for the shared nightly runner.
- **Examples are directories** with `main-web.roc`, `main-test.roc` and
  `main-fuzz.roc`, not a single `main.roc`, because each app builds for two
  platforms.
- **The release workflow is hand-written** and publishes a draft whose notes
  are written on GitHub, rather than the shared package release workflow and
  notes under `docs/releases/`.
- **No SBOM yet.** Release SBOMs are tracked as an issue.
