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
- GitHub CLI (`gh`), authenticated for release operations and optional
  attestation inspection,
- Node.js,
- Zola,
- the Tailwind CSS 3.4.17 standalone CLI (the site uses the v3 configuration),
- Roc.

Local scripts use `roc` from `PATH` by default. Override it with `ROC_BIN`,
`ROC`, or `python3 scripts/test.py --roc-bin /path/to/roc`.

CI uses the official `roc-lang/setup-roc` GitHub Action. The repository does not
build Roc itself. The site build uses standalone command-line tools only; there
is no npm dependency or package manifest.

Pull requests and pushes to `main` run a bounded hosted source gate: Zig and
browser contracts, Roc checks and tests, Wasm builds and size budgets, fuzz
corpus replay, and ordinary native semantic specs. Change selection adds GUI
and site jobs only when their inputs are affected. `Platform source` is the
required aggregate check. Exact archive creation and release-URL example smoke
tests belong to the combined release workflow, which validates the same
candidate on Linux, macOS, and Windows before publication. Pages deploys the
supported release, not development builds from ordinary pushes.

Compiler pins live in both platform headers and every web and GUI example
header, including internal web fixtures. `.github/roc-nightly.json` selects all
of them for coordinated compiler updates; adding an example requires registering
its header there. Public web dependency URLs remain unchanged during these updates. Run
`python3 scripts/toolchain.py --check --roc-bin /path/to/roc` to validate the
selected roots and installed compiler. The nightly bot advances those pins while
preserving release URLs and automatically merges only a passing pin-only PR.

## Pre-commit CI check

Run the mini-CI entry point before committing:

```sh
python3 scripts/minici
```

It runs every locally reproducible CI area: selection checks, the complete web
and shared source suite, fuzz corpus validation, coverage on macOS, GUI
semantics and real rendering, published examples, release archive validation,
and the documentation site. Linux requires Weston and Xvfb for the rendering
check; macOS and Windows launch the built applications directly. Hosted CI uses
the `hosted` mini-CI target for bounded pull-request feedback; the default local
run additionally covers the slower fault, benchmark, bundle, and coverage
campaigns. Platform-specific linking and archive checks still run on their
corresponding CI runners.

During investigation, pass one or more target names, such as
`python3 scripts/minici gui gui-smoke gui-scenarios`, but run the complete command before
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
python3 scripts/test.py gui
python3 scripts/test.py fault --native always
python3 scripts/test.py bundle --bundle always
python3 scripts/test.py bench --native always
python3 scripts/test.py size --roc-bin /path/to/roc
```

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
it for a deliberately small set of platform-owned fixtures. Application
projects can opt selected cases into an explicit fault run when their graph or
lifecycle shape warrants the additional coverage. Fault injection does not add
syntax or behavior to the `.scm` case itself, and it is deliberately not part
of `zig build test`.

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
browser DOM, no unpublished task execution, detached event listeners, and
allocation-free idempotent containment. Recovery uses a fresh instance. This
linked-app fatal campaign complements native refusal/retry tests; it does not
turn arbitrary native crashes into accepted outcomes. Roc-allocator fatal
boundaries also have focused linked-host tests.

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

Roc app executables built during tests are written under `.test-out/` by
`scripts/test.py`.

## Dependency artifact releases

### Web host inputs

The `Web host inputs` workflow builds the four native web spec hosts and the
Wasm browser host only when their actual Zig sources or build recipe change. It
tests native and Wasm application paths, then packages five target-confined
archives under one immutable `deps-web-hosts-<version>` release. Each archive
and its reviewed lock entry records both its exact SHA-256 and the shared narrow
host-input fingerprint. Application modules, examples, platform API files,
documentation, and release packaging do not change that fingerprint.

Ordinary CI and combined platform releases consume `web-host.lock.json`; they
do not compile these hosts. GitHub attestations remain available for external
provenance inspection, while ordinary admission uses the reviewed content
hashes without calling an attestation service. The independently released musl
startup objects and libc archives remain final linker inputs rather than web
host outputs.

### macOS linker interfaces

To inventory the compiled Rust host's external references without reading SDK
interfaces, build the optimized archive and use the active Rust toolchain's
LLVM reader. The matching reader is necessary because the static library can
contain Rust standard-library bitcode that older Apple or Homebrew tools cannot
read:

```sh
rustup component add llvm-tools-preview
TOOLCHAINS=Metal cargo build --locked -p signals-gpui-host --release -j 2
python3 scripts/audit_macos_archive.py target/release/libsignals_gpui_host.a --output /tmp/rust-host-imports.json
python3 -m unittest scripts/test_macos_archive_audit.py
```

For a custom Cargo target directory, substitute its release archive path. Supply
additional archives as positional arguments to subtract their definitions too;
for example, include `platform-gui/targets/arm64mac/libengine.a` from the same
platform build. The report records archive hashes, the reader version, and each
external symbol's referring members. A reader failure aborts the inventory
instead of publishing partial results. `--llvm-nm` selects an explicit compatible
reader when inspecting an archive from another Rust toolchain.

This is a conservative archive inventory before extraction and dead stripping.
It includes application callbacks and unused dependency code. It does not assign
symbols to frameworks or establish weak-import attributes or interface provenance.
Use it to review required interfaces; a minimal stub set additionally needs
reviewed library ownership and final-link validation for the released archives
and supported compiler.

The reviewed catalog in `dependencies/macos-interfaces/interfaces.json` selects
symbols for generated TBD files and records the source URLs for each interface.
The producer consumes this catalog without reading host or SDK bytes:

```sh
python3 scripts/build_macos_stubs.py \
  --output /tmp/macos-interfaces-candidate
```

`dependencies.lock.json` selects `deps-macos-interfaces-20260910.1` by exact
archive size and SHA-256. Ordinary GUI tests and `bundle_platforms.py` stage its
exact TBDs, catalog, provenance statement, manifest, and dependency receipt;
they never invoke the generator. Changing the catalog requires a new producer
release and reviewed lock update. Changing a host requires only final-link
validation against the selected interface release; it does not regenerate or
relabel those linker inputs.

The `macOS interface dependency releases` workflow generates the catalog-only
`.tbd` archive twice, compares the exact bytes, and then performs final Roc
application links and native GUI specs against the attested host selected by
`gui-host.lock.json`. An explicit dispatch on `main` with a fresh
`deps-macos-interfaces-<version>` tag publishes the tested archive and its
consumer lock with GitHub build provenance. Generation reads neither host nor
SDK bytes; the host is an independently released validation input, not part of
the generated artifact's identity. Review and adopt the emitted lock entry
separately. The adopted entry is consumed by ordinary CI and GUI package
bundling without an online attestation check.

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

The `Complete Windows system import releases` workflow builds its independent
pure-import package on Linux x86-64 and executes the exact candidate on Windows.
It installs the recipe's checksum-pinned Rust and Zig tools itself. To reproduce
both builds with Python 3.12 or newer:

```sh
python3 scripts/build_windows_system_imports.py --output /tmp/windows-imports-a --cache /tmp/windows-import-downloads
python3 scripts/build_windows_system_imports.py --output /tmp/windows-imports-b --cache /tmp/windows-import-downloads
cmp /tmp/windows-imports-a/windows-system-imports-x64mingw.tar /tmp/windows-imports-b/windows-system-imports-x64mingw.tar
python3 scripts/test_windows_system_import_artifact.py /tmp/windows-imports-a/windows-system-imports-x64mingw.tar
```

The last command requires Zig 0.16.0. On Windows, run the same candidate probe
with `--require-native`; cross-linking on Linux is not a native runtime test.
Publication uses a fresh `deps-windows-system-imports-<version>` tag on `main`
after both build and native jobs pass. This package does not yet replace existing
Windows consumer inputs or provide CRT implementations.

GUI CI caches compiled Cargo dependencies using the lockfile, Rust environment,
and runner image identity. Only successful pushes to `main` save the cache;
pull requests restore it without publishing entries. Workspace host code remains
outside that dependency cache and is rebuilt from the current checkout. This is
a build acceleration mechanism, separate from verification of release inputs.
Published-download checks continue to use fresh Roc caches.

Pull-request CI selects affected jobs from the complete merge-base diff using
`scripts/ci_changes.py`. GUI-only changes run the native GUI jobs; web changes
run browser/native checks, published examples, and release archive checks.
Known documentation paths run the site check. Shared engine changes, build
infrastructure, compiler/dependency locks, and unknown paths select every area.
Renames count at both their old and new paths. Main-branch pushes and manual
validation still run every area, and release workflows retain their full gates.
The required `Platform source` check verifies the selection job and requires
success from every selected job; it accepts a skip only for an unselected area.
New commits cancel superseded PR CI runs, but do not cancel main or release runs.

The `Windows dependency releases` workflow independently generates the ADVAPI32
import library from the definition and license hashes in
`dependencies/windows-imports.json`. It executes a probe linked against that
candidate on Windows and compares two builds before signing. Dispatch it on
`main` with a new `deps-windows-imports-<version>` tag. The emitted lock identifies
`windows-dependencies.yml` as its signing workflow. To exercise its producer:

```sh
python3 scripts/build_windows_imports.py --output /tmp/windows-import-candidate
python3 scripts/test_windows_import_artifact.py /tmp/windows-import-candidate/windows-imports-x64win.tar
```

The second command cross-links on Linux; native execution is required on Windows
before publication. This artifact contains no Signals host or application
manifest resource.

The `FreeType dependency releases` workflow builds the pinned upstream source
from `dependencies/freetype.json`. On Linux x86-64, Python 3.12 and Docker are
sufficient to run the same producer:

```sh
python3 scripts/build_freetype.py --output /tmp/freetype-candidate
python3 scripts/build_freetype.py --output /tmp/freetype-rebuild
cmp /tmp/freetype-candidate/freetype-x64glibc.tar /tmp/freetype-rebuild/freetype-x64glibc.tar
python3 -m unittest scripts/test_freetype_dependencies.py
```

Source downloads are cached by digest under `~/.cache/roc-signals/sources` and
verified again before each build. Docker constructs the reviewed builder from
its base-image digest, bootstrap CA and Zig distribution digests, and authenticated Ubuntu package
snapshot; the actual compilation has no network access and does not mount Cargo
or platform target directories as build inputs. Each candidate is extracted and
tested by rendering an exact glyph bitmap. No compiler pin or platform host
build is involved. CI repeats the build in another clean container before
publication.

Dispatch this workflow on `main` with a new `deps-freetype-<version>` tag to
publish tested bytes and their lock through `freetype-dependencies.yml`.
Review and merge the lock entry separately when adopting the dependency. The
Linux GUI builder verifies that release before compilation; the bundler verifies
it again in fresh staging and excludes the development copy of `libfreetype.so`.
Combined GUI bundles retain the lock entries and notices for FreeType,
xkbcommon, Windows imports, glibc link inputs, and the LLVM unwinder. Linux CRT
and unwinder inputs come from their independent verified releases.
The artifact preserves FreeType's system SONAME; applications still use the operating
system's runtime font libraries. The C compiler is Zig 0.16.0, targeting baseline
x86-64 and glibc 2.39; the separate Roc compiler pin is preserved.
The Linux link list omits the legacy `libutil`, `librt`, `libpthread`, and
`libdl` compatibility libraries. The supported glibc provides the required
symbols through libc; both native application specs and rendering smoke tests
exercise this link list. xkbcommon and its X11 library remain required inputs.
See `dependencies/README.md` for the input and
runtime boundaries.

The `glibc dependency releases` workflow generates Linux x86-64 startup and
glibc link inputs from the checksum-pinned Zig distribution. Reproduce it with
Python 3.12 and Docker:

```sh
python3 scripts/build_glibc.py --output /tmp/glibc-candidate
python3 scripts/build_glibc.py --output /tmp/glibc-rebuild
cmp /tmp/glibc-candidate/glibc-x64glibc.tar /tmp/glibc-rebuild/glibc-x64glibc.tar
python3 -m unittest scripts/test_glibc_dependencies.py scripts/test_dependency_artifacts.py
```

Both builds run the native probe against their extracted candidate. Dispatch
`glibc-dependencies.yml` on `main` with a new `deps-glibc-<version>` tag to attest
and publish the tested bytes. The archive contains corresponding source and a
standalone reproduction tree under `sources/glibc/`; run the same build command
from that directory to reproduce the producer. Review the resulting consumer
lock and platform link-input changes separately before adoption. Normal GUI
builds reuse this pinned release, and bundles retain its complete source and
notice payload alongside the link inputs. Admission requires the target-specific
header source payload plus complete glibc, LLVM and Linux header license terms;
older artifacts missing those notices are refused.

The `xkbcommon dependency releases` workflow independently builds both keyboard
libraries from the source and tool versions pinned in `dependencies/xkbcommon.json`.
Its native Meson configuration uses Zig. To reproduce the producer on Linux x86-64
with Python 3.12 and Docker:

```sh
python3 scripts/build_xkbcommon.py --output /tmp/xkbcommon-candidate
python3 scripts/build_xkbcommon.py --output /tmp/xkbcommon-rebuild
cmp /tmp/xkbcommon-candidate/xkbcommon-x64glibc.tar /tmp/xkbcommon-rebuild/xkbcommon-x64glibc.tar
python3 -m unittest scripts/test_xkbcommon_dependencies.py scripts/test_prepare_dependencies.py
```

Dispatch `xkbcommon-dependencies.yml` on `main` with a new
`deps-xkbcommon-<version>` tag to publish the tested, attested archive. Review the
resulting lock entry separately. Normal GUI builds download and verify the pinned
release; they do not rebuild xkbcommon or copy its link libraries from the build
machine. Bundles independently verify and stage both libraries and their license.
The runtime still uses the operating system's xkbcommon/XCB libraries and keyboard
layout data through the libraries' existing SONAMEs.

The `LLVM unwind dependency releases` workflow independently builds Linux x86-64
`libunwind.a` from the same checksum-pinned Zig distribution. Reproduce the two
container builds and test Rust panic recovery with Rust 1.95.0 installed:

```sh
python3 scripts/build_unwind.py --output /tmp/unwind-candidate
python3 scripts/build_unwind.py --output /tmp/unwind-rebuild
cmp /tmp/unwind-candidate/unwind-x64glibc.tar /tmp/unwind-rebuild/unwind-x64glibc.tar
python3 scripts/test_unwind_rust.py --candidate /tmp/unwind-candidate/unwind-x64glibc.tar
python3 -m unittest scripts/test_unwind_dependencies.py scripts/test_glibc_dependencies.py
```

Each build tests C++ exception handling and destructor execution using the
extracted candidate with explicit final link inputs. Rust's probe checks panic
recovery and `Drop` execution. Dispatch `unwind-dependencies.yml` on `main` with a
new `deps-unwind-<version>` tag to attest and publish the tested archive. Original
sources, notices, and reproduction inputs accompany `libunwind.a`; C++ support
archives used only by the producer probe are excluded. Adopting the resulting
consumer lock is a separate review. Linux GUI host builds and bundle staging
verify that lock and use its `libunwind.a`, preserving notices and reproduction
sources in bundles. No ambient GCC unwinder is copied into platform inputs.

For host-license review, `scripts/rust_license_inventory.py` collects original
notices from the crate archives selected by a `cargo-about --format json`
report. It checks each archive against `Cargo.lock`, preserves the publisher's
manifest separately, and reports packages without standalone notice files:

```sh
python3 scripts/rust_license_inventory.py --about /tmp/host-about.json --lock Cargo.lock --cache /path/to/cargo/registry/cache --supplements dependencies/gui-host-notices/manifest.json --review dependencies/gui-host-notices/review.json --include-sources --output /tmp/host-notices
python3 -m unittest scripts/test_rust_license_inventory.py
```

The cache argument names the directory containing the downloaded `.crate`
archives. Supplements preserve original upstream notice files and are admitted
only when their crate hash and Git revision match the published archive. Their
own bytes are checked against the reviewed manifest. The report determines the
selected package set; this collector does
not establish that the selection covers a host binary, resolve missing upstream
notices, or account for toolchain runtime notices. Its inventory is review
evidence, not permission to publish an incomplete host package.

`--include-sources` also retains each selected original `.crate` archive with
its locked hash. This preserves notices embedded in source comments and makes
the published source available for review. Retaining source does not establish
that an absent license grant exists; packages without standalone notices remain
explicit in `missing_notice_files`.
`--review` regenerates selected original source comments, declarations, and
upstream caveats from the hash-bound review manifest. Its evidence categories
do not certify permission or make standalone-file absence a publication blocker.

Collect toolchain notice evidence separately from the distributions pinned in
`dependencies/gui-host-notices/toolchains.json`:

```sh
python3 scripts/toolchain_license_inventory.py --target x64glibc --rust-archive /path/to/rustc-1.95.0-x86_64-unknown-linux-gnu.tar.xz --zig-source-archive /path/to/zig-0.16.0.tar.xz --output /tmp/host-toolchain-notices
python3 -m unittest discover -s scripts -p test_toolchain_license_inventory.py
```

The collector verifies archive hashes before reading notice files. It retains
Rust's standard-library copyright report and license texts, plus Zig's license
and complete original source archive so source-level notices are preserved.
Use the recipe's Rust distribution for the selected target. This is review
evidence; it does not identify which runtime components a particular host links
or cover SDK inputs. The release composer incorporates both inventories into the host/source pair
with the actual compiled dependency selection and publication validation.

Explicit GUI host release dispatches build only the selected native host targets.
Pull requests validate complete host/source pairs on Linux, Windows, and macOS.

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

Build both app-independent hosts and create both platform bundles:

```sh
scripts/bundle.sh
# Build and serve web/ and gui/ bundles plus URL-bound GUI example sources:
scripts/bundle.sh --serve --port 8000
```

The script uses `ROC_BIN`, `ROC`, or `roc` from `PATH`; use the pinned compiler.
Archives and `bundles.json` default to `.test-out/bundles`, with separate `web/`
and `gui/` directories. `BUNDLE_OUT_DIR` or `--output-dir` changes that root.
`--package web` and `--package gui` select one platform and put its archive
directly in the output directory. `--no-build` reuses prepared hosts;
`--debug-gui` selects a faster development Rust build. Use the default optimized
GUI build for distributable archives. A fat GUI archive containing every native
target exceeds the compiler's default 100 MiB expanded transitive package budget;
local-file platform builds passing does not establish that a URL-bound bundle
can be consumed. Release-candidate checks therefore pass the implemented
`--max-transitive-mb=512` option explicitly. The older diagnostic's suggested
`--max-transitive-bytes` spelling is incorrect. See `UPSTREAM_COMPILER_BUGS.md`
for the reproduction and keep the override visible until host-size work makes it
unnecessary.

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
The pinned compiler's dev backend currently emits invalid Wasm for unit-valued
capability callbacks (see `UPSTREAM_COMPILER_BUGS.md`, case 10), so ordinary
Wasm smoke builds use `--opt=size` as a narrow workaround. TODO: switch those
builds to `--opt=dev` once the upstream bug is fixed. The optional `--app-opt
dev` site build remains a compiler diagnostic, not a passing release gate or a
deployable alternative. Keep artifact validation enabled. After checking dev
output, rebuild with `--app-opt size`; both modes write `dist/`.

## Releases

Keep user-facing changes and migration instructions in `releases/unreleased.md`,
reviewed alongside the implementation. Before publishing, rename it to
`releases/<exact-release-tag>.md` (unprefixed SemVer, such as `0.2.0-rc1`),
replace the unreleased heading with that version, and name the explicit
source → target version in the migration section. Create a fresh unreleased file
when work on the next release begins. Published notes describe that upgrade;
do not rewrite them to follow later APIs. The site guides document the supported
API and link to releases rather than duplicating version-specific instructions.

Dispatch `Combined platform release candidate` on `main` with `release_tag` and
`validate_only: false`.
The release guard explicitly permits exact-nightly bootstrap; it does not claim
a stable Roc compiler exists. Preparation records the final source SHA, downloads
and content-hash verifies the immutable web hosts, GUI hosts, and external linker
inputs, then runs `roc bundle` exactly twice. It builds no Zig or Rust code. The
result is one web platform archive, one fat GUI platform archive, and
`signals-examples.zip`; the latter contains two distinct app roots whose headers
name their corresponding final asset URLs. `signals-release.json` records those
URLs, SHA-256 digests, sizes, input locks, compiler pin, and the explicit fat-package
budget.

To exercise preparation locally:

```sh
python3 scripts/release.py prepare --version 0.2.0-rc3
python3 scripts/release.py check
python3 scripts/release.py verify
```

Preparation requires a clean committed checkout so its source SHA identifies the
actual inputs. Output defaults to ignored `.release-out/` and must be empty;
retain an existing candidate when investigating or recovering a release. Linux
x64, Apple Silicon macOS, and Windows x64 runners each download the same candidate,
serve both exact platform archives over loopback, verify every extracted app header,
and run web and GUI smoke paths. Web apps build for Wasm on every runner and use the
native spec host where available. Every GUI app builds for the runner's native
target, runs semantic specs, and must report successful rendering. Only those
already-tested bytes reach the single publishing job. `validate_only: true` runs
the complete flow without creating a tag or release.

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
- `(shortcut <locator> "<key>" <modifier-mask>)` (native GUI)
- `(focus <locator>)`, `(blur <locator>)`
- `(composition-start <locator>)`, `(composition-end <locator>)`
- `(change <locator> "<value>")`, `(select-option <locator> "<value>")`
- `(custom-event <locator> "<event-name>" "<detail>")`
- `(submit <locator>)`, `(fill <locator> "<text>")`
- `(check <locator>)` and `(uncheck <locator>)`

`shortcut` dispatches the exact `Gui.on_shortcut` binding declared on the located
region through the shared engine. Keys use the public canonical vocabulary;
modifier bits are Control `1`, Shift `2`, Alt `4`, and Meta `8` (add them for a
combination). For example, `(shortcut (test-id "editor") "s" 3)` invokes
Control+Shift+S. Missing bindings, invalid keys, and masks outside `0..15` fail.
This command checks application semantics and scope disposal. GPUI interaction
tests cover focused routing, native editor precedence, and event propagation.

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

### Readable native file fixtures

Use structured Files settlements for application workflows so specs do not need
hand-counted UTF-8 frames or knowledge of the private `files1` payload:

```lisp
(click (role button :name "Open…"))
(expect-pending-task "notes-open" 1)
(resolve-file-choice "notes-open" (chosen "/tmp/meeting.txt"))
(resolve-file-read "notes-read" :path "/tmp/meeting.txt" :text "First line\nSecond line: λ")
(expect-value (label "Note text") "First line\nSecond line: λ")
```

The complete initial vocabulary is:

```lisp
(resolve-file-choice "save-path" (canceled))
(resolve-file-choice "save-path" (chosen "/tmp/project.board.json"))
(resolve-file-read "read" :path "/tmp/note.txt" :text "Contents")
(resolve-file-write "write" :path "/tmp/note.txt" :bytes 8)
(reject-file "read" :kind permission-denied :detail "/tmp/note.txt")
```

Directory browsing, previews, native launch, and incremental logs use the same
structured vocabulary:

```lisp
(resolve-file-directory "folder" :path "/tmp" :entries
  ((file "/tmp/readme.txt" 123) (directory "/tmp/project" 0)
   (symbolic-link "/tmp/latest" 12) (other "/tmp/socket" 0)))
(resolve-file-preview "preview" :path "/tmp/readme.txt" :text "First page" :truncated true)
(resolve-file-open "launch" :path "/tmp/readme.txt")
(resolve-file-log "tail" :path "/tmp/app.log" :text "Ready\n"
  :device 7 :inode 13 :offset 6 :change initial :state at-end)
```

Log changes are `initial`, `continued`, `rotated`, or `truncated`; states are
`more`, `at-end`, or `partial-utf8`. Cursor numbers and directory file sizes are
canonical unsigned decimal U64 values, including values above signed I64's
maximum. Signs, leading zeros, quoted numbers, and overflow are refused. Preview
and log text are bounded to 64 KiB. Direct directory fixtures accept up to
10,000 entries and four MiB of combined root/entry path bytes. Directory fixtures
settle `list_directory` tasks, not recursive scans; preview, log, and launch
fixtures each require their corresponding declared service.

Fields may appear in any order; each documented field is required exactly once. Choice tags
are `chosen` and `canceled`. Error kinds are `canceled`, `not-found`,
`permission-denied`, `invalid-utf8`, `invalid-path`, `resource-limit`, `io`, and
`unavailable`; canceled errors require empty detail. Paths must be valid UTF-8,
at most 4096 bytes, and absolute in one of the spellings a native worker returns:
POSIX-rooted (`/tmp/note.txt`), drive-rooted (`C:\Users\Lee` or `C:/Users/Lee`),
or a UNC prefix (`\\server\share\docs`). A typed fixture can therefore express a
Windows result directly instead of hand-writing a raw task frame. Read text and write byte counts have the
native one-MiB bound, and error detail is bounded to 4096 UTF-8 bytes. Unknown
fields, duplicate fields, invalid types, and oversized values reject the spec.

A fixture checks the pending task's declared service before calling its Roc
result decoder. Read fixtures cannot settle write tasks; choice fixtures accept
file, directory, and save choosers; error fixtures accept native Files tasks.
A mismatch reports the source line, task label, expected service, and actual
service or missing request. A task label locates a request for the harness; it
does not determine service semantics. Settlements still use ordinary engine
propagation and task ownership.

These commands simulate results and perform no filesystem IO. They establish
application response, cancellation, and state behavior; real filesystem and
native chooser behavior need host tests and a native walkthrough. Keep raw
`resolve-task`, `reject-task`, and `resolve-stale-task` when deliberately testing
malformed payloads or stale delivery. The Board and Notes journeys demonstrate
save snapshots, failed loads, cancellation, retries, and retained drafts.

A supplied result does not assert the request payload the app emitted. For
example, resolving a write with `:bytes 14` does not prove that the app submitted
those fourteen bytes. Test snapshot construction as pure application logic and
check real submitted data through focused native IO workflows. The harness
currently exposes pending/canceled counts, not request-body assertions.

Supported async and lifecycle commands:

- `(resolve-task "<task-name>" "<payload>")`
- `(resolve-stale-task "<task-name>" "<payload>")`
- `(reject-task "<task-name>" "<payload>")`
- `(tick-interval <period-ms>)`, `(tick-interval-if-active <period-ms>)`
- `(request-window-close)`, `(expect-window-closed true|false)` (native GUI lifecycle)
- `(expect-pending-task "<task-name>" <count>)`
- `(expect-canceled-task "<task-name>" <count>)`
- `(expect-interval <period-ms> <count>)`
- `(expect-cleanup "<cleanup-name>" <count>)`

A window-close assertion records the committed close decision. The harness
keeps the final semantic tree available for inspection; it does not simulate
an OS window or automatically reject subsequent interactions with that tree.
End the interaction journey at closure and use GPUI lifecycle tests to verify
native removal and teardown.

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

Common metric names include `dirty_source_roots`, `rows_reused`,
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
.test-out/bench-bin/signals-data-grid-bench --host-bench-app --host-bench-name signals-data-grid --host-bench-iterations 100 --host-bench-samples 3 examples-web/data-grid/specs/initial-mount.scm
```

The host initializes a fresh app per iteration, applies the initial command
batch, then replays commands classified as benchmark actions in
`src/bench/benchmark.zig` (user actions, task results, and interval ticks).
Expectation and metric assertion commands remain the semantic correctness suite
used by `python3 scripts/test.py native`.

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
import pf.Elem exposing [Elem]
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

## Native GUI platform spike

`platform-shared/` owns common signal, scope, descriptor, ownership, and render
construction modules. `scripts/prepare_platforms.py` copies its Roc files into
`platform-web/` and `platform-gui/`. These flat generated copies are individually
gitignored. The fixed repository layout needs no per-platform source configuration.

Run `python3 scripts/prepare_platforms.py --check` or
`zig build run-check-platform-sources` to compare SHA-256 hashes without changing
any files. Missing, modified, and stale shared-module entries fail the check.
The check runs with `zig build test`, and CI exercises deliberate drift detection.
Refresh copies after editing canonical sources with
`python3 scripts/prepare_platforms.py`. Bundle staging always reads the canonical
shared sources, even when local generated copies are stale.

The flat layout is intentional: nested `shared/` imports and hosted declarations
currently fail with the pinned compiler, including when compiled from bundles.
See `UPSTREAM_COMPILER_BUGS.md` for the observed limitations.

The GUI targets are Apple Silicon macOS, Linux x86_64 with glibc and a
Wayland/GPU session, and Windows x86_64. Host development needs Rust (tested
with 1.95.0 on macOS, Linux, and Windows CI) and Zig 0.16. Linux also
needs a C toolchain for Rust dependencies with native code,
xkbcommon development packages, and the xkbcommon-X11 runtime. FreeType is
an independently verified release input. The Linux Cargo `links` override in
`.cargo/config.toml` supplies `dylib=freetype` and suppresses freetype-sys
`build.rs` entirely, so missing pkg-config cannot trigger its bundled C build.
Roc links the released FreeType input separately; host release evidence rejects
any executed or compiled freetype-sys build script. Changing that crate version
requires reviewing the override. macOS needs Xcode
with its Metal compiler component (`xcodebuild -downloadComponent MetalToolchain`).
If Xcode reports mismatched support frameworks, complete
`xcodebuild -runFirstLaunch` first. Windows uses Rust's MSVC compiler host with
its `x86_64-pc-windows-gnullvm` target (`rustup target add --toolchain 1.95.0
x86_64-pc-windows-gnullvm`). The shared Windows builder pins Zig 0.16.0 and the
Microsoft-signed FXC/compiler DLL pair from SDK 10.0.26100.0, file version
10.0.26100.8249. It checks the actual loaded compiler DLL and committed hashes;
ambient `GPUI_FXC_PATH` cannot override release shader tooling. Optimized builds
compile GPUI shaders before packaging; development builds compile them at runtime.

Windows host builds verify and reuse both independently signed dependencies in
`dependencies.lock.json`: complete per-DLL import archives and GNU CRT inputs.
Authenticated GitHub CLI access is required. There is no local native dependency
build fallback. The host and engine use the GNU ABI, and the host build produces
its own application manifest resource. Structural COFF validation separates only
import records and exact linker helpers from the raw Rust archive, preserving
every implementation member byte-for-byte and in order. The transformation
receipt binds raw Cargo output to the final archive; engine/resource bytes remain
unchanged. Complete original notices are bundled and the validated source
companion remains a separate release asset.

Roc's final Windows link explicitly selects `--target=x64mingw` and uses all
released inputs from the platform header. For a direct Windows build, run
`roc build --target=x64mingw examples-gui/counter/main.roc --output=Counter.exe`. It does not discover installed MSVC/SDK
libraries. FXC remains a build-time SDK tool. Use `python` instead of `python3`
in the commands below on Windows, where `python3` can be a Store shortcut.
`build.zig` prefers `python` there. The workspace pins GPUI 0.2.2.

The separate `Windows GNU host candidate` workflow can inventory shader tooling
or test identified CI artifacts before release. It uses the same native builder
and structural transformer as production. Its full app gate admits original
notices and paired sources, then runs all six builds/specs/render checks natively
and through a fresh HTTP bundle cache. Candidate artifacts do not substitute for
signed production dependency admission.

Other native targets, including Intel macOS and Windows on Arm, are not
implemented.
The GUI builder selects `TOOLCHAINS=Metal` on macOS unless explicitly overridden;
use the same setting for direct `cargo test` commands if Xcode's default lookup
still reports the installed Metal component as missing.

The GUI platform header lists the Rust host and Zig engine as separate link
inputs: `libsignals_gpui_host.a` and `libengine.a` on all supported native targets. Roc links these with the
application object and the other declared inputs to produce the executable.
The builder does not merge them into a combined host archive. Rebuild older
prebuilt target directories before using them with this header.

Cargo tracks the checkout identity supplied by `.cargo/config.toml` through the
host's `build.rs`. This prevents stale host reuse when multiple checkouts share
`CARGO_TARGET_DIR`, without cleaning the host on every build. Run direct Cargo
commands from the workspace or crate directory so Cargo discovers that config.

```sh
python3 scripts/build_gui.py --debug
roc build examples-gui/counter/main.roc --output=.test-out/Counter
.test-out/Counter
# Same executable, display-free semantic check:
.test-out/Counter --host-run-spec-json examples-gui/counter/specs/counting.scm
# Brief rendering/adapter integration check:
.test-out/Counter --host-smoke --host-smoke-click Increment --host-smoke-expect '1'
```

`python3 scripts/test.py gui --roc-bin /path/to/pinned/roc --keep-output`
checks the compiler identity, prepares shared sources, builds the development
GUI host, runs focused GPUI adapter/editor tests, then `roc check` and `roc test` for each registered GUI app and internal fixture under `test/gui/`,
builds fresh executables, and runs their native semantic specs without a display.
The manifest at `examples-gui/examples.toml` must list every app directory, and
each app must have specs. Every GUI check must pass; this suite has no known-failure
allowlist. `--spec-filter`, `--shard`, `--jobs`, and `--fail-fast` also apply.
The default `all` suite includes GUI checks on Linux x86_64; run `gui` explicitly
on macOS, where it requires full Xcode and the Metal toolchain. CI runs them in a
dedicated Linux, Windows, and macOS jobs. GUI executables remain under `.test-out/gui`
when output is kept. Linux CI then runs `xvfb-run -a python3 scripts/gui_smoke.py --wayland`
with Weston and Mesa's software Vulkan driver. Weston runs on Xvfb so GPUI
receives a Wayland input seat as well as a virtual display; Weston's headless
backend provides no seat and GPUI 0.2.2 requires one.
It opens every maintained example, requires
the host's explicit rendering result, checks the counter's increment action,
and fails on a crash or a 30-second timeout. This checks the GPUI window/rendering
path separately from the display-free specs. Run the same script on a desktop
after the GUI suite to exercise the local graphics driver.

## Scripted GUI regression scenarios

`gui_smoke.py` answers one question: did the application mount and render. That
is not enough to catch a control laid out beyond the window or a native editor
that kept the previous document's undo history — both of which the maintained
semantic specs also cannot see, because they run without a presentation layer.

`python3 scripts/gui_regression.py --directory .test-out/gui` runs the scenarios
stored beside each example in `examples-gui/<app>/regression/*.script`, covering
initial, populated, selected, focused, disabled/read-only, modal, error/loading
and resized states. Each scenario is a line-per-step script executed against the
real window by the host's `--host-script` flag:

```text
# size: 800x600
click #edit-task-4
wait 400
expect-selected #task-4
expect-value "Task title" Polish the project sidebar
expect-history "Task notes" 0
expect-onscreen #task-detail
snapshot task-4-selected
```

Controls are named by the application's own `Gui.test_id` or by the label a
person reads — never by pixel coordinates, so the scenarios survive layout work.
Besides the ordinary state assertions, two observations exist only here:
`expect-history` reads how many native undo entries an editor is holding, which
is how document ownership becomes testable, and `expect-onscreen` reads a
control's laid-out bounds. `expect-onscreen` means *visible without scrolling*;
the host's window-scroll fallback means a failure is a usability finding rather
than a proof that nothing can reach the control.

A native file or folder dialog cannot be driven from a script. A scenario that
needs a real file names it in its front matter, `# choose: <path relative to
the example>`, once per chooser in the order the script opens them; the driver
passes each as `--host-choose` and the host hands it to the next chooser instead
of prompting, after the same path validation the dialog's own answer receives.
Everything past the chooser — the listing, preview, log-follow or open worker —
is the real one, which is what separates these scenarios from the specs that
resolve the worker's result by name. The `close` step, which must be last,
leaves through the window's own close request the way the frame's close button
does: an application with unsaved work may answer with a dialog and keep the
window. The report is written before the window goes, so the driver also reads
the process exit status; a crash during teardown is reported as the failure
even when every assertion passed. `activity-monitor/follow-and-close` and
`folder-explorer/real-folder-preview` are the scenarios built on this.

Every run writes a JSON report of every observation under
`.test-out/gui-regression/<app>/`, and on macOS also photographs the
application's own window in the state the script finished in — including the
state a failing assertion stopped at. Captures go through `gui_capture.py`, so
they find the window by the process id the driver started and refuse a window
whose size does not match the request; no region of your desktop is captured.
Pass `--no-capture` to run the scripts alone, `--scenario SUBSTRING` to select
some of them, and `--artifacts PATH` to write elsewhere.

The scenarios themselves are platform-neutral, because the interpreter lives in
the host rather than in the driver: the same checks run on every system the GUI
supports. Only the captures are macOS-only, and the driver says which half it
ran rather than reporting a pass for evidence it never gathered. On Linux the
scenarios need the same private display as the smoke checks, which
`python3 scripts/minici gui-scenarios` arranges — under Weston on an Xvfb
display there, and directly on macOS and Windows. CI runs that target after
`gui-smoke` and keeps the JSON reports when it fails.

A scenario runs against its example's own `assets/` directory. A script whose
front matter carries `# assets: <path relative to the example>` runs against a
prepared root instead, which is how the asset scenarios show a missing, altered
or unreadable file without a script damaging the working tree; the named
directory must exist. See `examples-gui/task-board/regression/assets-problem/`,
whose `generate.py` derives that root from the shipped assets.

A script whose front matter carries `# diagnostic:` documents a defect owned
elsewhere. It runs and its failure is reported, but it does not fail the run —
and a diagnostic that starts passing *does* fail the run, so a fix cannot leave
a stale exclusion behind. Never weaken an assertion to make a scenario pass;
state the reason in the script and let it run as a diagnostic instead.

Window captures are implemented for macOS only. On Linux the driver runs the
scripts without captures; the scripts themselves, including `expect-onscreen`,
work anywhere the examples run, but this repository has only executed them on
Apple Silicon macOS so far.

Normal GUI launches do not print engine metrics. Pass `--host-trace-engine` to an
app executable to log event-turn metrics to stderr; `--host-smoke` prints its explicit
validation result, and `--host-script` prints its own pass or failure line. Host
errors remain visible without tracing.

Host builds default to two Cargo workers. Use `scripts/build_gui.py --jobs N`
or `scripts/test.py gui --gui-build-jobs N` to adjust memory pressure. Parallel
app work should serialize substantial host builds. Cargo reuses valid cached
artifacts without an unconditional host clean. Rebuilding and optimizing the
Rust host uses ThinLTO across its Rust dependency graph to keep the archive
within Roc’s package-size budget. External native link libraries
have independent release cycles and are fetched from their verified locks.
GUI specs validate shared
semantics; the separate window smoke above checks rendering and adapter dispatch,
and does not establish OS keyboard, pointer, or IME behavior. GPUI adapter tests
exercise simulated input and layout; they also do not replace a native desktop walkthrough.

After `scripts/bundle.sh --package gui --serve`, download `http://127.0.0.1:8000/Counter.roc`
and run `roc build Counter.roc`. Alternatively, `roc run Counter.roc --opt=speed`
compiles and opens the window directly. Plain `roc run` currently encounters the
required-`main` shim collision documented in `UPSTREAM_COMPILER_BUGS.md`, case 12. The app author needs the pinned Roc compiler
and the target operating system (plus runtime GUI libraries on Linux).
Rust and Zig are used when preparing the platform bundle. Windows application
linking still needs Roc's implicit MSVC/SDK inputs. On macOS, the package embeds compiled Metal shaders
and generates the required framework/library link stubs from the reviewed
interface catalog into
`targets/macos-sysroot`; building a bundled app does not need Xcode. The
final application link takes place on the user's machine during `roc build`
or the compilation step of `roc run`. The `.tbd` files supply interface metadata;
macOS supplies the actual framework implementations at runtime. Running an
already-built executable does not require an Apple SDK. The macOS
build is validated on macOS 26.3; older versions are not yet validated.
This produces a native executable, not a desktop
installer. Linux bundles now include independently built glibc 2.39 link stubs,
startup objects and complete corresponding source/license inventories. The Rust
host still depends on its build environment's glibc ABI; the pinned link inputs
do not establish compatibility with older Linux distributions.

The `GUI host link inputs` workflow (`gui-hosts.yml`) builds native candidates
and runs all GUI application specs with the pinned Roc compiler against their
extracted archives. Candidate tests populate empty target directories from the
independently verified Linux or Windows releases; development target copies are
not admitted as dependency evidence. All native producers capture the actual Cargo build
stream, filtered metadata, and unchanged lock with `build_gui.py --cargo-evidence`.
The notice composer selects the conservative set of compiled packages, retains
original notices and source declarations, and supplies pinned canonical SPDX
terms under an explicit expression policy. These reference terms are labeled
separately from upstream notices; template copyright placeholders are not
attributed to crates. Unknown expressions and incomplete evidence are rejected.

Mac `--cargo-evidence` builds use a fresh Cargo target beneath the evidence output's
parent directory so cached shaders cannot be attributed to different tools.
That scratch target is removed when the build process exits, after the host
archive has been copied into the platform target directory. The existing host build receipt records the selected Metal/metallib executable
hashes and version diagnostics, Xcode/SDK identities, and GPUI shader/header/AIR/
metallib hashes bound to the resulting host. Ordinary development builds retain
normal Cargo caching. The Mac source companion retains this evidence with the
exact selected crate sources and compiler notices. No Apple SDK or tool binaries
are added to the receipt. The original
objc2 SDK-derived qualification remains preserved as an upstream declaration,
not treated as an inferred distribution prohibition.

Each eligible candidate comprises `gui-host-<target>.tar` plus
`gui-host-sources-<target>.tar`. The host contains a hash-indexed compressed notice
archive; the companion retains exact locked crate sources, Zig sources, and
Cargo evidence. Rust distribution notices include its standard-library copyright
report. The host manifest binds the companion digest, and both exact tested
artifacts receive build attestations and appear in the release lock. Source
companions remain accessible through that lock without occupying the Roc platform
bundle or being downloaded for each app build. Preserve the notice archive and
linked source access when redistributing the bundle.

A main-branch manual dispatch selects Linux, Windows, macOS, Linux and Windows,
or all three targets
for an independent `deps-gui-host-<version>` release. Mac admission requires the
complete source/notice pair and native final links/specs against the independently
released project-authored interfaces; copied SDK stubs are not release inputs. The original
objc2 qualification is retained alongside its declared license terms. Missing
standalone license files alone are not a blanket
publication prohibition: original source evidence and declarations remain visible
in the package inventory and reviewed expression policy.

Set `HOST_RELEASE` to the actual published tag, verify its lock asset, and pass
the reviewed lock directly to the bundler:

```sh
gh release download "$HOST_RELEASE" --pattern dependencies.lock.json --dir /tmp/hosts
scripts/bundle.sh --package gui --no-build --prebuilt-host-lock /tmp/hosts/dependencies.lock.json
```

The bundler downloads and verifies every selected archive, including cached
copies, against the reviewed size and SHA-256. The lock also records its producer
repository, source commit, main ref, and workflow for optional provenance
inspection. It extracts into private staging and checks whether the actual Rust
host, Zig engine, Cargo manifest, lock, or build configuration changed since the
host release. Platform Roc APIs, applications, semantic specs, documentation,
packaging, and external linker inputs do not invalidate a compatible host.
Host-related source must be clean and committed. Overlapping local and prebuilt
hosts for one target are errors.

The GUI test driver accepts the same reviewed lock through
`python3 scripts/test.py gui --gui-host-lock /path/to/dependencies.lock.json` or
`GUI_HOST_LOCK`. It downloads only the host for the current operating system,
stages that target's independently released system link inputs, and runs the
ordinary Roc checks, builds, and semantic specs without rebuilding Cargo or Zig
host code. Cargo host tests and fresh host-output construction remain part of the
dedicated producer workflow when actual host inputs or producer machinery change.

A reviewed host release can only be published from `main`, so a branch that
changes the host sources has no matching release yet. When the lock does not
describe the checkout's host inputs, the driver says so and builds and tests the
host from source for that run instead of refusing to start — otherwise a host
change could never reach `main` to be released from. Asking for the verified
host itself still refuses a mismatched lock: the fallback is the test driver's
decision, never something a release or a bundle can inherit. The macOS bundle
step is skipped in that case for the same reason — there is no released archive
for it to validate.

Because that job may build the host, its runner needs the host's build inputs:
the FreeType and xkbcommon development packages on Linux, and the
`x86_64-pc-windows-gnullvm` Rust target on Windows. Generating the macOS
interface catalog remains outside ordinary CI; that has its own producer and
review.

These archives contain host code and licenses, not external system libraries or
SDK stubs. Every included target must also have its external link inputs supplied;
the bundler rejects incomplete targets. Windows ADVAPI32 imports and all declared
Linux external link inputs are fetched through their independent verified locks.
Completing Windows CRT/import separation and macOS SDK stub admission remains
separate work. Raw prebuilt directories are no longer accepted.

The bundle output also contains every registered GUI app under `examples-gui/`,
including its supporting Roc modules and semantic specs. Those generated app
headers refer to the served bundle URL. With the server still running, build an
app directly from the output directory:

```sh
roc build .test-out/bundles/examples-gui/notes-editor/main.roc --output=.test-out/Notes
.test-out/Notes
```

`Gui` offers typed rows, columns, panels, native styles, headings/text, enabled
buttons, labeled inputs, and checkboxes. See the native presentation protocol in
`docs/native-gui-protocol.md` for field compatibility and limits. Signals, keyed
rows, scopes, and ownership remain in the shared engine.
Wide collections use `Gui.virtual_list` to bound child lookup and layout to the
visible range; ordinary containers enumerate direct children when rendered.
See [Native GUI](@/docs/native-gui.md) for controls and keyboard regions, and
`crates/gpui-host/README.md` for the boundary limits.

### Combined platform release candidates

The single release workflow publishes the web and GUI platforms together without
conflating their APIs. Web applications and GUI applications remain separate app
roots and may share ordinary Roc modules, but each header names its own platform
archive. The GUI archive is deliberately fat: it contains the admitted
`x64glibc`, `arm64mac`, and `x64mingw` hosts and their target-confined linker inputs.
The web archive contains its native spec hosts and Wasm browser host.

Packaging changes do not rebuild either host. `web-host.lock.json` and
`gui-host.lock.json` select immutable host releases whose narrow source
fingerprints must match the checkout; packaging and publication refuse a lock
that does not, and only the GUI test driver falls back to a source build. `dependencies.lock.json` independently
selects the external linker inputs, including the catalog-derived macOS TBDs.
Ordinary admission uses the recorded byte counts and SHA-256 hashes without an
attestation service. The publishing job additionally attests the exact two bundles,
example archive, and release manifest for users who want external provenance.

Mac admission final-links maintained applications against the reviewed TBD catalog;
Windows retains the complete GNU runtime and system import order; Linux retains
the reviewed glibc, FreeType, xkbcommon, and unwinder inputs. Missing final-link
symbols are feedback to the relevant external linker-input catalog and do not make
those interfaces host-build dependencies.

### Validate generated macOS bundles

Creating a bundle from the reviewed locks is platform-independent. Native Apple
Silicon validation happens after bundling: the macOS runner downloads the same
candidate as the other smoke runners, serves it over HTTP with an empty Roc
cache, final-links every maintained GUI example against the selected released
host archives and interface inputs, and runs its native specs. It does not
install Rust, build Cargo, build the Zig engine, download the Metal toolchain,
or regenerate TBDs:

```sh
GUI_HOST_LOCK=gui-host.lock.json python3 scripts/minici gui
python3 scripts/bundle_platforms.py --package gui --no-build --output-dir /tmp/macos-bundle
python3 scripts/check_macos_interfaces.py --bundle /tmp/macos-bundle
```

These are candidate checks. Mac host and interface production remain separate
release cycles; ordinary consumers use their reviewed content hashes.
