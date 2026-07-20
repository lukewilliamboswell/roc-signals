# RealWorld (Conduit) Demo Plan

Captured: 2026-07-06.

Purpose: plan the first full RealWorld-class maintained app, `examples/conduit`.
The app is an evidence instrument first and a demo second: its job is to
discover what roc-signals must support for real production applications while
the API-breakage window is still open (few users, cheap wholesale changes).
The build produces two deliverables:

1. The app itself, submission-shaped: spec-complete against the RealWorld
   frontend spec (https://docs.realworld.show/), built through the standard
   site pipeline, and published as a featured example.
2. A findings ledger (`wip/research/realworld_demo_findings.md`, created at
   Phase 0) recording every platform gap, friction point, compiler issue, and
   confirmation that a gated backlog item stayed unneeded.

License to break: examples are evidence tools with no compatibility promises,
and right now the platform has the same freedom. When conduit evidence proves
a better platform shape, propose the breaking change through the normal
promotion gates with low ceremony; do not paper over API awkwardness in app
code without a ledger entry.

## Status and next steps (updated 2026-07-20)

Work lives on branch `real-world-demo` (PR #13). Phases 0-5 are implemented.
Conduit and the replacement JSON Config Editor are public examples; the site
features Conduit and opens every example on a focused standalone page. Conduit
uses hash routes beneath `/roc-signals/examples/conduit/`, so GitHub Pages deep
links refresh without a fallback server.

The authoritative native behavior script and full repository gate pass with
PATH Roc `release-fast-8eaa9abd`. Coverage includes capability-bearing browser
sources, duplicate-name task routing, keyed-row structural replacement,
descendant accessible-name lookup, repeated mutation/refetch behavior,
same-turn route canonicalization, static-host hash routes, and callable signal
identity. The full dev and size site builds also pass.

Current order:

1. **Merge PR #13.** Make only review and current-main CI fixes; do not add more
   example or platform scope before merge.
2. **Close post-merge evidence.** Run real-backend conformance, an injectable
   `StorageUnavailable` startup case, the longer navigation/soak trace, action
   telemetry, payload measurements, and the comparison study. Recheck/file the
   builtin JSON escape compiler issue separately.

Expect further findings — that is the mission, not a schedule slip. The
project has no users, so platform-shape changes stay cheap; judge every fix
against the long-term ideal architecture (efficient, maintainable, DRY)
rather than the smallest local patch.

## Focused Gates

This note carries no repository behavior claims. For edits, run:

```sh
git diff --check
zig build run-check-tidy
```

## External Assumptions

- roc-lang/roc#9964 (wide-record JSON derivation SIGSEGV) is assumed fixed.
  Fallback if it slips: the split-parse pattern from
  `examples/service-ops-center/Dashboard.roc` is proven and Conduit DTOs are
  narrow (an article is ~10 fields plus a nested author), so this does not
  block the build; record the friction in the ledger either way and refresh
  `wip/research/json_codec_evidence.md` at Phase 0.
- roc-parser markdown support is assumed available as a package dependency.
  Fallback if it slips: extend the app-local parser from
  `examples/_fixtures/markdown-elem` (needs fenced code blocks, images,
  nested lists) and swap to roc-parser later; the Elem-rendering layer is the
  same either way.

Do not block the build waiting on either external; start with the fallback
and swap when available.

## Scope

In scope — the full Conduit feature checklist, each item locked by native
spec assertions:

- Authentication: register, login, logout, JWT persisted in localStorage,
  restored before first render, sent as `Authorization: Token <jwt>`.
- Routes: home `/`, `/login`, `/register`, `/settings`, `/editor`,
  `/editor/:slug`, `/article/:slug`, `/profile/:username`,
  `/profile/:username/favorites` — deep links, back/forward, per-route
  titles, auth-guarded redirects.
- Feeds: global feed, your feed, tag-filtered feed, popular tags sidebar,
  limit/offset pagination (20 per page).
- Articles: CRUD, markdown bodies rendered to `Elem` nodes (no raw HTML),
  favorite/unfavorite with counts.
- Comments: create, read, delete.
- Profiles: view, follow/unfollow, my-articles and favorited tabs.
- Settings: update user (image URL, username, bio, email, password).
- Error rendering: 422 validation envelopes (`{"errors": {...}}`) on all
  forms, network failure states on every fetch surface, loading and empty
  states.

Out of scope / non-goals:

- No SSR, i18n, or offline-first sync.
- No router DSL, route table, or path-pattern matching in the platform;
  routing stays app code (`Route.roc`).
- No platform surface prebuilt for this app; every promotion goes through the
  `wip/NEXT_STEPS.md` gates with conduit named as the trigger.
- No standalone RealWorld deployment commitment yet. The repository demo is
  published and submission-shaped; a real deployment may replace the in-page
  backend and change `Route.demo_base_path`.
- No optimistic mutations in the first pass: favorites/follows/comments are
  server-confirmed with disabled in-flight controls. Promote optimism only if
  UX evidence demands it (that would itself be a ledger finding).

## App Shape

Location: `examples/conduit`, registered as a public example in
`www/data/examples.toml`. Its authoritative native behavior gate, wasm mount,
and both site build modes pass; `design.md` includes it in the maintained app
suite.

Module sketch and size budget (total target 3,000-4,000 lines; crossing
5,000 is itself a finding about platform ergonomics):

- `app.roc` — shell: header/footer, session wiring, route switch (~400-500).
- `Route.roc` — `Browser.location()` ↔ route parse/format, including query
  params for pagination and tag filters (~150).
- `Api.roc` — request builders for all ~19 endpoints, auth header plumbing,
  error-envelope decoding, DTO records and JSON decode/encode via builtin
  `Json` (~600-900; the module most sensitive to roc#9964).
- `Session.roc` — auth state, namespaced storage keys (`conduit.jwt` etc. —
  all public examples share one origin, so keys must be app-prefixed),
  restore/persist/clear (~150).
- `Markdown.roc` — roc-parser (or fallback parser) to `Elem` rendering with
  the link-scheme allowlist from the markdown-elem fixture (~150 rendering).
- Page modules `Home.roc`, `Article.roc`, `Editor.roc`, `Profile.roc`,
  `Settings.roc`, `Auth.roc` (~200-450 each).
- `Format.roc` — ISO date → display formatting (~80).
- `spec.txt` — will be the largest native spec in the suite; if it strains
  spec-runner ergonomics, that is a tooling finding, not a reason to skip
  assertions.

Decisions recorded now:

- Routing mode: hash routes under the fixed published document path
  `/roc-signals/examples/conduit/`. This keeps every deep link refreshable on
  GitHub Pages without a 404 redirect shim. Route parsing remains app code over
  the shipped `Browser.Location` and history surfaces; it does not promote a
  router or hash-specific platform API.
- Backend strategy: an in-page deterministic JS backend following the
  `www/static/example_tasks.mjs` pattern — a conduit API router with seeded
  users/articles/comments, in-memory mutations, real 422 validation, and
  optional latency injection. Native specs inject task responses directly and
  need no backend at all. Unhandled task routes fall through to real browser
  `fetch`, so the same wasm binary can point at a real conformant RealWorld
  backend by base-URL swap; at least one manual cross-origin pass against a
  real backend is required (MoE-2). A local conformant HTTP server stays a
  stretch option only if manual full-stack testing needs it.
- Auth header uses the spec's `Token` prefix, not `Bearer`.

## Goals and Measures of Effectiveness

MoEs answer "did the demo do its job"; the mission is platform evidence, so
MoE-5 is the one that matters most.

- **MoE-1 Feature completeness.** Every checklist item above works and is
  locked by at least one native spec assertion. Verified by a
  feature → spec-line map maintained in the findings ledger; no unchecked
  rows at Phase 5 exit.
- **MoE-2 Conformance.** The app runs unmodified against any conformant
  RealWorld backend: same binary against the in-page backend and, in at
  least one recorded manual pass, a real HTTP backend cross-origin (base-URL
  difference only). The in-page backend's responses are shaped from the
  RealWorld API spec, with 422 envelopes and pagination semantics asserted in
  the JS test suite.
- **MoE-3 Navigation integrity.** Every route shape cold-mounts correctly
  from a deep link with the right title and auth guard; a 10-step
  back/forward trail never desyncs URL and rendered view. Verified by native
  spec plus wasm mount exercises.
- **MoE-4 Robustness.** An enumerated error matrix renders in-app, never as
  console-only failures: 422 on all four forms; network failure on every GET
  surface; stale-response suppression under rapid route switching;
  `StorageUnavailable` boots to a working logged-out app; slow responses show
  loading states.
- **MoE-5 Evidence yield.** The findings ledger classifies every entry
  (platform-gap / app-land-confirmed / compiler / ergonomics / tooling) and
  at build end every `wip/NEXT_STEPS.md` priority 1-5 either cites conduit
  evidence for a promotion or is explicitly re-deferred with a reason. No
  silent workarounds: any place app code routes around a platform deficiency
  has a ledger entry.
- **MoE-6 Submission readiness.** Builds green through
  `python3 scripts/serve.py --no-server` in both app optimization modes, has
  a README, and nothing structural blocks a later publish/submit decision.

## Measures of Performance

MoPs are budgets with named measurements, reusing the existing bench and
work-assertion machinery (`python3 scripts/test.py bench --native always`,
native spec work assertions, SignalsRuntime telemetry). Prior art:
release-planner preview-typing budgets, deployment-queue row budgets.

Interaction budgets (native spec work assertions, ratcheted once measured):

- Feed page change (20 cards swap): bounded commands/patches with keyed row
  reuse; no per-card state loss for unchanged cards.
- Route transition (feed → article → back): patch scope bounded to the routed
  content region; assert zero patches to header/footer scopes.
- Favorite/follow toggle: single-region patch, work independent of feed
  length.
- Editor and comment typing: bounded per-keystroke work; markdown preview
  parse-on-type budget (release-planner prior art); no per-keystroke storage
  writes.
- Tag/tab switch: exactly one in-flight feed request (request replacement
  asserted, stale results suppressed).

Startup and payload:

- Gzipped wasm+js+css per app-opt mode tracked against existing examples;
  conduit will be the largest app — record the first measurement, then set
  the ceiling and ratchet.
- Startup command/decode bytes and time-to-first-render from existing
  runtime telemetry; deep-link first render must reflect route and restored
  session without a post-mount patch flash.

Long-session and wire:

- Soak: scripted feed↔article navigation ×100 plus login/logout cycles with
  plateau counters; memory must plateau (reuse the
  `wip/research/long_session_plateau_evidence.md` machinery). A violation is
  a `design.md` budget finding routed through NEXT_STEPS priority 6.
- Refresh `wip/research/command_wire_live_mount_telemetry.md` with conduit
  action traces — this is exactly the "representative action telemetry, not
  just mount snapshots" that note names as its reopen condition for the
  string-dedupe hypothesis.

Browser-level Lighthouse/Web Vitals snapshots are informative only, never
gates; wall-clock browser numbers are too noisy to ratchet.

## Comparison to Other Implementations

Yes, compare — that is RealWorld's entire premise: identical spec means
differences are attributable to the platform, not the app idea. Comparison
serves three purposes: it calibrates the friction log ("hard everywhere" vs
"hard here"), it gives external anchors to MoPs that otherwise have no
reference point (bundle size, LoC), and it strengthens the eventual public
demo story.

Discipline, because comparison is easy to do badly:

- Compare structurally, not wall-clock. RealWorld is not a perf benchmark
  (js-framework-benchmark serves that); browser timing comparisons across
  implementations of different ages are noise.
- Reference implementations vary wildly in age, completeness, and polish;
  pick few and note their vintage.
- Never distort the app to win a metric; the demo's job is evidence.

Method: pick two or three references — the Elm SPA example (closest
philosophical cousin: typed FP, no-runtime-exceptions story), a Svelte
implementation (closest reactivity model, small-bundle reference), and
optionally React+Redux (mainstream baseline). Compare in a findings-ledger
table:

- App LoC by category (routing, API/DTO, views, state, markdown) — shows
  where roc-signals costs or saves code.
- Gzipped payload delivered for first render.
- Cold-load request count and deep-link behavior.
- Error-state coverage (many reference implementations skip MoE-4 entirely —
  worth knowing either way).
- A short subjective ergonomics narrative per category.

## Build Phases (completed)

Each phase exits by: running the phase-named gates from `wip/NEXT_STEPS.md`
Green Gates, updating the findings ledger, and keeping evidence notes current
in the same slice.

### Phase 0 — pre-flight canaries (no platform changes)

- Cross-origin canary: point a small fixture (or `api-request-console`) at a
  real external HTTPS endpoint with an `Authorization` header; observe
  preflight behavior and error surfacing. This is the only fully unproven
  platform path (all maintained apps are same-origin today); refresh
  `wip/research/fetch_policy_evidence.md` with the outcome.
- roc#9964 verification: re-run the JSON codec fixture with a single wide
  parse; refresh `wip/research/json_codec_evidence.md`.
- Markdown spike: parse a Conduit-style article (headings, fenced code,
  images, nested lists, blockquotes) via roc-parser (or the fallback) and
  render to `Elem`; extend the markdown-elem fixture assertions.
- Backend skeleton: conduit API router in the `example_tasks.mjs` pattern
  with seed data and `GET /api/articles` proven through a fixture.
- Create `wip/research/realworld_demo_findings.md` with the entry format
  below.

### Phase 1 — skeleton

Register `examples/conduit` initially unpublished, shell layout, `Route.roc`, route
switching with placeholder pages, per-route titles, deep links, back/forward
native and wasm coverage.

### Phase 2 — read-only Conduit

Global feed with pagination, popular tags, tag filtering, article page with
markdown body, public profile pages; loading/error/empty states for every
fetch. Feed and route-transition work budgets land here.

### Phase 3 — sessions

Register/login/logout, JWT persist/restore through namespaced localStorage,
auth header plumbing in `Api.roc`, guarded routes with `replace_state`
redirects, settings page, Your Feed tab. Storage assertions and the first
422 form rendering land here.

### Phase 4 — write paths

Editor create/edit with tag input, article delete, comments create/delete,
favorites, follows. Server-confirmed mutation pattern throughout; request
replacement and stale suppression asserted on every mutating surface.

### Phase 5 — hardening and measurement

The full MoE-4 error matrix, static-host hash-route decision, public example,
site gates, and findings synthesis landed. The longer soak, action telemetry,
payload/reference comparison, real-backend conformance, and final JSON escape
recheck remain post-merge evidence rather than merge blockers.

## Findings Ledger Protocol

`wip/research/realworld_demo_findings.md`, one entry per finding:

```
### <date> <phase> — <title>
Classification: platform-gap | app-land | compiler | ergonomics | tooling
Severity: blocker | friction | paper-cut
Evidence: <file / spec / telemetry refs>
Action: <promotion trigger recorded in NEXT_STEPS priority N | issue filed |
        accepted as app code | breaking-change proposal>
```

Promotion result: Conduit required no new public platform surface. Hash routing,
markdown rendering, route parsing, and JSON envelope mapping remain app code.
Scroll restoration, generic `Sub`, app-specific interop, dynamic event
response, fetch-policy knobs, multi-select/file inputs, and storage
write-failure recovery remain deferred until a maintained app proves a sharper
need.

## Risks

- External dependencies slip (roc#9964, roc-parser) — mitigated by proven
  fallbacks above; do not block.
- Scale is unprecedented: ~2× the largest maintained app. Construction-order
  state identity (moving a `Ui.state` binder breaks it) becomes a real
  discipline concern; page-module conventions mitigate, and any bite is a
  high-value ledger finding.
- In-page backend fidelity drift vs the real API — mitigated by the MoE-2
  manual cross-origin pass; running the official API spec collection against
  a thin HTTP wrapper stays a stretch option.
- Public-site weight: Conduit is the largest published example. Both app-opt
  builds and its wasm mount pass; payload comparison remains a post-merge
  measurement.
- Spec-runner ergonomics under a very large `spec.txt` — treat as a tooling
  finding if it hurts.
