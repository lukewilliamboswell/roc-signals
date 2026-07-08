# RealWorld (Conduit) Demo Findings Ledger

Created: 2026-07-08, at `wip/REALWORLD_DEMO_PLAN.md` Phase 0.

Purpose: one entry per finding from the `examples/conduit` build — every
platform gap, friction point, compiler issue, tooling pain, and every
confirmation that a gated backlog item stayed unneeded. No silent
workarounds: any place app code routes around a platform deficiency gets an
entry here. At build end, every `wip/NEXT_STEPS.md` priority 1-5 either
cites conduit evidence for a promotion or is explicitly re-deferred with a
reason (MoE-5).

Entry format:

```
### <date> <phase> — <title>
Classification: platform-gap | app-land | compiler | ergonomics | tooling
Severity: blocker | friction | paper-cut
Evidence: <file / spec / telemetry refs>
Action: <promotion trigger recorded in NEXT_STEPS priority N | issue filed |
        accepted as app code | breaking-change proposal>
```

## Feature → spec-line map (MoE-1)

Maintained from Phase 1 onward; no unchecked rows at Phase 5 exit.

| Feature | Spec assertion(s) | Status |
| --- | --- | --- |
| (populated as features land) | | |

## Findings

### 2026-07-08 Phase 0 — Nightly compiler renamed the builtin `Json` error type; repo idiom broke under floating-nightly CI

Classification: compiler
Severity: blocker (for gates; resolved in this slice)
Evidence: `roc check` on nightly-2026-July-07 (`release-fast-050c6975`)
rejected every `Try(a, Json)` annotation ("The type Json is not exposed by
the module Builtin") in `examples/service-ops-center/Dashboard.roc`,
`examples/_fixtures/json-decode/JsonProbe.roc`, and
`wip/research/wide_record_json_sigsegv_repro.roc`. Upstream change landed
between nightly-2026-July-05 (`c0cae66`, last green vintage) and
nightly-2026-July-06/07: the parse error type is now `Json.ParseErr` with
payload-carrying tags `MissingRequiredField(Str)` / `InvalidJson(Str)`
(previously bare `Json` with `MissingRequired` / `InvalidJson`), and
`Json.encode` was replaced by `Json.to_str` / `Json.to_str_try`
(roc-lang/roc commit 84f5cc921c). CI floats on `nightly-new-compiler`
(`.github/workflows/ci.yml:30`), so main was red against the current
nightly independent of any conduit work.
Action: accepted as app code — migrated all three files to
`Json.ParseErr` / `MissingRequiredField(_)` / `InvalidJson(_)` /
`Json.to_str_try` in this slice; `wip/research/json_codec_evidence.md`
refreshed. The payload-carrying tags are a small win for conduit: decode
errors can now surface the offending field name in error states.

### 2026-07-08 Phase 0 — New effectful-name lint requires `!` on the platform's hosted declarations; warnings now fail `roc check` gates

Classification: compiler
Severity: blocker (for gates; resolved in this slice)
Evidence: nightly-2026-July-07 (`release-fast-050c6975`) emits seven
"EFFECTFUL FUNCTION NAME" warnings for the annotation-only hosted
declarations in `platform/HostValue.roc` (`clone`,
`store_with_capability`, ..., `take_with_split`) and exits 2 on
warnings-only checks, which fails `python3 scripts/test.py roc-check` for
every example. This is intentional upstream behavior, not a false
positive: annotation-only declarations in the platform package are
rewritten to hosted lambdas, which the effectful-name check always treats
as effectful (see roc-lang/roc 8684eb0abf, which narrowed the transform to
platform packages precisely because "only the platform package
legitimately provides hosted functions"; upstream's own `test/fx` platform
names all hosted functions with `!`). The lint checks only the hosted
declaration's own body, so the rename does not cascade: pure platform
callers (`Capability.roc`, `Ui.roc`) keep their names.
Action: accepted as platform-internal migration — renamed the seven
`HostValue` functions with a `!` suffix and updated the `hosted` table in
`platform/main.roc` plus the call sites in `Capability.roc`/`Ui.roc`.
App-invisible (HostValue is not in the platform `exposes` list); the host
ABI symbol names (`roc_host_value_*`) are unchanged. Worth watching: the
platform still types these as pure (`->`) while upstream's convention is
the effectful arrow (`=>`) — if upstream later enforces call-site
effectfulness, the purity model of the view layer needs a real design
response, not a rename. If a floating-nightly breakage recurs, pinning
`nightly-tag` in `.github/workflows/ci.yml` (setup-roc supports it) is the
recorded option.

### 2026-07-08 Phase 0 — Markdown spike: app-land parser covers Conduit article syntax; roc-parser dependency not needed yet

Classification: app-land
Severity: paper-cut
Evidence: `examples/_fixtures/markdown-elem` extended with fenced code
blocks (multi-line state across the line fold), images (`![alt](src)` with
the same scheme allowlist applied to `src` — javascript: images degrade to
plain alt text with no `img` attribute), and one-level nested lists
(grouped consecutive `- ` / `  - ` lines into a single keyed list block).
Native spec asserts all three in both the static and the signal-backed
live views, plus the existing patch budgets
(`expect_metric_delta_at_most patches_emitted 80`), all green under
`python3 scripts/test.py native --native always`. No roc-parser package
dependency exists in the repo; the plan's fallback (extend the app-local
parser) is the working path, and the conduit `Markdown.roc` can start from
this fixture.
Action: accepted as app code; swap to roc-parser only if it ships as a
package and materially simplifies the module.

### 2026-07-08 Phase 0 — Spec `fill` strings cannot express newlines, so multi-line markdown is untypeable in native specs

Classification: tooling
Severity: friction
Evidence: `src/spec/spec_parser.zig` unescapes `\n` only for
`custom_event` and `resolve_task`/`reject_task` payloads
(`dupeUnescapedQuoted`); `fill` values pass through verbatim, so a typed
`"\n"` reaches the app as two characters. The markdown-elem fixture works
around it by prefilling the live view's initial state with a multi-line
sample (fence + nested list) and keeping `fill` exercises single-line.
Conduit's editor page (multi-line article bodies, markdown preview
parse-on-type budgets) will hit the same wall.
Action: accepted for Phase 0; if conduit's editor specs need real
multi-line typing, propose extending `fill` (or a `fill_multiline`
command) as a spec-runner slice — record the decision here when Phase 4
reaches the editor.

### 2026-07-08 Phase 0 — Conduit in-page backend skeleton proven (seeded router, pagination, 422 envelopes, auth plumbing)

Classification: app-land
Severity: paper-cut
Evidence: `www/static/conduit_backend.mjs` implements the RealWorld read
surface plus login as a deterministic in-memory backend in the
`example_tasks.mjs` pattern: seeded users/articles/comments, spec-shaped
envelopes, limit/offset pagination with total `articlesCount` (23 seeded
articles so the default 20-per-page paginates), `Authorization: Token`
parsing with viewer-dependent `favorited`/`following` flags, 422/401/404
error envelopes, and optional latency injection with abort handling.
Dynamic path segments (`/api/articles/:slug`) do not fit
`createHttpTaskRouter`'s literal route keys, so the handler decodes the
request itself with the exported payload codecs and returns null for
non-conduit URIs to keep the chain fall-through semantics. 13 node tests
in `scripts/browser/conduit_backend.test.mjs` (wired into
`zig build run-test-browser`, 95/95 green) lock pagination semantics and
the 422 envelope shape per MoE-2. List responses intentionally omit
article `body` (matches the spec's Multiple Articles example), keeping the
app's feed DTO compatible with the weakest conformant backend.
Action: accepted as app-support code; mutation endpoints land with the
Phase 3/4 app slices that exercise them.

### 2026-07-08 Phase 0 — Cross-origin authenticated fetch works under browser defaults; CORS denial surfaces as renderable Network error

Classification: app-land (confirmation — no platform gap)
Severity: paper-cut
Evidence: real-browser canary via headless Chrome against the shipped
`signals.mjs` fetch path; full observations and boundary recorded in
`wip/research/fetch_policy_evidence.md` (2026-07-08 refresh). A
preflighted cross-origin GET with `Authorization: Token ...` succeeded
against a CORS-enabled endpoint with the header transmitted; a no-CORS
endpoint surfaced as the documented `network` HttpError. The one fully
unproven platform path from the plan is now observed; conduit needs no
fetch-policy knobs for header-based auth (NEXT_STEPS priority 3 candidate
"browser fetch-policy controls" stays closed).
Action: accepted — no promotion; cookie-credentialed cross-origin and the
real-backend conformance pass remain the recorded gaps (MoE-2, Phase 5).

### 2026-07-08 Phase 0 — roc#9964 wide-record JSON SIGSEGV no longer reproduces on current nightly

Classification: compiler
Severity: friction (downgraded from blocker; issue still open upstream)
Evidence: `roc check wip/research/wide_record_json_sigsegv_repro.roc`
(50-field record, updated to the new `Json.ParseErr` idiom) exits 0 in
~1.0s on nightly-2026-July-07 (`release-fast-050c6975`); on
`release-fast-c0cae661` the same check exited 139 (SIGSEGV). roc-lang/roc#9964
remains open upstream — not yet closed or commented, so treat the fix as
unconfirmed-by-upstream and keep the repro file until it closes.
`examples/service-ops-center/Dashboard.roc` still `roc check`s in ~64s with
its ten-way split parse; whether a single wide parse is now both correct
and fast is a follow-up measurement (recorded in
`wip/research/json_codec_evidence.md` as a reopen note). Conduit DTOs are
narrow (~10 fields + nested author), so Api.roc plans single parses per DTO
either way.
Action: accepted as app code (single-parse DTOs in conduit Api.roc);
re-verify against roc#9964 when upstream closes it; json_codec_evidence.md
refreshed with the recheck.
