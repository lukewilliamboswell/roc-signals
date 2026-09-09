# macOS dependency baseline

This working branch starts at dependency integration commit
`1ec76e738badb3abde416da5740eb787ee379f5e`. Its macOS GUI CI passed:
https://github.com/lukewilliamboswell/roc-signals/actions/runs/34330474386/job/102398068611
This is a development baseline, not a redistributable Mac release candidate.
Remove this handoff document before merging the work; put lasting workflow changes
in `www/content/docs/contributing.md` and decisions in the PR.

## Get started

Use an Apple Silicon Mac (`uname -m` must report `arm64`). Intel Mac GUI targets
are not implemented. Install Python 3, GitHub CLI, Rustup, Zig **0.16.0**, and full
Xcode **26.3** with Metal. CI uses Rust **1.95.0**. Node/Zola/Tailwind are not needed
for the focused GUI checks below. Commands run from the repository root.

```sh
git fetch origin
git switch --track origin/macos-dependency-baseline
rustup toolchain install 1.95.0 --profile minimal
export RUSTUP_TOOLCHAIN=1.95.0
# Adjust this to your actual Xcode installation:
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
export TOOLCHAINS=Metal
xcodebuild -version
xcodebuild -downloadComponent MetalToolchain
xcrun --find metal
zig version
```

If Xcode reports mismatched support frameworks, complete
`xcodebuild -runFirstLaunch` before retrying. Use your installed Xcode path;
do not assume CI's versioned application name exists locally.

Download the exact pinned Roc outside the checkout:

```sh
mkdir -p ../signals-mac-tools
gh release download nightly-2026-09-04-c125b82 --repo roc-lang/nightlies \
  --pattern roc_nightly-macos_apple_silicon-2026-09-04-c125b82.tar.gz \
  --dir ../signals-mac-tools
tar -xzf ../signals-mac-tools/roc_nightly-macos_apple_silicon-2026-09-04-c125b82.tar.gz \
  -C ../signals-mac-tools
```

Add the extracted directory containing `roc` to PATH, then verify the pin:

```sh
python3 scripts/toolchain.py --check --roc-bin roc
python3 scripts/test.py gui --keep-output
python3 scripts/gui_smoke.py
```

The GUI suite builds all six registered examples and runs display-free native
specs. The smoke command needs a logged-in desktop and opens the examples,
checks rendering, and exercises the counter increment. Also manually check
keyboard focus, text editing, scrolling, resizing, and IME as applicable.
These instructions were checked against source and passing CI; the Linux author
has not run them on a physical Mac.

## Optimized build and actual package consumption

```sh
python3 scripts/prepare_platforms.py
python3 scripts/build_gui.py
ROC_BIN="$(command -v roc)" python3 scripts/bundle_platforms.py \
  --package gui --no-build --output-dir .test-out/mac-bundle --serve
```

Keep that local server running. In another terminal with the same pinned Roc:

```sh
mkdir -p .test-out/mac-consumer
curl --fail http://127.0.0.1:8000/Counter.roc -o .test-out/mac-consumer/Counter.roc
roc build .test-out/mac-consumer/Counter.roc --output=.test-out/mac-consumer/Counter
.test-out/mac-consumer/Counter --run-spec-json examples-gui/counter/specs/counting.scm
.test-out/mac-consumer/Counter --smoke --smoke-click Increment --smoke-expect 'Count: 1'
```

Local source linking and successful archive creation do not prove URL consumption.
Pinned Roc enforces a **100 MiB expanded transitive package budget**. Record any
size rejection; the diagnostic's suggested `--max-transitive-bytes` override is
not implemented in this compiler. Host optimization/size work is happening on a
separate branch. Do not change compiler pins to hide a packaging failure.

## Dependency work

Read `AGENTS.md` and `design.md` before changing host boundaries. Start with:

- `scripts/build_gui.py`: `MACOS_FRAMEWORKS`, `copy_macos_sysroot`, Darwin build branch.
- `platform-gui/main.roc`: separate Rust host and Zig engine link inputs.
- `scripts/bundle_platforms.py`: target/sysroot staging.
- `dependencies.lock.json`, `scripts/prepare_dependencies.py`, and the native
  dependency workflows: existing independently released, attested dependency pattern.
- `.github/workflows/ci.yml`: `gui-macos`; `.github/workflows/gui-hosts.yml`:
  existing host producer, with further release/notices work on a separate branch.

The current builder copies 16 framework TBD roots, `libSystem.tbd`, `libobjc.tbd`,
`libc++.tbd`, and their external reexports from the selected Xcode SDK into
`platform-gui/targets/macos-sysroot`. It dereferences symlinks and expects TBD v4.
It records SDK version/build, but lacks an independent pinned dependency package,
complete hashed inventory, redistribution evidence, and verified release reuse.
Ordinary host builds repeat this collection.

First capture the working local baseline: OS/CPU, Xcode and SDK version/build,
Rust/Zig/Roc versions, tests, package expanded size, copied TBD paths/hashes,
install names, reexports, and the final executable's dynamic dependencies
(`otool -L`). Keep generated binaries and SDK files untracked.

Then establish the source and redistribution basis for the framework/link stubs.
Being text stubs does not itself establish redistribution permission. Do not
publish copied Apple SDK files as a dependency release without resolving that
question. A local Xcode prerequisite is an alternative product decision still
open for discussion; do not silently adopt it as the finished bundle contract.

The intended result is an independently versioned, complete dependency inventory
with source pins, original notices, reproducible construction, signing and build
attestation. Consumers verify the exact release before staging. Ordinary host
changes reuse that release, without rebuilding external libraries or collecting
SDK files again. Rebuilding and optimizing the Rust host itself is acceptable;
there is no requirement to avoid cross-crate host optimization. Keep the engine
and host separate: Roc performs the final executable link.

Validate missing/tampered inputs and reexport closure, then build URL-bound apps
in a clean consumer environment without SDK discovery for any claimed
self-contained release. Run semantic specs and desktop smoke tests on the actual
result. Record the minimum supported macOS version rather than inferring it from
the SDK version. Coordinate shared producer/notice script changes with the
ongoing Linux work; Mac-specific changes can proceed on this branch.
