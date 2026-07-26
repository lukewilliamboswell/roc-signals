# Signals — Next Steps

This file is the active backlog. It should contain only unfinished work and the
current ordering. Completed phase notes, benchmark snapshots, and retired findings
belong in git history or focused design notes, not here.

## Direction

The shipped consolidation and production-readiness surface lives in `design.md`
and the linked evidence notes. This backlog tracks only remaining promotion
candidates, current ordering, and the gates for adding new public surface or
promoting structural work.

The current phase is production-application readiness, measured against a
RealWorld (Conduit)-class SPA. This phase is *expected* to uncover platform
gaps, engine defects, and developer-experience friction — that is its point,
not a setback: every finding feeds the ledger and improves the platform. The
project has no users yet, so there is no compatibility pressure; when evidence
shows a better shape, change the platform wholesale rather than accreting
workarounds. The bar for any fix or change is the long-term ideal
architecture: efficient (preserve the O(1) lookup, local-splice, and
memory-plateau disciplines in `design.md`), maintainable, and DRY.

The gap analysis, examples roadmap, and per-app
landed status live in `wip/research/realworld_gap_analysis.md`.
`wip/BROWSER_ENV_DESIGN_PREP.md` holds browser-environment slice detail and
open follow-up questions. Keep shipped controlled input/forms, canonical
event-binding, public guide, bundle/release-flow, and native spec runner layers
current when public surface changes.

The completed `examples/conduit` RealWorld demo is the current
production-readiness evidence source; its plan and findings live in
`wip/REALWORLD_DEMO_PLAN.md` and
`wip/research/realworld_demo_findings.md`. The build promoted no new public
surface. Follow-up promotions still require a concrete app or canary trigger
against the priorities below.

Evidence still gates public surface and structural promotions, but the evidence
is now manufactured deliberately: the maintained examples are grown along the
roadmap in `wip/research/realworld_gap_analysis.md` so they become the realistic
driving apps that prove each gap, instead of waiting for an app to happen to
need something.

Guiding rules:

- Do not add duplicate public helpers when a smaller core API plus focused sugar is
  enough.
- Do not keep compatibility APIs as permanent design inputs. Compatibility shims are
  temporary migration tools and should have an explicit removal path.
- Keep JS and native hosts as boundary executors. Roc describes explicit data; hosts
  execute descriptors and report diagnostics.
- Prefer typed descriptors over public bit flags or ad hoc stringly protocols.
- Add public surface only when a maintained app or focused canary proves the
  need; do not prebuild from gap analysis alone.
- Treat example apps as evidence tools, not compatibility surfaces. Grow or
  rework them freely; when coverage moves between apps, unique canaries and work
  assertions move with them, and the `design.md` app-suite list plus
  `www/data/examples.toml` update in the same slice.
- Keep `wip/PUBLIC_API_SHRINK_AUDIT.md` current whenever the public surface
  changes, and reflect removed or renamed surface in docs/examples in the same
  slice.
- When a design prep item has shipped, remove it from this backlog and fold the
  enduring parts into `design.md` instead of keeping it as a completed task.

### Evidence roadmap

Per-app rationale, phase ordering, landed status, and deferred suite-curation
decisions live in `wip/research/realworld_gap_analysis.md`. Use that note to
choose the proving app or focused canary; keep the roadmap detail out of this
active backlog.

## Active merge and evidence work

Active Roc toolchain: use `roc` from `PATH` and record `roc version` with gate
results (reviewed 2026-07-20 as `release-fast-8eaa9abd`). Temporary compiler
checkouts are retired for this workstream. Use `--no-cache` from this sandbox,
e.g.
`roc build --no-cache --target=arm64mac --opt=dev --output=/tmp/conduit-dbg
examples/conduit/app.roc`.

### 0a. Merge RealWorld demo PR #13

**Goal:** merge the completed RealWorld-class maintained app and callable
signal-identity refactor once required CI is green.

Implementation, publication, visual polish, hash-route static hosting, native
behavior, and local release/readiness gates are complete. The PR also adopts
boxed evaluator callables as signal identity, following roc-lang/roc#10264.
Completed evidence belongs in `wip/research/realworld_demo_findings.md`, not
this active backlog.

Current merge order:

1. Keep PR #13 free of new feature work and resolve only review or current-main
   CI failures.
2. Merge when required CI is green.

The compiler, native behavior, full repository, wasm mount, and public dev/size
site gates pass with the reviewed PATH toolchain. Conduit and the JSON config
editor are published examples. Real-backend conformance, the long soak/action
telemetry pass, payload/reference comparison, and the builtin JSON escape
recheck remain post-merge evidence work; none blocks PR #13.

## Active priority order

The priorities below are ordered promotion candidates. Do not implement public
surface or structural work from priorities 1-6 until a maintained app,
focused canary, or current measurement satisfies its gate; otherwise keep design
notes current and avoid unpromoted implementation. The order is a
risk/order-of-evidence guide, not a mandate to build without a fresh trigger.

### 1. Browser environment follow-ups, gated on proven app or canary need

**Goal:** keep the shipped browser-environment surface focused and promote only
remaining browser APIs that a maintained app or focused canary proves.

Current state: the shipped browser-environment surface and coverage live in
`design.md` and `wip/BROWSER_ENV_DESIGN_PREP.md`; roadmap evidence lives in
`wip/research/realworld_gap_analysis.md`. The remaining candidates below are
follow-ups beyond the shipped startup, location/history, storage,
visibility/online, and document-title surface.

First promotion trigger: name one maintained app or focused canary and one
specific browser-environment gap beyond the shipped surface. Keep each
promotion narrow, reuse the shared boundary payload vocabulary, and keep route
parsing, storage serialization, and key namespacing in app/package code.

Candidate items:

- App-visible recovery from failed storage write/remove commands. The current
  validation is recorded in
  `wip/research/storage_command_result_evidence.md`: `team-checkout` can render
  startup read unavailability through `StorageUnavailable`, but write/remove
  failures are still host/runtime errors. Promote only with a maintained app or
  focused canary that proves rendered command failure recovery, and co-design it
  with a broader command/effect-result surface rather than a storage-only side
  channel.
- Cross-tab storage events, behind the subscriptions priority, only if
  app-visible same-origin sync becomes necessary.
- Scroll restoration, hash-specific behavior, or split path/query/hash sources
  only if a routed maintained app proves raw location pieces plus app code are
  insufficient.
- IndexedDB or other async storage abstractions only with a concrete app need;
  they should ride task/effect semantics, not the synchronous startup snapshot.

Non-goals:

- No router DSL, route table, or path-pattern matching in the platform.
- No whole-store storage snapshots.
- No platform serialization framework; stored values remain text and apps use
  `Str`, builtin `Json`, or app/package codecs.

### 2. Subscriptions and app-specific JS interop

**Goal:** add broader inbound host messages only after a maintained app or
focused canary proves the surface.

`wip/JS_INTEGRATION_DESIGN_PREP.md` holds the design detail. The shared boundary
payload vocabulary and `Capability` ownership model are required reuse points;
subscriptions must not introduce a second payload format. `Html.behavior`
remains an element-scoped browser widget hook, `Signal.interval` remains a
timer/effect source, and promoted subscription or interop handlers should be
registered on the owning `SignalsRuntime`.

Current state: the focused browser-source path for location, visibility, and
online/offline has shipped; proof lives in
`wip/BROWSER_ENV_DESIGN_PREP.md` and `wip/JS_INTEGRATION_DESIGN_PREP.md`.
Generic public `Sub` and app-specific interop remain deferred.

First promotion trigger: name a later source or interop need that proves
app-facing generalization is required. Cross-tab storage events, a parameterized
browser source, or app-specific interop may qualify; the already-shipped focused
sources and `Signal.interval` are prior art, not sufficient triggers.

Deliverables when promoted:

- Mount-scoped source ids and generations.
- Scope-owned subscription descriptors with stable identity and host diffing:
  unchanged descriptors do not restart, parameter changes restart, and disposal
  stops the resource.
- Start/stop/unmount cleanup semantics.
- Shared boundary payload decoding.
- Stale-message diagnostics.
- Native spec injection primitives that model semantics without becoming a browser
  clone.
- Work metrics proving subscription diffing is bounded by changed scopes.
- A typed effect capability registry shape shared with HTTP task routing. Replace
  task-name string prefixes only when the promoted subscription/app-interop slice
  proves the shared task/subscription routing model, not as unrelated HTTP churn.

Keep deferred until needed:

- Public generic `Sub` API.
- Ports-like app-specific JS channels.
- Browser source catalogs beyond focused canaries.
- JS runtime debug/introspection hooks; the closed spike outcome lives in
  `wip/research/js_runtime_introspection_evidence.md`. Reopen only when a
  maintained app, public demo, or focused browser test proves telemetry plus
  app-local adapters are insufficient.

### 3. HTTP production hardening, gated on proven app or canary need

**Goal:** close the remaining gaps between the shipped package-aligned HTTP
slice and production expectations, promoting each item only when a maintained
app or focused canary proves the gap.

Current state: the shipped package-aligned HTTP surface and coverage live in
`wip/research/http_effects_evidence.md`. Current routing still uses task names
with the `http:send:` prefix. The RealWorld-lens analysis
(`wip/research/realworld_gap_analysis.md`) confirms this candidate list.

First promotion trigger: name one maintained app or focused canary and one
specific production gap. Keep the promoted slice narrow: explicit abort must
prove user-driven cancellation distinct from scope disposal or request
replacement; effect capability routing must be co-designed with the
subscriptions priority; JSON or body helpers must prove builtin `Json` plus
request/response envelopes are not enough; browser fetch-policy knobs must
prove a maintained app or focused canary needs host control beyond the current
browser defaults.

Candidate items:

- Explicit user-driven abort, distinct from scope disposal.
- Typed effect capability registry replacing the current `http:send:` task-name
  prefix routing only after the subscriptions priority proves the shared
  task/subscription routing model with a subscription or interop canary. The
  shipped focused browser-source canaries prove source ids, generations, and
  lifecycle cleanup, but do not by themselves justify unrelated HTTP routing
  churn.
- JSON/body helper sugar only if a new maintained app or focused canary proves
  builtin `Json` plus request/response envelopes are insufficient; the current
  no-promotion outcome lives in `wip/research/json_codec_evidence.md`.
- Browser fetch-policy controls such as credentials, redirect, mode, cache, or
  referrer policy only if a maintained app or focused canary proves browser
  defaults are insufficient; the current no-promotion outcome lives in
  `wip/research/fetch_policy_evidence.md`.

### 4. Form/input hardening, gated on proven app or canary need

**Goal:** extend beyond the shipped controlled input/forms milestone only when a
maintained app or focused canary proves a concrete browser-form gap.

Use this priority for future roadmap expansions that expose a browser-form gap.

Current state: the shipped controlled input/forms surface and coverage live in
`wip/research/form_input_evidence.md`.

First promotion trigger: name one maintained app or focused canary and one
specific browser-form gap the current helpers cannot express. The promoted slice
must stay narrow and include the right host split: JS contract coverage for
browser-only details such as selection/caret, file inputs, or constraint
validation, plus native/app specs for semantic state changes without turning the
native runner into a browser clone.

Candidate items:

- Selection-preserving normalization for masks/formatters such as currency,
  phone, credit card, or slug fields.
- File inputs as browser-owned/uncontrolled controls with explicit event payloads.
- Multi-select and richer select/radio semantic actions only when state in a
  maintained app or focused canary proves the current single-value helpers are
  not enough.
- Browser constraint validation integration, app-visible focus commands, or
  date/time input helpers only when a maintained app or focused canary requires
  host involvement.

Non-goals:

- Do not make the native spec runner a full browser clone; browser-only behavior
  such as exact IME ordering belongs in JS contract tests.
- Do not add form helper families when general attrs/events plus focused sugar
  express the maintained app or focused canary cleanly.

### 5. Dynamic event response, only if needed

**Goal:** support expert cases where event response depends on event payload or app
state, without taxing ordinary handlers or adding duplicate APIs.

Current state: the static-policy, event-delivery, shared payload, response-bit,
and native event-flow proof lives in `wip/EVENT_PROPAGATION.md`. The
RealWorld-lens gap analysis (`wip/research/realworld_gap_analysis.md`) found no
current need for dynamic response; link-click `prevent_default` is already
shipped static policy. Roc handlers still return zero response bits, and no
app-facing dynamic handler surface is promoted.

First promotion trigger: name one maintained app or focused canary that needs
state-dependent event response that static `EventPolicy` cannot express.

Design guardrails:

- `wip/EVENT_PROPAGATION.md` holds the event design detail. Keep future dynamic
  response, same-event handler composition, or broad payload work on the shipped
  canonical `EventBinding` and shared boundary-schema path; do not reintroduce
  event-only payload formats or listener-option bits as public API.

Deliverables when promoted:

- Dynamic response only through explicit `state.on_event`-style handlers that return
  both next state and `Event.Response`.
- Response bits continue to be validated and applied synchronously before the JS
  listener returns and before event response commands drain.
- Ordinary `on_unit` / `on_str` / `on_bool` / `on_detail` / `on_key` handlers
  remain static-policy only.
- Handler chains are not a prerequisite for the first dynamic-response slice. Add
  ordered chain semantics only when composition pressure proves the need, or when
  the promoted dynamic-response implementation requires a binding-level handler
  shape; an initial implementation may reject multiple stateful handlers after
  canonicalization while preserving that target shape.

Non-goals:

- No separate payload-only dynamic response API unless repeated code proves it is
  worth adding as sugar.
- No public handler-chain surface without a maintained app or focused canary that
  needs same-event composition.
- No async/task-based event response; browser event policy must remain synchronous.

### 6. Structural/design-gap backlog

Feature work above should not bury a core propagation or scaling gap when a metric
shows a `design.md` budget is violated. The following remain eligible, but should
be promoted only with current measurements.

First promotion trigger: name the violated `design.md` budget, the current
counter or benchmark that proves it, and the smallest representative app or
focused fixture that reproduces it. The promoted slice must preserve existing
O(1) lookup and local-splice discipline; do not trade long-session memory
plateaus for scans or broad rebuilds.

#### Long-session growth / slot reclamation

No active structural work is promoted. The current plateau and slot-reuse proof
lives in `wip/research/long_session_plateau_evidence.md`.

Promote only with a new failing measurement that names the violated `design.md`
budget, the current counter or benchmark that proves it, and the smallest
representative app or focused fixture that reproduces the growth path. Preserve
O(1) lookup discipline for id-indexed reads; do not fix memory by reintroducing
scans on hot lookup paths.

#### Measured command-wire string dedupe

Keep as a hypothesis, not active work. Evidence, refresh commands, and reopen
criteria live in `wip/research/command_wire_live_mount_telemetry.md`; the static
framing estimate lives in `wip/research/wire_protocol_dynamic_size_estimate.mjs`.

Promote only if representative action telemetry, not just mount snapshots, shows
fixed/dynamic string traffic is larger than the remaining structural tail and a
scoped dedupe slice lowers total command/decode bytes. Do not globally intern
Roc strings, `HostValue`s, keys, or capability-owned data.

#### Additional scratch/arena work

Promote only when named counters identify a specific transient buffer still worth
moving and the measurement separates host-internal scratch from Roc-owned heap
values.

- Keep Roc heap allocations and host-internal scratch separate.
- Do not move boxed Roc values or refcounted data into per-cycle scratch storage.

## Green Gates

Use the smallest gate that proves the slice, then run the end-to-end repository
gate before committing. For a pure refactor slice the existing native specs are
the regression guard; a behavior-changing slice must also land the assertion that
locks it in.
Before implementing any promoted priority above, record the promotion trigger in
the relevant priority and linked design/evidence note; if the trigger is still
missing, keep the work to design notes, evidence, or existing-surface hardening.
When updating a linked design or evidence note, run the focused gates named in
that note whenever the edit changes a current-state or coverage claim.
When public surface changes, update the `design.md` API sketch,
`wip/PUBLIC_API_SHRINK_AUDIT.md`, and public guide/examples in the same slice so
the shipped surface is not split across competing maps.

- Pre-commit tidy gate:
  `git diff --check`
  `zig build run-check-tidy`
- Focused Zig host work:
  `zig build run-test-zig -Dtest-filter="signals host"`
- Native spec runner, simulated DOM, or app spec changes:
  `python3 scripts/test.py native --native always`
- Benchmark or work-budget changes:
  `python3 scripts/test.py bench --native always`
- Coverage/test-gap investigation after substantial native host, `src/signals`,
  spec runner, simulated DOM, allocation diagnostic, or host-runtime changes:
  `zig build run-coverage-native-host`
- Platform host artifacts, including wasm32:
  `zig build build-test-hosts -Doptimize=ReleaseSmall`
- Platform Roc or ABI changes:
  `python3 scripts/test.py roc-check`
- Focused wasm app build and mount regression:
  `python3 scripts/test.py wasm`
- Platform bundle/release-flow regression:
  `python3 scripts/test.py bundle --bundle always`
- Zig-only checks and tests:
  `zig build test`
- JS↔WASM contract guards:
  `zig build run-test-browser`
- Browser host + public apps build, both app optimization modes. Run these
  sequentially because both write `dist/`:
  `python3 scripts/serve.py --no-server --app-opt dev`
  `python3 scripts/serve.py --no-server --app-opt size`
- End-to-end repository gate:
  `python3 scripts/test.py`

For doc-only updates that do not change evidence claims, run `git diff --check`
and the tidy gate. For public site content, docs, or site config changes, also
run the browser host + public apps build gate in both app optimization modes so
the rendered site and downloadable example sources stay valid.
