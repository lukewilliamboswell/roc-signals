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
Line references are to `examples/conduit/spec.txt` sections by comment
header (line numbers drift; headers are stable).

| Feature | Spec assertion(s) | Status |
| --- | --- | --- |
| Deep link cold-mounts routed page + title | "Cold mount at a deep link" section | done (Phase 1) |
| Header nav push_state routing (brand, Sign in, Sign up) | "Brand link navigates home" section | done (Phase 1) |
| Back/forward keep URL, title, view in sync | "Back/forward walk the entry trail" section | done (Phase 1) |
| All 9 route shapes mount with per-route titles | "Every route shape mounts" section | done (Phase 1) |
| Home query params (page, tag) parse into feed state | "Home query params parse" section | done (Phase 1) |
| Unknown route renders not-found without URL rewrite | "Unknown routes render the not-found page" section | done (Phase 1) |
| Feeds, pagination controls, popular tags | — | Phase 2 |
| Article page with markdown body | — | Phase 2 |
| Profiles (view, tabs) | — | Phase 2 |
| Auth: register/login/logout, JWT persist/restore | — | Phase 3 |
| Guarded routes with replace_state redirects | — | Phase 3 |
| Settings | — | Phase 3 |
| Editor create/edit, article delete | — | Phase 4 |
| Comments create/delete | — | Phase 4 |
| Favorites, follows | — | Phase 4 |
| 422 envelopes on all four forms | — | Phase 3/4 |
| Network failure states on every fetch surface | — | Phase 2-5 |

## Findings

### 2026-07-08 Phase 2 — Builtin Json parser rejects every escape sequence inside JSON strings

Classification: compiler
Severity: blocker (worked around in app code)
Evidence: `wip/research/conduit_decode_probe.roc` — parsing
`{"body":"a\nb"}` returns `InvalidJson` on nightly-2026-July-07 and at
roc-lang/roc HEAD: `Builtin.Json.split_json_string_tail` returns
`invalid_json` whenever a backslash appears before the closing quote, so
`\n`, `\"`, `\\`, `\t`, and `\uXXXX` are all unparseable. Every
RealWorld article body (markdown with newlines) and any bio/title with a
quote hits this; a conformant client cannot avoid it.
Action: upstream issue warranted (draft: "builtin Json cannot parse any
string escape sequence; split_json_string_tail rejects backslashes" with
the probe file); app workaround in `examples/conduit/Api.roc`
(`shield_escapes`/`restore_text`: placeholder-substitute escapes before
parse, restore after decode; `\uXXXX` still unsupported). Remove the
workaround and re-simplify when upstream lands support.

### 2026-07-08 Phase 2 — Native host panics when a Ui.when arm flips during a task resolve/reject flush

Classification: platform-gap
Severity: blocker (worked around in app code)
Evidence: resolving the conduit feed from one row to zero rows (flipping
an is-empty `Ui.when` arm), or rejecting it (flipping an is-failed arm),
panics the native host with "descriptor stream recorded duplicate
descriptor index" (exit 134). Reproduced deterministically by the Phase 2
spec before the workaround; a state-driven equivalent (button click sets
the list empty and flips the same arm shape) does not reproduce, so the
task-completion flush path is implicated. Loading-arm flips at task start
never panicked.
Action: promotion trigger recorded — this is a host correctness bug
(descriptor stream/scope disposal during task flush), to be minimized
into a fixture and fixed as its own slice; conduit's `Feed.roc` renders
empty/failed states as placeholder keyed rows instead of when arms until
then (restore the arms with the fix). Article/Profile pages still use
failed arms and are exposed to the same panic on reject — the Phase 5
error matrix must not land before the host fix.

### 2026-07-08 Phase 2 — Accessible name lookup does not traverse link children; keyed rows need static context

Classification: ergonomics
Severity: paper-cut
Evidence: spec `role:link name:"X"` matchers miss anchors whose text is a
nested `Html.text_s` child (only `Html.link`'s direct label registers an
accessible name). Keyed `Ui.each_str` rows receive only a static key plus
an item signal, so row-level links with dynamic targets encode data in
row keys (`Feed.roc` pagination keys carry `page|tag`; single-row keyed
lists give author links a static username). Workable, but a
`link`-with-signal-label helper or child-traversing name computation
would remove both contortions.
Action: accepted as app code; revisit as a platform ergonomics candidate
only if later phases keep paying it.

### 2026-07-08 Phase 1 — Cold-cache `roc check` takes ~51s on the conduit skeleton; warm re-check is 90ms

Classification: compiler
Severity: friction
Evidence: on nightly-2026-July-07 (`release-fast-050c6975`), the first
`roc check examples/conduit/app.roc` after edits reports ~51,000ms; an
immediate re-check of the unchanged file reports 90ms, so the cost is
cold-cache module-graph compilation, not per-iteration. For comparison,
cold checks of small fixtures are sub-second (`json-decode` ~320ms, the
50-field repro ~1s) while `service-ops-center` is ~64s — app-shaped code
pays far more than fixture-shaped code and the scaling with size is
unclear. Local iteration is fine; the cost lands on cold paths —
`python3 scripts/test.py roc-check` gates and CI check every example from
fresh copies, so each conduit phase adds cold-check latency to every gate
run.
Action: recorded; re-measure at each phase exit, and minimize an upstream
repro if cold checks cross a few minutes at target app size.

### 2026-07-08 Phase 1 — Tag constructors are not first-class functions

Classification: ergonomics
Severity: paper-cut
Evidence: passing a payload tag constructor as a function argument
(`slug_route(prefix, EditorEdit)`) fails to check — the bare tag is
treated as a zero-argument tag (`[EditorEdit, ..]` vs the needed
`Str -> Route`). `examples/conduit/Route.roc` wraps constructors in
lambdas (`|slug| EditorEdit(slug)`) instead.
Action: accepted as app code; language-level, not a platform matter.

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
