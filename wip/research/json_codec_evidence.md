# JSON Codec Evidence

Captured: 2026-07-05.

Purpose: record the HTTP/body-codec spike outcome from the RealWorld gap
analysis. This note decides whether Signals should add a JSON/body helper layer
on top of the shipped request/response envelopes and the compiler builtin
`Json` module.

## Focused Gates

For edits to this note:

```sh
git diff --check
zig build run-check-tidy
```

If the service parser or JSON fixture changes, also run:

```sh
python3 scripts/test.py roc-check
python3 scripts/test.py native --native always
```

Refresh check: re-run on 2026-07-05:

- `python3 scripts/test.py roc-check` exited successfully across the maintained
  examples and focused fixtures, including `examples/_fixtures/json-decode` and
  `service-ops-center`.
- `python3 scripts/test.py native --native always` exited successfully for the
  maintained apps and fixtures, including the JSON fixture and service
  dashboard parser path.

## Current Evidence

The shipped HTTP surface already returns explicit request/response envelopes.
Applications receive body bytes or UTF-8 text; when parsing JSON, they feed
text to the compiler builtin `Json` module. This keeps HTTP transport and body
decoding separate: the platform owns request scheduling, cancellation,
stale-result suppression, headers, status, and transport errors; app code owns
its API schema.

The `examples/_fixtures/json-decode` fixture proves the builtin covers the
ordinary app-side needs that would otherwise motivate platform sugar:

- nested records,
- tag-union values,
- custom parser hooks,
- missing-required and invalid-json errors,
- optional fields represented as `Try(..., [Missing])`,
- camel-case field mapping,
- encoding plus parse roundtrip.

The maintained `service-ops-center` app proves the remaining friction is not
an HTTP envelope gap. It decodes one dashboard response into app-domain state,
maps JSON errors into `Dashboard.ParseErr`, validates schema and enum/code
fields, and keeps route/task behavior independent of the parser shape.

## Wide-Record Spike

The earlier service parser intentionally split the raw JSON schema into ten
small derived record parses. The comment in
`examples/service-ops-center/Dashboard.roc` cites a compiler workaround:
derived parsing for one 52+ field record segfaulted on
`roc release-fast-7da362c8`.

The 2026-07-05 check against the current workspace compiler produced the same
class of evidence:

- Replacing the service parser with one wide `RawDashboard` record did type
  check, but `python3 scripts/test.py roc-check` spent about 49 seconds on
  `service-ops-center` alone, compared with tens of milliseconds for the other
  apps.
- Adding an executed 63-field `JsonProbe.Wide` parse to the focused
  `json-decode` fixture crashed `roc check` with `SIGSEGV`.

The 2026-07-06 recheck on `roc release-fast-c0cae661` still reproduces the
compiler crash. A temporary minimization pass showed 45-49 fields pass and
50-63 fields crash. The focused 50-field repro now lives at
`wip/research/wide_record_json_sigsegv_repro.roc`; running
`roc check wip/research/wide_record_json_sigsegv_repro.roc` exits 139 with the
Roc compiler SIGSEGV message. Running the same command under LLDB stops thread
12 with `EXC_BAD_ACCESS` at an invalid generated-code address. Filed upstream
as roc-lang/roc#9964 with the equivalent `test/fx` platform repro.

That means the split service parser remains a current compiler workaround. It
does not prove that Signals needs JSON helpers, because a platform wrapper over
the same builtin derivation would inherit the compiler failure or hide it behind
a less explicit API.

## Decision

Do not promote a Signals HTTP/body JSON helper layer from the current evidence.

Keep the public surface as:

- `roc-lang/http` request and response values,
- Signals task scheduling and response envelopes,
- app-side builtin `Json` parsing/encoding,
- small app-local mappers from API DTOs to domain state.

The service parser stays split until the Roc compiler can handle wide derived
record parsing without a crash or pathological check time. When that upstream
constraint changes, prefer simplifying the app parser before adding platform
surface.

## Reopen Triggers

Reopen this only with a maintained app or focused canary that proves a
Signals-specific gap, for example:

- repeated request/response envelope boilerplate that cannot be removed with an
  app/package helper,
- a typed error-body workflow that needs host participation,
- content-type negotiation that changes command scheduling or response
  classification,
- compiler builtin `Json` limitations after the wide-record derivation issue is
  fixed or avoided.

Do not reopen merely because an app has a large API DTO or domain validation
logic. Those are app/package responsibilities unless they require host behavior.
