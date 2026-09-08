# Upstream compiler bugs

Roc compiler and builtin bugs this repo has hit, with the workaround each one
forced on us. Every entry names the workaround site so the code can be
un-worked-around once the upstream fix lands.

Toolchain: the nightly pinned in `.roc-version`, which is what CI installs.
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
| 10 | Unit-state capability callbacks produce invalid dev Wasm | not filed | `repro/unit-state-wasm-dev/` | no; size backend validates |

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
