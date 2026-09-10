# Upstream compiler bugs

Roc compiler and builtin bugs this repo has hit, with the workaround each one
forced on us. Every entry names the workaround site so the code can be
un-worked-around once the upstream fix lands.

Toolchain: the nightly pinned in the `roc` header in `platform-web/main.roc`, which is what CI installs.
Individual entries record the versions on which they were reproduced; older
entries are historical evidence, not claims that every bug persists on the pin.
`scripts/dev/check-example.sh` and `scripts/test.py` both read `ROC_BIN`, so
point it at the pinned toolchain when reproducing:

```sh
export ROC_BIN=/path/to/pinned-roc/roc
```

| # | Bug | Upstream | Repro | Worked around |
|---|-----|----------|-------|---------------|
| 1 | `Json.parser_camel()` corrupts long field names on wasm32 | [#10957](https://github.com/roc-lang/roc/issues/10957) | `repro/json-camel-long-field-name/` | yes |
| 2 | flight-search double-frees its task payload on wasm32 | [#10958](https://github.com/roc-lang/roc/issues/10958) | — | yes |
| 3 | markdown-editor traps with `unreachable` in the browser | [#10959](https://github.com/roc-lang/roc/issues/10959) | — | yes |
| 11 | Native GPUI sample cannot link as Shared or PIE | not filed | `examples-gui/keyed-rows/` | normal Roc executable linkage |
| 10 | Unit-state capability callbacks produce invalid dev Wasm | not filed | `repro/unit-state-wasm-dev/` | no; size backend validates |
| 14 | `roc bundle --output-dir` fails across filesystems | not filed | commands below | stage on the output filesystem |
| 16 | `Ui.each` applications fail during monotype code generation | [#11265](https://github.com/roc-lang/roc/issues/11265) | `repro/recursive-each-codegen/` | no |
| 17 | Markdown Editor retains Roc allocations after native specs | [#11269](https://github.com/roc-lang/roc/issues/11269) | commands below | no |

For #1, camelCase field names longer than ten bytes are corrupted on wasm32 at
byte four, while native is unaffected; `favoritesCount` exposed it. For #2, the
first flight-search task result double-frees its exact-length string payload on
wasm32 while native passes. For #3, markdown-editor traps during wasm32 mount
while all native specs pass. Their linked upstream issues carry the reductions
and current status.

## 10. Unit-state capability callbacks produce invalid dev Wasm

Reproduced on `nightly-2026-09-04-c125b82`: a `Ui.state({}, ...)` app
compiles successfully with `--opt=dev`, but Node and Chromium reject the
artifact with `expected 0 elements on the stack for fallthru, found 2`.
Boolean state without an event handler and a string input validate; adding a
unit event handler also reproduces the failure. The size backend validates
the same unit-state app. The exact compiler cause remains unisolated.

See `repro/unit-state-wasm-dev/README.md` for commands and controls. Site builds
now validate the generated Wasm instead of treating compiler exit status as
proof of a usable artifact. No platform semantic workaround has been applied.

## 11. Native sample requires archive linkage and a non-PIE executable

Reproduced with `nightly-2026-09-04-c125b82`, `--target=x64glibc`,
`--opt=speed`, and the GPUI spike's Roc application. `output: Shared` fails
in `ld.lld`: `R_X86_64_64 cannot be used against symbol roc__static_const_0;
recompile with -fPIC`, originating in `roc_static_data_x64glibc.o`.
`output: Archive` builds, but linking that archive into Cargo's default PIE
executable fails with `R_X86_64_32S` / `R_X86_64_32` relocations from the Roc
LLVM object. This is a linked-app reproduction, not a minimized compiler case.

The current GUI package uses normal Roc executable linkage and needs neither
an application archive nor a Cargo `-no-pie` override. Shared output remains a
separate compiler limitation. To reproduce after preparing the GUI package,
copy `platform-gui` and `examples-gui/keyed-rows/main.roc` into a scratch directory,
point the app at that copied platform, and replace the copied `x64glibc` target
with `{ inputs: [app], output: Shared }`. Run the pinned compiler with
`roc build main.roc --target=x64glibc --opt=speed`. This isolates Roc's Shared
relocations from GPUI and the engine. No source-value layout workaround is used.

## Not compiler bugs — missing builtins

These cost time this session because they look like they should exist. They are
API gaps, not defects; recorded so nobody re-derives them.

| Expected | Reality |
|---|---|
| `Try.unwrap_or` / `Try.with_default` | Absent. Use **`Try.ok_or(try, fallback)`** (call position; `Try` exposes `map_ok`/`map_err` as methods). |
| `Try.and_then` / `Try.or_else` | Absent. `Try.on_err` covers the error-side case; otherwise `match` or `?`. |
| `List.reverse` | Absent. Build the list in the wanted order, or `fold` + `concat`. |
| `U64.max_value` / a max constant | Absent. `U64.max : U64, U64 -> U64` is a two-argument "greater of". Model "no limit" as a tag instead of a sentinel literal. |
| `_` in a type alias declaration | Rejected ("Underscores are not allowed in type alias declarations"). Use an inline record annotation at the signature instead. |
| calling a function held in a record field | `rec.f(x)` parses as a *method* lookup on `rec` and fails. Parenthesise the field: `(rec.f)(x)`. |
| `Str` ordering | There is no `Str.compare` / `compare_to` / `order` in this build, and `Str` has no `compare` method. Comparing strings for sort order means hand-rolling a byte comparison. |

Present and used, for contrast: `U64.compare`, `U64.from_str`, `Str.contains`,
`List.find_first`, `List.keep_if`, `List.map2`, `List.all`, `List.any`,
`List.contains`, `List.join_map`, `Try.ok_or`, `Try.map_ok`, `Try.map_err`,
`Try.is_ok`, and the `?` operator.

## 12. Default run exports a required `main` in addition to the host entry

With `nightly-2026-09-04-c125b82`, a platform requiring `main : () -> I64`
and providing only `"roc_ui_init": ui_init` triggers a duplicate `main` when
running through the default interpreter shim. A C `libhost.a` defining C `main`
and the six runtime callbacks from `src/builtins/host_abi.zig` reproduces it
without Signals, GPUI, hosted functions, or retained values. See
`repro/required-main-host-collision/README.md` for reproduction commands.

`lir/checked_pipeline.zig` includes `.platform_required` roots in
`platformEntrypoints` and `platformEntrypointNames`; the generated shim exports
both `roc_ui_init` and `main`. The latter conflicts with the C process entry.
Normal `roc build` and `roc run --opt=speed` work with the GUI host. Do not
weaken the host's `main`, allow duplicate definitions, or rename the application
entry silently: those would conceal the boundary problem.

## 13. Re-exporting a shared module through a relative package dependency

With `nightly-2026-09-04-c125b82`, moving `Elem` and its dependencies into a
package, adding `shared: "../platform-shared/main.roc"` to the platform, and
exposing a local facade `import shared.Elem as SharedElem; Elem : SharedElem`
causes `roc check` to panic with `typed_cir invariant violated: duplicate module
name .../platform-gui/main.roc.Elem`. This was observed while checking Counter;
it is not yet a minimized upstream regression. Both importing the shared type
in the platform entry and importing the facade there reproduced the panic.

The build instead assembles both packages from one shared source directory.
The original build-time assembly introduced no Roc alias, altered value layout,
or semantic fallback. The later nested `shared/` layout also encounters hosted
declaration lookup and re-export failures and is not yet validated. Revisit direct package
re-exports after the compiler supports this source layout.

## 14. Bundle output on another filesystem fails with CrossDevice

With `nightly-2026-09-04-c125b82`, `roc bundle` creates its temporary archive
under the current directory and renames it into `--output-dir`. When those
directories are on different filesystems, it fails with `CrossDevice` instead
of completing the bundle. Windows CI reproduced this with Python's temporary
directory on C: and the requested output under `RUNNER_TEMP` on D:.

To reproduce, create a directory on each of two filesystems, put `README.md`
in the first, then run `roc bundle README.md --output-dir <second-directory>`
from the first. No platform host or Roc application is needed. On Linux,
`/dev/shm` and `/tmp` can provide the two filesystems when they have different
device IDs.

`scripts/bundle_platforms.py` stages inputs in a private temporary directory
inside the requested output directory. The compiler's final rename then stays
on one filesystem; this does not rebuild, rewrite, or replace a tested archive.

## 15. Package size diagnostic suggests an unavailable override

With `nightly-2026-09-04-c125b82`, fetching a platform package that expands above
104857600 bytes fails with `dependency tree too large`. The diagnostic suggests
`--max-transitive-bytes`, but the pinned CLI does not implement that option.
It appears only in the diagnostic text in `src/compile/package_resolution.zig`.

Reproduce by preparing a Linux GUI release host, running
`scripts/bundle.sh --package gui --no-build --serve --port 8000`, and compiling
the generated URL-bound `Counter.roc` with the pinned compiler. The observed
host archive alone was 151741542 bytes; its complete GUI package expanded to
191834541 bytes. Adding `--max-transitive-bytes=536870912` to `roc build` is
rejected rather than raising the budget. This is a linked-platform reproduction,
not a minimized compiler regression.

Do not interpret a successful local-file build or compressed archive size as
proof of URL consumption. Package layout and host size still need to satisfy
the expanded transitive budget; there is no validated CLI workaround for this
compiler pin. No compiler change is made here.

## 16. `Ui.each` applications fail during monotype code generation

Reproduced with `nightly-2026-09-09-7dadc35` on Apple Silicon macOS and Linux
x64. `roc check` and `roc test` succeed, but native and Wasm builds terminate
with `SIGSEGV` before producing an artifact. The failure is deterministic with
the compiler cache disabled and one worker. The original reduction retained a
recursive nominal tree and a row-builder call back into its group renderer:

```sh
roc build -j1 --target=wasm32 --opt=size --no-cache \
  repro/recursive-each-codegen/main.roc
```

Further reduction shows recursion is not required. `simple-each.roc` contains
only state, a derived `Rows` signal, and derived row text;
`compound-disposal.roc` contains a constant two-row signal and static row body.
Both build with `nightly-2026-09-04-c125b82` and crash with the September 9
nightly. Their full GUI keyed-rows and compound-disposal counterparts fail at
the same address: `0x3f8` on Apple Silicon macOS and `0x378` on Linux x64.

A current debug compiler turns both small cases into an explicit invariant in
`postcheck/monotype/lower.zig:mergeCheckedEvidenceContract`: checked target
contract evidence differs from substitution-derived evidence while lowering a
platform-required procedure. The producer-authoritative
`retain_constraint_relation` rule was incorrectly nested under the derived
target arm, so structural derived evidence reached the invariant before that
rule could apply. Postcheck monotype lowering is the confirmed compiler area;
the precise bad release dereference remains unsymbolized. See the repro README
for exact good/bad commands and output.

The same nightly also crashes while generating `pomodoro-tracker`,
`form-builder`, `split-the-bill`, and `conduit`; those applications have not
all been reduced to the minimal `Ui.each` shape.
Changing Query Builder's recursive editor would remove supported behavior
rather than work around the compiler. No source workaround or known-failure
entry is applied.

## 17. Markdown Editor retains Roc allocations after native specs

Reproduced with `nightly-2026-09-09-7dadc35` on Linux x64 in hosted CI.
Markdown Editor builds and every semantic assertion reports success, but each
of its 11 isolated spec processes exits with the native host's allocation
ledger holding exactly 30 Roc allocations and 2176 bytes. All retained values
were allocated during mount (`phase=0`) from one generated caller address. The
smallest known behavioral reproduction is the initial-render spec alone:

```sh
GOOD=/path/to/roc_nightly-linux_x86_64-2026-09-04-c125b82/roc
BAD=/path/to/roc_nightly-linux_x86_64-2026-09-09-7dadc35/roc

python3 scripts/test.py native --native always \
  --spec-filter 'markdown-editor/initial-render-*' --roc-bin "$BAD"
python3 scripts/test.py native --native always \
  --spec-filter 'markdown-editor/initial-render-*' --roc-bin "$GOOD"
```

Expected, and actual with the good nightly: the semantic result is `passed`,
the process exits successfully, and no Roc allocation remains. Actual with the
bad nightly: the semantic result is still `passed`, then shutdown reports
`native host shutdown retained 30 Roc allocations / 2176 bytes` and exits 1.
Wasm build, mount, and unmount of the same application release all tracked Roc
allocations, narrowing the regression to generated native ownership code. The
exact compiler subsystem has not been confirmed; native reference-count
insertion or specialization is suspected.

The ledger failure remains a hard test failure: passing visible behavior does
not make ownership imbalance acceptable. No known-failure entry or host cleanup
workaround is applied.
