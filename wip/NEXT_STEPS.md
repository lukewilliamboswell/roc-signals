# Signals — Next Steps

This file is the active backlog. It should contain only unfinished work and the
current ordering. Completed phase notes, benchmark snapshots, and retired findings
belong in git history or focused design notes, not here.

## Direction

The consolidation phase is done. The platform now has one typed boundary
(shared boundary schema tags / `EventExtractionPlan` plus bundled `Capability`
ownership), one canonical event binding model with typed static policy and
delivery, a versioned hybrid wire protocol with dynamic records, and
package-aligned HTTP pinned to `roc-lang/http`. The maintained example apps
drove and proved those layers.

The next phase is production readiness, not new surface. The controlled
input/forms milestone now has focused native and JS canaries, including
signal-backed optional custom text attrs for honest absence semantics. The
canonical event-binding and static-policy slice has shipped; remaining event
work is canary- or measurement-gated. The public guide, bundle/release flow, and
native spec runner are now documented and validated against the configured
release bundle; keep them current when public surface changes.

Guiding rules:

- Do not add duplicate public helpers when a smaller core API plus focused sugar is
  enough.
- Do not keep compatibility APIs as permanent design inputs. Compatibility shims are
  temporary migration tools and should have an explicit removal path.
- Keep JS and native hosts as boundary executors. Roc describes explicit data; hosts
  execute descriptors and report diagnostics.
- Prefer typed descriptors over public bit flags or ad hoc stringly protocols.
- Add surface only when a maintained app or focused canary proves the need.
- Keep `wip/PUBLIC_API_SHRINK_AUDIT.md` current whenever the public surface
  changes, and reflect removed or renamed surface in docs/examples in the same
  slice.
- When a design prep item has shipped, remove it from this backlog and fold the
  enduring parts into `design.md` instead of keeping it as a completed task.

## Active priority order

The priorities below are ordered promotion candidates. Do not implement a
surface from priorities 1-4 until a maintained app, focused canary, or current
measurement satisfies its gate; otherwise keep design notes current and avoid
new public API.

### 1. Dynamic event response, only if needed

**Goal:** support expert cases where event response depends on event payload or app
state, without taxing ordinary handlers or adding duplicate APIs.

First promotion trigger: name one maintained app or focused canary that needs
state-dependent event response. The shared boundary, typed static policy
(`prevent_default`, propagation, capture, passive, once, `self`, and `trusted`),
and explicit `EventDelivery` request path are met; the ABI already returns
response bits. Browser dispatch now validates returned response bits, applies
supported DOM-response controls synchronously before draining event response
commands, and fails closed on unsupported bits; current Roc handlers still return
zero, so the missing piece is the explicit app-facing handler surface that can
produce non-zero bits.

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

### 2. Subscriptions and app-specific JS interop

**Goal:** add broader inbound host messages only after a maintained app or
focused canary proves the surface.

`wip/JS_INTEGRATION_DESIGN_PREP.md` holds the design detail. The shared
boundary payload vocabulary and `Capability` ownership model now exist and are
the required reuse points; subscriptions must not introduce a second payload
format. The shipped `Html.behavior` marker remains an element-scoped browser
widget hook and must not become the subscription or app-port route table. The
current browser stance is one Wasm instance per active mount, so promoted
subscription or interop source ids and handlers should be registered on the
owning `SignalsRuntime` rather than in global JS registries. `Signal.interval` is
shipped as a timer/effect source, not public `Sub` surface.

First promotion trigger: name one maintained app or focused canary and one small
built-in browser subscription, such as online, visibility, or media-query state,
that proves lifecycle, payload, stale-message, cleanup, and work-budget
semantics. Treat `Signal.interval` as lifecycle prior art only. Keep app-specific
ports-like channels and broad browser source catalogs out of the first slice
unless the same trigger proves they are required.

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

### 3. HTTP production hardening, gated on proven app or canary need

**Goal:** close the remaining gaps between the shipped package-aligned HTTP
slice and production expectations, promoting each item only when a maintained
app or focused canary proves the gap.

Current state: the shipped package-aligned HTTP evidence is summarized in
`wip/research/http_effects_evidence.md`. It covers the `roc-lang/http` 0.1
package pin, request/response envelopes, timeout/body/header transport, ordered
duplicate response-header pairs, narrow browser `fetch` mapping under browser
defaults, `HttpError` classification, task cancellation and stale-result
suppression, task lifecycle telemetry, maintained app canaries, and browser
HTTP/router contract tests. Current routing still uses task names with the
`http:send:` prefix.

First promotion trigger: name one maintained app or focused canary and one
specific production gap. Keep the promoted slice narrow: explicit abort must
prove user-driven cancellation distinct from scope disposal or request
replacement; effect capability routing must be co-designed with priority 2; JSON
or body helpers must prove builtin `Json` plus request/response envelopes are
not enough; browser fetch-policy knobs must prove a maintained app or focused
canary needs host control beyond the current browser defaults.

Candidate items:

- Explicit user-driven abort, distinct from scope disposal.
- Typed effect capability registry replacing the current `http:send:` task-name
  prefix routing only after priority 2 proves the shared task/subscription routing
  model.
- JSON body decode helper layer only if a maintained app or focused canary proves
  the compiler builtin `Json` API is not enough.
- Browser fetch-policy controls such as credentials, redirect, mode, cache, or
  referrer policy only when a maintained app or focused canary needs host
  control beyond browser defaults.

### 4. Form/input hardening, gated on proven app or canary need

**Goal:** extend beyond the shipped controlled input/forms milestone only when a
maintained app or focused canary proves a concrete browser-form gap.

Current state: the shipped controlled input/forms evidence is summarized in
`wip/research/form_input_evidence.md`. It covers guarded `SetValue`
reconciliation for focused/composing text inputs, signal-backed text input,
number draft input, textarea, checkbox, single-value select/option helpers,
string-valued radio helpers, action-button disabled state, submit/reset default
action coverage, focused optional text attrs, required/readonly/ARIA validation
attrs, and the documented validation pattern.

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

### 5. Structural/design-gap backlog

Feature work above should not bury a core propagation or scaling gap when a metric
shows a `design.md` budget is violated. The following remain eligible, but should
be promoted only with current measurements.

First promotion trigger: name the violated `design.md` budget, the current
counter or benchmark that proves it, and the smallest representative app or
focused fixture that reproduces it. The promoted slice must preserve existing
O(1) lookup and local-splice discipline; do not trade long-session memory
plateaus for scans or broad rebuilds.

#### Long-session plateau gate

Current state:

- The native plateau and dirty-queue evidence is summarized in
  `wip/research/long_session_plateau_evidence.md`. It currently covers repeated
  event dispatch, dirty keyed-row reorder churn, bounded row removal/reinsert,
  nested branch-scope churn, retained allocation/table lengths, dirty-queue
  reachability/rank ordering, source-route deduplication, diamond convergence
  deduplication, and dirty propagation scratch capacities.

Result:

- Slot reclamation is in place for the dense tables proven by the simple and
  nested removal/reinsert gates.

#### Slot reclamation for monotonic identity tables

Current state: inactive each-row scope slots, state cells, node identities, DOM
identities, native simulated DOM element slots, component scopes, and `when`
branch scopes are reused in the plateau gates linked above.

Still eligible only with a new failing measurement:

- Preserve O(1) lookup discipline for id-indexed reads; do not fix memory by
  reintroducing scans on hot lookup paths.

#### Measured command-wire string dedupe

Keep as a hypothesis, not active work.

- Browser command telemetry reports fixed-record bytes, fixed-string bytes,
  dynamic-buffer bytes, and apply-path decode counts/bytes for fixed strings,
  dynamic records, dynamic strings, and dynamic byte arrays. The static framing
  estimate remains in `wip/research/wire_protocol_dynamic_size_estimate.mjs`,
  the latest live mount snapshot is in
  `wip/research/command_wire_live_mount_telemetry.md`,
  and built wasm apps can be sampled after
  `python3 scripts/test.py wasm --keep-output` with
  `node scripts/browser/mount_wasm_example.mjs .test-out/wasm/<slug>.wasm <slug> --telemetry-summary`.
  When refreshing the public-app snapshot, repeat the mount command for every
  current `public = true`, `wasm = true` entry in `www/data/examples.toml`.
- Promote only if representative action telemetry, not just mount snapshots,
  shows fixed/dynamic string traffic is larger than the remaining structural tail
  and the proposed dedupe lowers total command/decode bytes without adding broad
  Roc value interning.
- Do not globally intern Roc strings, `HostValue`s, keys, or capability-owned data.

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
