# RealWorld Production Gap Analysis

Captured: 2026-07-04.

Purpose: keep the production-readiness gap analysis and the examples-roadmap
detail out of the active backlog. `wip/NEXT_STEPS.md` cites this note, and its
promotion triggers name the example expansions described here.

Refresh check: re-checked 2026-07-05 after the browser-environment, storage,
focused browser-source, and rich-content example phases landed. Re-check the
classifications and the roadmap when another phase ships or an example
expansion lands, so the backlog never cites stale analysis.

Update 2026-07-06: a dedicated RealWorld demo app (`examples/conduit`) is now
scheduled; the plan, scope, and measures live in `wip/REALWORLD_DEMO_PLAN.md`.
Conduit stops being only a measuring stick and becomes a built app; this note
remains the platform-gap classification record.

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
platform, hosts, or browser runtime. Since capture, location/history, storage,
visibility, online/offline, and document-title updates have landed; the
rich-content proof closed markdown rendering without raw HTML by using ordinary
`Elem` nodes. The remaining unresolved browser API item from that scan is
`matchMedia`; raw HTML remains intentionally unpromoted.

## Platform Gaps, Ranked

Classification key: build (schedule through the examples roadmap), spike-gated
maybe (collect evidence first; promote only if it shows structural friction),
probably-not (validate current defaults; do not prebuild).

### 1. Browser URL/history source and navigation commands — built

A production SPA needs the current location as app state, popstate for
back/forward, pushState/replaceState commands, route-change lifecycle
semantics, native spec injection, and JS runtime validation for URL parsing,
dispatch ordering, and unmount cleanup. Without this, routing collapses into
app-local state with anchors.

Current status: `Browser.location`, push/replace commands, live popstate
updates, native initial-location/history primitives, JS runtime validation,
focused Wasm location fixture exercises, and the routed `service-ops-center`
workflow have landed. `Browser.visibility` and `Browser.online` have also
landed as focused inbound-source canaries through service-ops-center polling
pause/resume and live-search offline/online task gating. `Browser.set_title`
has landed as a separate route-derived command. Remaining route-adjacent
questions such as scroll restoration stay outside this slice.

Owner: shipped browser-environment surface; follow-up questions live under
browser-environment and subscriptions priorities in `wip/NEXT_STEPS.md`.
Design detail lives in `wip/BROWSER_ENV_DESIGN_PREP.md`.

### 2. Browser storage — built

Persisted sessions need localStorage (and possibly sessionStorage) reads
during startup, write/remove from Roc commands, clean surfacing of read
failures, a recorded decision on cross-tab storage events, native spec
primitives for initial storage and write assertions, and JS tests for
unavailable storage, malformed values, cleanup, and ordering. Key names and
auth semantics stay app-side; the platform gap is storage as an effect/source.

Current status: the platform storage foundation and maintained-app proof have
landed. `Browser.local_storage_text` and `Browser.session_storage_text` read
declared keys at startup, local/session write/remove commands ride the command
boundary with runtime coalescing, native specs can seed/assert storage, Wasm
startup reads are seeded through a prepared-mount declaration pass, and
`team-checkout` proves persisted checkout restore/write/clear in native and
Wasm. App-visible recovery from failed write commands remains a separate
command/effect-result design question if future app evidence needs it; the
current validation is recorded in
`wip/research/storage_command_result_evidence.md`.

Owner: shipped browser-environment surface; app-visible write-failure recovery
remains a browser-environment follow-up if future app evidence needs it.
Design detail lives in `wip/BROWSER_ENV_DESIGN_PREP.md`.

### 3. Startup hydration / typed initial environment — built

Routing, focused browser sources, and storage need browser-provided initial
values before or during mount: typed environment values into Roc, no
fake-default first render patched after mount, a sync-only versus task-backed
decision, and one environment snapshot per active mount. This affects the
`main : () -> Elem` contract and the host boundary, so it is platform/API
design, and it is the shared prerequisite of gaps 1, 2, and 4.

Current status: the platform kept `main : () -> Elem` and seeds typed
host-owned environment sources from a synchronous per-mount snapshot before
first render. Location, visibility, online, and declared storage sources now use
that path.

Owner: shipped browser-environment surface; design detail lives in
`wip/BROWSER_ENV_DESIGN_PREP.md`.

### 4. Subscription source lifecycle — built for focused canaries

Inbound browser sources need scope-owned subscription descriptors, start/stop
lifecycle, stale-message handling, mount-scoped source ids/generations, native
spec injection, and JS source registration. Route changes (popstate) were the
first focused canary; visibility and online/offline proved the same machinery
through maintained apps.

Current status: the dedicated browser-source path has landed for location,
visibility, and online/offline, with mount-scoped ids/generations, stale
message handling, native spec injection, JS listener cleanup, and shared
boundary payload reuse. Generic public `Sub` and app-specific interop remain
deferred until a parameterized source or escape hatch proves the app-facing
shape.

Owner: dedicated browser-source internals are shipped for the focused canaries.
Generic public `Sub` and app-specific interop remain deferred under the
subscriptions priority in `wip/NEXT_STEPS.md`.

### 5. Safe rich-content story — closed for current evidence

Article-style bodies need a generic safe rendering story. Preferred: the app
parses markdown into ordinary `Elem` nodes, needing no raw HTML runtime.
Alternative: a JS behavior renders sanitized markdown into an element-owned
island. Rejected: a raw HTML setter, which would need strict sanitization and
XSS validation.

Current status: the first app-side proof has landed and the host follow-up is
fixed. Text rendering remains safe; `Elem` element construction accepts
arbitrary tags, so headings, lists, blockquotes, and code structure are
constructible; no raw HTML path exists. The `markdown-elem` fixture proves
static markdown structure, dynamic nested inline/list `Ui.each`, inline code,
emphasis text, safe-link hrefs, and blocked `javascript:` links. The
`release-planner` expansion proves note switching and preview typing with
bounded command/patch telemetry. Equal-row retained-value ownership and split
outer-row render fallback are now host behavior, not reasons to add a raw HTML
setter.

Owner: closed for current evidence. Enduring design lives in `design.md`;
future richer content helpers require another maintained app or focused canary.

### 6. HTTP body codec ergonomics — closed for current evidence

JSON request-body helpers, response-decode helpers, a consistent error-body
path, or content-type helpers become a platform gap only if an example proves
the current byte/string envelopes plus builtin `Json` are too clumsy or
fragile.

Current status: the spike outcome is recorded in
`wip/research/json_codec_evidence.md`. Apps use builtin `Json` on response
text.
The focused fixture covers nested records, custom parsers, missing/invalid
errors, optional fields, camel-case parsing, and encoding. The
`service-ops-center` dashboard still splits one flattened API body across
multiple raw record parses, but the spike proved that is a current Roc compiler
wide-record derivation constraint, not a Signals HTTP/body helper trigger.

Owner: HTTP hardening priority if a future app proves a new host-level gap.

### 7. Browser fetch-policy knobs — closed for current evidence

credentials, mode, redirect, cache, and referrer policy are not current
blockers; header-based auth already works with the current surface. Validation
against the roadmap examples found no promotion trigger; do not prebuild.

Current status: the validation outcome is recorded in
`wip/research/fetch_policy_evidence.md`. `api-request-console` uses the
full-response request path for same-origin POST requests with headers, body, and
timeout. `service-ops-center` uses same-origin HTTP text refreshes plus
visibility/request-replacement cancellation. Runtime tests assert that browser
fetch receives only method, headers, body, and signal; browser defaults remain
responsible for credentials, redirects, mode, cache, referrer behavior, and
CORS.

Owner: closed for current evidence. Reopen only with a maintained app or focused
browser canary that proves browser defaults are insufficient.

### 8. JS runtime debug/introspection hooks — closed for current evidence

Tests or demos may need generic mount/route/storage/task introspection.
App-specific debug objects (a demo's `window.__app_debug__` shape) stay in app
adapters and must not drive platform surface.

Current status: the spike outcome is recorded in
`wip/research/js_runtime_introspection_evidence.md`. `SignalsRuntime` telemetry
already covers the mount lifecycle, environment/browser-source updates, storage
snapshots and commands, task lifecycle, command batches/decode work, event
payload diagnostics, behavior lifecycle, and cleanup counts used by current
tests and demos. No new debug/introspection surface is promoted.

Owner: closed for current evidence. Reopen only with a maintained app, public
demo, or focused browser test that proves telemetry plus app-local adapters are
insufficient.

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

Current decision (revised 2026-07-06): the expand-existing-apps-only phase is
complete; a dedicated RealWorld demo app, `examples/conduit`, is scheduled as
the next evidence vehicle. It is too large to graft onto an existing app's
fiction, which was the recorded fallback condition for splitting out a
dedicated app. Scope, phases, MoE/MoP definitions, backend strategy, and the
comparison method live in `wip/REALWORLD_DEMO_PLAN.md`; findings accumulate in
`wip/research/realworld_demo_findings.md` from its Phase 0. No other suite
curation is scheduled.

### service-ops-center: routed ops SPA with visibility-aware polling

Expansion: URL-addressable views including a `/services/:id` drill-down, deep
links, back/forward, a replaceState redirect for unknown service ids, nav links
intercepted with the shipped `prevent_default` static policy, and
visibility-aware polling have landed. A hidden tab pauses auto-refresh with a
visible status note; returning to the tab triggers a catch-up refresh.

Drove: the startup snapshot (a deep link must mount the right view on first
render), the location/history source and navigation commands, the popstate
canary, the visibility canary, and nested-JSON detail payload evidence for the
codec spike.

Guardrail: bounded growth, roughly 2100-2300 total lines across its modules.
If the remaining expansion exceeds that or strains the fiction, split a
dedicated app instead (fallback, unscheduled).

Current landed status: `service-ops-center` now derives its selected view from
`Browser.location`, exposes service detail routes such as `/services/api`, uses
intercepted links plus navigation commands, redirects unknown ready routes with
replaceState, and is covered by native and wasm route/back-forward checks. It
also derives document titles from the active route through `Browser.set_title`
and `Ui.on_change_initial`, and consumes `Browser.visibility` to pause interval
polling while hidden, cancel in-flight polling work on hide, keep manual refresh
available, and catch up when visible again. The earlier app-state drill-down
remains useful as the evidence history for why the browser-environment and
subscription canaries were promoted.

### team-checkout: persisted checkout session

Expansion: cart quantities, delivery draft, and current step survive a reload;
a "resume saved order" banner on restore; and a "clear saved order" action
removes keys. A visible "draft could not be saved" notice remains deferred
because storage command failures are not app-state command results yet; see
`wip/research/storage_command_result_evidence.md`.

Drove: storage startup reads through the snapshot with honest absence
semantics and write/remove commands coalesced per drain (typing must not emit
one write per keystroke). App-visible write-failure recovery remains a
browser-environment follow-up.

Current landed status: `team-checkout` restores its current step, delivery
draft, selected plan, and cart quantities from namespaced localStorage keys,
writes edits through `Ui.on_change`, and removes all draft keys through the
clear saved order action. Native and Wasm checks seed storage, verify restored
state, assert writes, and assert removals. Startup read unavailability can
render through `StorageUnavailable`; the write-failure notice remains
unimplemented because storage command failures currently surface as host-level
runtime errors rather than app-state command results.

### live-search: offline-aware search panel

Expansion: while offline, task starts are suppressed and an offline banner
shows; returning online re-runs the current query. The source lives inside the
toggleable panel scope, so open/close proves branch-scoped start/stop/dispose
and late-message suppression on top of the app's existing lifecycle specs.

Current landed status: `Browser.online : Signal(Bool)` seeds before mount,
updates from native `set_online` and browser `online`/`offline` events, and the
live-search native/Wasm checks prove offline suppression, online replay, and
closed-panel cleanup.

### release-planner: markdown card notes

Expansion: card notes authored in a small markdown subset (headings, emphasis,
inline code, links, lists) rendered as `Elem` nodes, with a live preview in
the note editor as a parse-on-type workload.

Drove: the rich-content decision, an `Elem`/`Html` coverage audit for nested
inline content, command/patch telemetry for note switches and preview typing,
and a link-scheme allowlist as safety evidence that no raw HTML setter is
needed.

Current landed status: `release-planner` stores markdown on cards, exposes an
editor with a live parsed preview, and covers note switching plus preview
typing budgets in the native spec. The companion `markdown-elem` fixture covers
static markdown-to-`Elem` structure, dynamic nested inline/list rendering, and
link-scheme safety. The live preview uses ordinary dynamic `Elem` structure; no
raw HTML or browser-only behavior island is required for the current markdown
subset.

### conduit: RealWorld demo (scheduled)

The full Conduit spec as a dedicated maintained app: routed pages with deep
links, JWT session persisted in localStorage, paginated feeds, markdown
article bodies, comments, favorites, follows, and 422 error-envelope
rendering, driven against an in-page deterministic API backend with a
cross-origin conformance pass. Planned to drive: representative action
telemetry for the command-wire dedupe hypothesis, the scroll-restoration
trigger (or its explicit re-deferral), post-roc#9964 JSON ergonomics evidence
at ~19-endpoint scale, and scale evidence for construction-order state
identity in a ~3-4k line app. Detail: `wip/REALWORLD_DEMO_PLAN.md`.

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

- Done for the first rich-content proof: `release-planner` markdown notes plus
  an `examples/_fixtures/markdown-elem` fixture cover structure assertions per
  construct, note-switch work deltas, preview-typing budgets, and link-scheme
  safety without adding platform surface.
- Done for the browser-environment trigger: `service-ops-center` first exposed
  app-state service selection plus a nested-JSON detail payload, then promoted
  that friction into a routed `Browser.location` workflow.
- Done for the storage trigger: `team-checkout` reload now restores its saved
  checkout state from namespaced localStorage keys.

### Phase 1: startup environment snapshot

Done for current browser-environment pieces: typed location, visibility, and
online snapshots plus declared storage read discovery, focused fixtures, native
injection, Wasm mount exercises, and JS snapshot/storage contract tests prove
the first frame can reflect host environment data without a fake-default
post-mount patch.

### Phase 2: subscription machinery and navigation

Done for the popstate/navigation canary: mount-scoped ids/generations, stale
suppression, pushState/replaceState commands, anchor interception, native
history fixtures, focused Wasm fixture exercises, browser navigation contract
tests, and fully routed `service-ops-center`.

Done for Phase 2b, on the same machinery: visibility (`service-ops-center`) and
online (`live-search`).

### Phase 3: storage commands

Write/remove with per-drain coalescing and host-level failure surfacing;
`team-checkout` resume-draft end to end; an
`examples/_fixtures/storage-commands` fixture; browser storage contract tests.
The focused fixture, browser contract tests, and maintained `team-checkout`
resume-draft proof have landed. App-visible write-failure recovery remains
separate from the current command error path and is recorded in
`wip/research/storage_command_result_evidence.md`.

### Phase 4: JSON verdict

Done for current evidence: the codec spike is recorded in
`wip/research/json_codec_evidence.md` and does not promote a Signals
HTTP/body JSON helper layer.

## Result

The current platform readiness build items from this pass are closed for the
maintained examples. JSON/body helper ergonomics, browser fetch-policy knobs,
and JS runtime debug/introspection hooks are closed for current evidence. Later
browser sources, generic subscriptions, app-specific interop, and richer content
helpers stay evidence-gated behind maintained apps or focused canaries in
`wip/NEXT_STEPS.md`.
