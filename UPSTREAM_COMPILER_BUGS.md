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
| 10 | Unit-state capability callbacks produce invalid dev Wasm | not filed | `repro/unit-state-wasm-dev/` | Wasm smoke builds use size; TODO: restore dev after upstream fix |
| 14 | `roc bundle --output-dir` fails across filesystems | not filed | commands below | stage on the output filesystem |
| 15 | A hand-written `parser_for` cannot be annotated | not filed | `examples-gui/counter/Theme.roc` | omit the annotation |

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

See `repro/unit-state-wasm-dev/README.md` for commands and controls. Routine
Wasm smoke builds use `--opt=size`; their call sites carry TODOs to restore
`--opt=dev` after the upstream fix. Site builds validate generated Wasm instead
of treating compiler exit status as proof of a usable artifact. No platform
semantic workaround has been applied.

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

## 15. Package size diagnostic names the wrong override

With `nightly-2026-09-04-c125b82`, fetching a platform package that expands above
104857600 bytes fails with `dependency tree too large`. The diagnostic suggests
`--max-transitive-bytes`, but the implemented option is named
`--max-transitive-mb`.

Reproduce by preparing a Linux GUI release host, running
`scripts/bundle.sh --package gui --no-build --serve --port 8000`, and compiling
the generated URL-bound `Counter.roc` with the pinned compiler. The observed
host archive alone was 151741542 bytes; its complete GUI package expanded to
191834541 bytes. Adding `--max-transitive-bytes=536870912` to `roc build` is
rejected, while `--max-transitive-mb=512` successfully raises the budget. This
is a linked-platform reproduction, not a minimized compiler regression.

Do not interpret a successful local-file build or compressed archive size as
proof of URL consumption. Package layout and host size still need to satisfy
the expanded transitive budget or callers must pass the explicit implemented
override. No compiler change is made here.

## 15. A hand-written `parser_for` cannot carry a type annotation

Reproduced on `nightly-2026-09-04-c125b82`. A nominal type may implement the
`parser_for` codec hook itself, and doing so works — `Theme.Doc` in
`examples-gui/counter/Theme.roc` collects a JSON object into a list so the
theme can reject duplicate keys, which a derived record cannot see. What does
not work is annotating that method.

Naming the concrete builtin types is not possible: `JsonEncoding` and
`JsonState` are `undeclared type` outside the builtin module. Writing the
method generically, in the shape the builtins themselves use, is rejected as a
type mismatch instead:

```roc
Value := [Color(Str), Layout(U32)].{
	parser_for : encoding -> (state -> Try({ value : Value, rest : state }, [InvalidJson(Str), ..]))
		where [
			encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, [InvalidJson(Str)]),
			encoding.parse_u32 : encoding, state -> Try({ value : U32, rest : state }, [InvalidJson(Str)]),
		]
	parser_for = |encoding|
		|state|
			match encoding.parse_str(state) {
				Ok(parsed) => Ok({ value: Value.Color(parsed.value), rest: parsed.rest })
				Err(_) =>
					match encoding.parse_u32(state) {
						Ok(parsed) => Ok({ value: Value.Layout(parsed.value), rest: parsed.rest })
						Err(err) => Err(err)
					}
			}
}
```

The reported type of the returned lambda is
`state -> [Err([InvalidJson(Str)]), Ok({ rest: state, value: Value })]`, which
the checker will not unify with the annotated `Try(...)`. Closing the error
row, opening it, adding `MissingRequiredField(Str)`, and spelling the `Ok`
constructor as `Try.Ok` all produce the same mismatch. The same body checks and
runs correctly with the annotation removed.

Workaround: the `Value.parser_for` and `Doc.parser_for` methods in
`examples-gui/counter/Theme.roc`, and in its byte-identical copy in
`examples-gui/notes-editor/Theme.roc`, are left unannotated and each carries a
comment pointing here. Restore the annotations once the checker accepts them.
