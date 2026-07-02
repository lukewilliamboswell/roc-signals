# Signals — Next Steps

This file is the active backlog. It should contain only unfinished work and the
current ordering. Completed phase notes, benchmark snapshots, and retired findings
belong in git history or focused design notes, not here.

## Direction

The next phase should reduce the number of public concepts, not grow the API in
order to preserve every historical path. Prefer one small, typed boundary model
that attributes, event payloads, subscriptions, app interop, and structured effect
results can share.

Guiding rules:

- Do not add duplicate public helpers when a smaller core API plus focused sugar is
  enough.
- Do not keep compatibility APIs as permanent design inputs. Compatibility shims are
  temporary migration tools and should have an explicit removal path.
- Keep JS and native hosts as boundary executors. Roc describes explicit data; hosts
  execute descriptors and report diagnostics.
- Prefer typed descriptors over public bit flags or ad hoc stringly protocols.
- Add surface only when a maintained app or focused canary proves the need.
- When a design prep item has shipped, remove it from this backlog instead of
  keeping it as a completed task.

## Active priority order

### 1. Boundary model consolidation

**Goal:** define the smallest shared boundary model that can carry typed data
between Roc and hosts without creating one-off formats for events, subscriptions,
JS interop, and structured effects.

This should happen before broadening event propagation, because event payloads and
dynamic event responses are only one consumer of the boundary.

Deliverables:

- Define a minimal shared `BoundarySchema` / `BoundaryPayload` family for:
  - unit;
  - bool;
  - text;
  - integer / float scalars only if a real canary needs them;
  - non-empty records of primitive leaves.
- Define `EventExtractionPlan` as a DOM-specific producer of that boundary payload,
  not as an event-only payload format.
- Reuse the same boundary vocabulary for future subscription/app-interop payloads.
- Keep Roc layout opaque to JS and Zig. Hosts may move bytes/scalars and invoke
  app-compiled capabilities/decoders; they must not decode arbitrary Roc layouts.
- Extend the current error model for extraction/validation failure across hosts:
  - deterministic diagnostic, preserving JS `event_payload_error` telemetry for
    event extraction failures;
  - no reducer delivery for that handler;
  - no silent fallback to DOM inference.
- Audit the existing public API and mark compatibility-only pieces for removal or
  replacement by the smaller boundary API.

Non-goals for this slice:

- No generic public `Sub` API yet.
- No app-specific JS channel yet.
- No dynamic event response API yet.
- No broad catalog of event payload leaves. Add leaves only for a canary.

Validation:

- Any new boundary leaf/container addition must include one focused app/spec
  canary, JS contract coverage for encoding/validation/extraction failure, and
  native spec coverage for the semantic result without duplicating browser quirks.

### 2. Public API shrink pass

**Goal:** make the current public surface trend toward one core API plus small
sugar, rather than parallel fixed/named/compatibility paths.

Deliverables:

- Keep `wip/PUBLIC_API_SHRINK_AUDIT.md` current whenever the public surface
  changes.
- Keep fixed event helpers and named events lowering through the same
  `Node.EventBinding` shape while preserving fixed-event compression until
  measurements say it can be removed.
- Remove or avoid reintroducing public raw ids, listener bitmasks, and duplicate
  helper families when a slice touches that surface.
- Reflect any removed or renamed surface in docs/examples in the same slice.

Validation:

- Existing maintained examples still check/build.

### 3. Reframe event propagation on top of the boundary

**Goal:** implement event propagation policy as descriptor data over the shared
boundary, not as another event-specific API family.

Prerequisite: Priority 1 has a settled minimal boundary payload format.

Deliverables:

- One canonical event descriptor internally. Fixed hot event opcodes may remain as
  compression only, not as a separate semantic path.
- Handler-level policy and payload:
  - static prevent default;
  - static stop propagation;
  - static stop immediate propagation;
  - capture/bubble phase;
  - passive/active listener choice;
  - `once`;
  - `self`/`trusted` filters.
- Delivery derivation:
  - `Node.EventBinding` now carries a typed delivery request through the Roc ABI;
  - host-facing Zig event bindings now carry requested/effective delivery and a
    native-delivery reason derived before render-cache storage/sink dispatch;
  - browser runtime still derives the same current `Auto -> Native` decision from
    existing command fields for command-wire telemetry because delivery is not yet
    encoded in render commands;
  - public request starts with `Auto` and `Native` only, exposed through the
    low-level `Html.on_event_delivery` path;
  - delegated delivery remains an internal optimization until there is a proven
    need to expose it;
  - native is forced for semantics delegation cannot reproduce;
  - remaining work is to encode delivery through the browser command wire when the
    canonical host descriptor replaces the fixed/named split.
- Continue extending native spec coverage beyond the current `real_click`
  primitive. Capture/bubble and static stop/stop-immediate policy now have
  focused native runner coverage; `release-planner` has a nested note-button
  canary proving stop-propagation prevents card drag startup during a real click;
  submit dispatch has focused coverage for static prevent-default and disabled
  targets; and `self`/`trusted` filters are encoded in typed policy and covered
  in browser/native runner tests. Remaining gaps include broader default-action
  modeling where relevant.

API discipline:

- Do not add `on_pointer_down_stop_propagation`-style helper names.
- Do not add a second payload-description system for events.
- Do not expose DOM event objects to Roc.
- Keep high-level helpers as sugar over the canonical descriptor.

Validation:

- Preserve the `release-planner` nested-control/drag canary: `real_click` on the
  card note button must increment the note without starting a drag.
- Native spec coverage should be added for any new propagation/default-action
  semantics beyond the current capture/bubble, stop/stop-immediate, submit, and
  `self`/`trusted` cases.
- JS contract tests should cover any new listener option or event response timing
  behavior; current coverage includes static default/propagation policy,
  `self`/`trusted` filters, listener options passed to `addEventListener`,
  delivery telemetry for current `Auto -> Native` derivation, and response-bit
  timing. Zig render-cache coverage now verifies descriptor-level delivery
  derivation before storage and sink dispatch.

### 4. Dynamic event response, only if needed

**Goal:** support expert cases where event response depends on event payload or app
state, without taxing ordinary handlers or adding duplicate APIs.

Prerequisites:

- Shared boundary payloads are implemented.
- Static event policy is implemented over canonical descriptors.
- A real maintained app or canary needs state-dependent response.

Deliverables:

- Dynamic response only through explicit `state.on_event`-style handlers that return
  both next state and `Event.Response`.
- Response bits are applied synchronously before the JS listener returns.
- Ordinary `on_unit` / `on_value` handlers remain static-policy only.

Non-goals:

- No separate payload-only dynamic response API unless repeated code proves it is
  worth adding as sugar.
- No async/task-based event response; browser event policy must remain synchronous.

### 5. Subscriptions and app-specific JS interop

**Goal:** add broader inbound host messages only after the boundary model is proven
by events/effects and a real example needs the surface.

Deliverables when promoted:

- Mount-scoped source ids and generations.
- Start/stop/unmount cleanup semantics.
- Shared boundary payload decoding.
- Stale-message diagnostics.
- Native spec injection primitives that model semantics without becoming a browser
  clone.

Keep deferred until needed:

- Public generic `Sub` API.
- Ports-like app-specific JS channels.
- Browser source catalogs beyond focused canaries.

### 6. Structural/design-gap backlog

Feature work above should not bury a core propagation or scaling gap when a metric
shows a `DESIGN.md` budget is violated. The following remain eligible, but should
be promoted only with current measurements.

#### Persistent rank-ordered propagation queue

Design gap, not cosmetic optimization.

- Replace per-event fresh dirty worklists and sorting with the single rank-bucketed
  dirty queue described by `DESIGN.md`.
- Reuse existing generation stamps for deduplication.
- Know it worked when propagation results stay identical and per-event dirty-list
  allocations drop to zero after warmup.

#### Long-session plateau gate

- Reuse one host environment across sustained churn.
- Assert retained allocation/table sizes plateau after warmup.
- Use this before promoting free-list or slot-reclamation work.

#### Slot reclamation for monotonic identity tables

Promote only if the long-session gate shows monotonic growth that matters.

- Candidate tables: scopes, node identities, DOM identities, dense id-indexed side
  tables.
- Preserve O(1) lookup discipline; do not fix memory by reintroducing scans.

#### Measured command-wire string dedupe

Keep as a hypothesis, not active work.

- Add byte/decode counters first.
- Promote only if fixed/dynamic string traffic is larger than the remaining
  structural tail in representative apps.
- Do not globally intern Roc strings, `HostValue`s, keys, or capability-owned data.

#### Additional scratch/arena work

Promote only when named counters identify a specific transient buffer still worth
moving.

- Keep Roc heap allocations and host-internal scratch separate.
- Do not move boxed Roc values or refcounted data into per-cycle scratch storage.

## Green Gates

Use the smallest gate that proves the slice, then run the full signal gate before
committing. For a pure refactor slice the existing native specs are the regression
guard; a behavior-changing slice must also land the assertion that locks it in.

- Pre-commit tidy gate:
  `zig build run-check-tidy`
- Focused Zig host/engine work:
  `zig build run-test-zig -- --test-filter "native_host"`
- Shared engine instantiates under wasm32:
  `zig build build-test-hosts -Doptimize=ReleaseSmall`
- Platform Roc or ABI changes:
  `roc check examples/<app>/app.roc`
- Focused wasm/app build regression:
  `python3 scripts/test.py wasm`
- Zig-only checks and tests:
  `zig build test`
- JS↔WASM contract guards:
  `zig build run-test-browser`
- Browser host + apps build, both backends:
  `python3 scripts/serve.py --no-server --app-opt dev`
  `python3 scripts/serve.py --no-server --app-opt size`
- End-to-end repository gate:
  `python3 scripts/test.py`

For doc-only updates, `git diff --check` is enough.
