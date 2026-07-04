# RealWorld Production Gap Analysis

Captured: 2026-07-04.

Purpose: keep the production-readiness gap analysis and the examples-roadmap
detail out of the active backlog. `wip/NEXT_STEPS.md` cites this note, and its
promotion triggers name the example expansions described here.

Refresh check: created 2026-07-04. Re-check the classifications and the
roadmap when a phase ships or an example expansion lands, so the backlog never
cites stale analysis.

## Focused Gates

For edits to this note, which carries no repository behavior claims, run:

```sh
git diff --check
zig build run-check-tidy
```

## Method

The RealWorld demo spec (Conduit) is a common cross-framework benchmark for a
production SPA: routed pages, a persisted auth session, article bodies
rendered from markdown, and a JSON API. It is used here as a measuring stick
for platform capability, not as a committed demo app.

Conduit requirements were filtered down to platform/API/runtime gaps
(app-specific concerns are listed near the end and excluded from platform
work), then each gap was verified against the repository by searching the
platform Roc modules, the Zig hosts, and the JS runtime.

Repo-verified absences at capture time: no support for or mention of
`window.location`, `history.pushState`/`replaceState`, `popstate`,
`hashchange`, `localStorage`, `sessionStorage`, `navigator.onLine`,
`visibilitychange`, `matchMedia`, `document.title`,
`innerHTML`/`insertAdjacentHTML`, or markdown rendering anywhere in the
platform, hosts, or browser runtime.

## Platform Gaps, Ranked

Classification key: build (schedule through the examples roadmap), spike-gated
maybe (collect evidence first; promote only if it shows structural friction),
probably-not (validate current defaults; do not prebuild).

### 1. Browser URL/history source and navigation commands — build

A production SPA needs the current location as app state, popstate for
back/forward, pushState/replaceState commands, route-change lifecycle
semantics, native spec injection, and JS runtime validation for URL parsing,
dispatch ordering, and unmount cleanup. Without this, routing collapses into
app-local state with anchors.

Today: nothing exists. Prior art: the `Signal.interval` source lifecycle, the
command boundary, and the shipped `prevent_default` static policy for
intercepting link clicks.

Owner: browser-environment priority (location/history sub-item) in
`wip/NEXT_STEPS.md`; design detail in `wip/BROWSER_ENV_DESIGN_PREP.md`.
popstate is the first canary for the subscriptions priority.

### 2. Browser storage — build

Persisted sessions need localStorage (and possibly sessionStorage) reads
during startup, write/remove from Roc commands, clean surfacing of read
failures, a recorded decision on cross-tab storage events, native spec
primitives for initial storage and write assertions, and JS tests for
unavailable storage, malformed values, cleanup, and ordering. Key names and
auth semantics stay app-side; the platform gap is storage as an effect/source.

Today: nothing exists.

Owner: browser-environment priority (storage sub-item); design detail in
`wip/BROWSER_ENV_DESIGN_PREP.md`.

### 3. Startup hydration / typed initial environment — build

Routing and storage both need browser-provided initial values before or
during mount: typed environment values into Roc, no fake-default first render
patched after mount, a sync-only versus task-backed decision, and one
environment snapshot per active mount. This affects the `main : {} -> Elem`
contract and the host boundary, so it is platform/API design, and it is the
shared prerequisite of gaps 1 and 2.

Today: `platform/main.roc` requires `main : {} -> Elem` with no environment
mechanism; mounting runs `SignalsRuntime.mount()`, `roc_ui_mount()`,
`roc_ui_init()`, then `main({})`.

Owner: browser-environment priority (snapshot sub-item); design detail in
`wip/BROWSER_ENV_DESIGN_PREP.md`.

### 4. Subscription source lifecycle — build

Inbound browser sources need scope-owned subscription descriptors, start/stop
lifecycle, stale-message handling, mount-scoped source ids/generations, native
spec injection, and JS source registration. Route changes (popstate) are the
first focused canary; visibility and online status follow on the same
machinery.

Today: the design shape exists in `wip/JS_INTEGRATION_DESIGN_PREP.md`;
`Signal.interval` is lifecycle prior art; the shared boundary payload
vocabulary is shipped and required for reuse.

Owner: subscriptions priority; the first canary is delivered through the
browser-environment location slice.

### 5. Safe rich-content story — decide and validate

Article-style bodies need a generic safe rendering story. Preferred: the app
parses markdown into ordinary `Elem` nodes, needing no raw HTML runtime.
Alternative: a JS behavior renders sanitized markdown into an element-owned
island. Rejected: a raw HTML setter, which would need strict sanitization and
XSS validation.

Today: text rendering is safe; `Elem` element construction accepts arbitrary
tags, so headings, lists, blockquotes, and code structure are constructible;
no raw HTML path exists.

Owner: rich-content priority in `wip/NEXT_STEPS.md`.

### 6. HTTP body codec ergonomics — spike-gated maybe

JSON request-body helpers, response-decode helpers, a consistent error-body
path, or content-type helpers become a platform gap only if an example proves
the current byte/string envelopes plus builtin `Json` are too clumsy or
fragile.

Today: apps use builtin `Json` on body bytes. Standing evidence:
`examples/service-ops-center/Dashboard.roc` flattens its dashboard API body to
scalar fields and re-parses one body through multiple raw record passes.

Owner: HTTP hardening priority; the spike outcome is recorded in
`wip/research/json_codec_evidence.md` when the spike runs.

### 7. Browser fetch-policy knobs — probably-not

credentials, mode, redirect, cache, and referrer policy are not expected
blockers; header-based auth already works with the current surface. Validate
against the roadmap examples; do not prebuild.

Owner: HTTP hardening priority.

### 8. JS runtime debug/introspection hooks — spike-gated maybe

Tests or demos may need generic mount/route/storage/task introspection.
App-specific debug objects (a demo's `window.__app_debug__` shape) stay in app
adapters and must not drive platform surface.

Today: `SignalsRuntime` already exposes telemetry hooks for task lifecycle and
command decode counters.

Owner: subscriptions priority candidate list.

## Explicitly App-Specific

These must not drive platform work directly: Playwright configuration,
selectors/classes/text, exact page templates, feed pagination logic, auth
reducers/state machines, RealWorld API request modules, default avatar
behavior, and exact debug-object shapes.

## Examples Roadmap

Methodology: the maintained examples are grown deliberately so they become the
realistic driving apps that generate requirements and prove each gap. The
promotion gates in `wip/NEXT_STEPS.md` stay, but the evidence is manufactured
instead of awaited. Examples are evidence tools, not compatibility surfaces,
and do not need backwards compatibility.

Current decision: expand existing apps only; no new app and no suite curation
is scheduled. If the flagship becomes unwieldy under the routing expansion,
splitting a dedicated routed app out of it is the recorded fallback.

### service-ops-center: routed ops SPA with visibility-aware polling

Expansion: URL-addressable views including a `/services/:id` drill-down, deep
links, back/forward, a replaceState redirect for unknown service ids, nav
links intercepted with the shipped `prevent_default` static policy, and
visibility-aware polling (a hidden tab pauses the auto-refresh with a visible
status note; returning to the tab triggers a catch-up refresh).

Drives: the startup snapshot (a deep link must mount the right view and start
only that view's HTTP task on first render), the location/history source and
navigation commands, the popstate canary, the visibility canary, and
nested-JSON detail payload evidence for the codec spike.

Guardrail: bounded growth, roughly 2100-2300 total lines across its modules.
If the expansion exceeds that or strains the fiction, split a dedicated routed
app instead (fallback, unscheduled).

### team-checkout: persisted checkout session

Expansion: cart quantities, delivery draft, and current step survive a reload;
a "resume saved order" banner on restore; a "clear saved order" action that
removes keys; a visible "draft could not be saved" notice when writes fail.

Drives: storage startup reads through the snapshot with honest absence
semantics, write/remove commands coalesced per drain (typing must not emit
one write per keystroke), and typed failure surfacing rendered as app state.

### live-search: offline-aware search panel

Expansion: while offline, task starts are suppressed and a "search unavailable
offline" banner shows; returning online re-runs the current query. The source
lives inside the toggleable panel scope, so open/close proves branch-scoped
start/stop/dispose and late-message suppression on top of the app's existing
lifecycle specs.

Drives: the branch-scoped subscription source shape, extending proven spec
patterns.

### release-planner: markdown card notes

Expansion: card notes authored in a small markdown subset (headings, emphasis,
inline code, links, lists) rendered as `Elem` nodes, with a live preview in
the note editor as a parse-on-type workload.

Drives: the rich-content decision, an `Elem`/`Html` coverage audit for nested
inline content, command/patch telemetry for note switches and preview typing,
and a link-scheme allowlist as safety evidence that no raw HTML setter is
needed.

### Unchanged apps

- `api-request-console`: HTTP request/response envelope canary.
- `team-signup`: forms canary for focus/blur/composition and validation attrs
  (see `wip/research/form_input_evidence.md`).
- `deployment-queue`: keyed row create/remove work budgets.
- `workspace-widgets`, `command-palette`: unchanged; no curation scheduled.

### Storage key namespacing

All public examples share one origin on the public site (`scripts/serve.py`
builds one `dist/`), so storage keys collide across apps unless namespaced per
app/mount. This is a real constraint for the storage design, not a
hypothetical.

## Phase Ordering

Dependency spine: the snapshot underpins the initial route and initial
storage; the subscription machinery underpins popstate, visibility, online,
and any future storage events; navigation commands cannot be validated without
a routed example; markdown and JSON evidence need zero platform surface.

### Phase 0: evidence without new surface

- `release-planner` markdown notes plus an `examples/_fixtures/markdown-elem`
  fixture (structure assertions per construct, note-switch work deltas, and a
  bench entry for preview typing).
- `service-ops-center` view selection via app state (`Ui.when`) plus a
  nested-JSON detail payload in the example task backend, decoded with builtin
  `Json`.
- Record the friction notes: views are not linkable, reload loses the current
  view, browser Back exits the app; checkout reload loses the order. Those
  notes are the promotion triggers for the browser-environment sub-items.

### Phase 1: startup environment snapshot

Typed snapshot (URL pieces plus declared storage reads), an
`examples/_fixtures/env-snapshot` fixture, a native initial-environment
injection directive, and a JS snapshot contract test. Proves the first frame
is final: no fake-default render patched after mount.

### Phase 2: subscription machinery and navigation

Scope-owned descriptors, mount-scoped ids/generations, start/stop, and stale
suppression with popstate as the first canary; pushState/replaceState
commands; anchor interception. Fixtures `route-source` and
`subscription-lifecycle`; browser navigation contract tests.
`service-ops-center` becomes fully routed.

Phase 2b, on the same machinery: visibility (`service-ops-center`) and online
(`live-search`).

### Phase 3: storage commands

Write/remove with per-drain coalescing and failure surfacing; `team-checkout`
resume-draft end to end; an `examples/_fixtures/storage-commands` fixture;
browser storage contract tests. Independent of phase 2b; the two may swap.

### Phase 4: JSON verdict

Decide the codec spike from the accumulated decode evidence: promote a narrow
helper layer or close the gap as not-needed. Record the outcome in
`wip/research/json_codec_evidence.md`.

## Result

The narrowed platform readiness list is: URL/history, browser storage, startup
environment hydration, subscription source lifecycle, and the rich-content
strategy, with JSON helper ergonomics and debug/introspection hooks as
spike-gated maybes and fetch-policy knobs as a probable no. Each build item is
scheduled through the examples roadmap above and gated in
`wip/NEXT_STEPS.md`.
