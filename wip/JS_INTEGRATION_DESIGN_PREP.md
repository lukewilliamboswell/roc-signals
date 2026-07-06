# JS Integration / Subscriptions Design Prep

Working note for JavaScript integration in the Signals UI framework. The first
dedicated browser-source canaries (location, visibility, and online/offline)
have shipped without exposing a generic public `Sub` surface. This note keeps
the plan shape, requirements, research notes, and open questions for future
generic `Sub`s, app-specific JS interop, and browser mounting if a maintained
app or focused canary promotes the deferred `wip/NEXT_STEPS.md` priority.

The browser-environment surface that consumes the focused browser-source
machinery (startup snapshot, location/history, visibility, online/offline, and
storage) is designed in `wip/BROWSER_ENV_DESIGN_PREP.md`; this note owns the
generic subscription machinery: descriptors, identity, generations, lifecycle,
and the payload producer.

Refresh check: re-run on 2026-07-05 with the focused browser integration gate:
`node --test --test-name-pattern "behavior lifecycle|protocol checks|timer|task|clear_event|remove_node" scripts/browser/runtime_contract.test.mjs`.
It passed 16/16 for behavior lifecycle, protocol checks, timer/task bridges,
HTTP task routing, and listener cleanup. The browser-source-specific
location/storage/visibility/online/title spot-check is recorded in
`wip/BROWSER_ENV_DESIGN_PREP.md`. Current behavior/mounting claims below
remained green; subscriptions and app-specific interop remain unpromoted.

## Why This Exists

`design.md` now keeps `Sub(a)` out of the shipped app-facing API and records the
enduring rule future subscriptions must follow: subscriptions are declared by
structure, owned by scopes, diffed by the host, and started/stopped by lifecycle.
That direction is useful, but it is not enough for implementation or
production-readiness.

Real web apps need long-lived browser and JS resources:

- browser location/history route changes (popstate);
- WebSocket / EventSource streams;
- local/session storage events;
- browser online/offline status;
- visibility/focus/media-query state;
- third-party widgets and app-specific JS services;
- analytics or host-shell integration;
- multiple mounts or embedded widgets on one page.

These are not one-shot HTTP tasks. They need explicit subscription ownership,
lifecycle, test fakes, and boundary rules. Elm's ports are useful prior art for
this problem, but Signals should not copy Elm mechanically; it should adapt the
boundary discipline to the Signals effects-as-sources engine.

Signals already has one narrow browser integration hook:
`Html.behavior(name)` marks a DOM element for a behavior registered through
`mountSignalsApp({ behaviors })`. The runtime attaches the matching behavior
after a batch, calls behavior `update` for dynamic custom attributes, and cleans
it up on marker removal, subtree removal, or unmount. This is useful for
element-scoped browser widgets such as the service-ops chart, but it is not a
general subscription or ports surface: it is browser-only, not a retained source,
and any Roc update still comes back through declared DOM events such as
`Html.on_custom`.

## Current Coverage in `design.md`

`design.md` covers future `Sub`s only at a high level:

- `Core Concepts` says general `Sub` descriptors are deferred until a maintained
  app or focused canary needs broader inbound host messages.
- `App-Facing API` says `Sub(a)` and app-specific JS interop are future surfaces,
  not shipped API.
- `Glitch Freedom, Ordering, and Async` says future `Sub` descriptors must be
  declared by structure, scope-owned, diffed by the host, and lifecycle-managed.
- `Async in the browser` covers timers and tasks, but not a general subscription
  descriptor or app-specific interop channel.
- `Browser mounting model` defines one Wasm instance per active mount; this prep
  still needs a mount-local registration model for subscriptions and interop
  beyond the existing element-scoped behavior registry.

Missing details, intentionally unresolved until promotion:

- no concrete `Sub(a)` constructors or descriptor shape;
- no place in `Elem` / scope structure where subscriptions are declared;
- no keyed identity for subscriptions;
- no start/stop diff algorithm beyond one sentence;
- no generic subscription-side producer descriptor or concrete inbound encoding
  format beyond the dedicated browser-source payloads;
- no native fake model for generic inbound JS/subscription events;
- no app-specific interop channel comparable to Elm ports, beyond the current
  browser-only `Html.behavior` marker;
- no per-mount JS registration model for generic subscriptions or app-specific
  interop attached to the current one-Wasm-instance-per-mount browser stance.

Conclusion: the enduring design has the right direction, but the plan should not
become surface without a maintained app or focused canary. This prep doc should
feed a future `design.md` section only after that promotion trigger exists.

## Elm Ports Research Notes

Elm ports are an application-level interop boundary between Elm and JavaScript:

- outgoing ports produce `Cmd msg` values that JavaScript can subscribe to;
- incoming ports produce `Sub msg` values that JavaScript can send values into;
- payloads are limited to the types that can cross Elm's JS boundary, commonly
  JSON values for richer data;
- ports are deliberately coarse boundaries. Elm's guide recommends sending richer
  messages through a small number of ports rather than creating one port per JS
  function;
- ports are for applications, not packages, so the package ecosystem remains pure
  Elm.

The useful idea is the ownership boundary:

- Roc owns Roc app state;
- JS owns JS/browser resources that cannot or should not live in Roc;
- messages cross at a small explicit boundary;
- app-specific interop is allowed without making every JS API part of the core
  framework.

Signals should preserve that boundary discipline, but model integration using its
own primitives:

- outbound effects are explicit `Cmd`s;
- inbound events are host-owned sources/subscriptions;
- everything enters the one propagation queue;
- subscriptions are scope-owned and disposed deterministically;
- JS never decodes Roc layouts.

## Design Goals

1. **Make long-lived external resources first-class.** A subscription should be a
   retained source owned by a scope, not an ad hoc callback in JS.
2. **Keep JS thin.** JS owns browser resources and executes declared operations;
   it does not run reactive logic or reconstruct meaning.
3. **Avoid a generic unsafe FFI.** App-specific interop is useful, but it must
   cross through typed/declared channels with explicit payload formats.
4. **Keep packages portable.** Packages should not require arbitrary app ports;
   they should depend on platform capabilities or data types.
5. **Make native testing deterministic.** Every subscription type needs a native
   fake/injection path so behavior and work budgets are asserted without a real
   browser.
6. **Support multiple app instances.** JS resources, channels, listeners, and DOM
   ids must be scoped to a mount or WASM instance.

## Conceptual Model

### Subscription source

A `Sub(a)` represents a long-lived external source that can publish values of
`a`. The host starts it when its owning scope becomes active and stops it when the
scope is disposed or the declared subscription changes.

A subscription is different from a task:

- a task has one request and one success/failure result;
- a subscription may publish many values over time;
- subscription stop is normal lifecycle, not failure;
- subscription identity matters so the host can diff old vs new declarations.

### Scope ownership

Subscriptions should be declared inside explicit scopes, similar to state and
cleanup. The owner scope determines:

- when the subscription starts;
- when it is stopped;
- where retained callbacks/capabilities are released;
- which stale inbound messages must be ignored.

### Diffing declared subscriptions

On structural changes the engine should compare declared subscription descriptors
for each active scope:

- unchanged descriptor: keep existing external resource;
- changed descriptor with same construction site but different parameters: stop
  old resource and start new one;
- removed descriptor: stop old resource and release retained values;
- added descriptor: start new resource.

Diffing must not require a whole-app scan. It should follow the same structural
budget as other active-stream maintenance: O(affected scope), not O(total app).

### Inbound update path

External events enter as source updates:

1. JS/browser resource receives event/message.
2. JS encodes the declared payload into WASM-owned memory or another explicit
   boundary representation.
3. Host validates subscription id/generation and ignores stale events.
4. Host updates the subscription source value.
5. Propagation uses the same dirty queue as clicks, timers, and task results.

## Candidate App-Facing API Shapes

The exact API needs research. Possible concepts:

```roc
Sub(a)

Signal.from_sub : Sub(a), a -> Signal(a)
Ui.subscribe : Sub(a) -> Elem
```

or a component-style form that binds the subscription result to a signal source:

```roc
Ui.sub : Sub(a), (Signal(a) -> Elem) -> Elem
```

For app-specific interop, a ports-like channel could be introduced later:

```roc
Interop.Channel(a)
Interop.send : Channel(a), a -> Cmd
Interop.subscribe : Channel(a), a -> Sub(a)
```

These names are illustrative only. A promoted slice may use a focused built-in
source surface without stabilizing a generic public `Sub(a)` API; keep the
generic API deferred until repeated canaries prove it. The design must account
for Signals' current `Elem`-driven app shape, scoped identity, retained
callbacks, and confined erasure.

## Built-In Subscription Candidates

Do not start by building every browser API. Use the smallest set that proves the
model:

- `Signal.interval` is shipped as a timer/effect source, not as public `Sub`
  surface. Treat it as lifecycle prior art for start/stop/unmount behavior, and
  only fold it into shared subscription internals if the promoted slice proves
  that reuse lowers complexity without changing the app-facing API.
- The browser location source (popstate route changes) was the named first
  canary. Its app-facing surface is designed in
  `wip/BROWSER_ENV_DESIGN_PREP.md` and promoted through the browser-environment
  priority in `wip/NEXT_STEPS.md`; this note owns the machinery it rides.
- The second canary has landed on the same machinery:
  `Browser.visibility` for the `service-ops-center` polling-pause expansion.
- The third canary has landed on the same machinery:
  `Browser.online` for the `live-search` offline expansion.
- Later canaries on the same machinery: `Browser.media_query : Str -> Sub(Bool)`
  when an app proves parameterized restart, cross-tab storage events if storage
  sync becomes app-visible, or app-specific interop if a maintained app needs an
  escape hatch.

Keep broader browser source catalogs deferred until a maintained app or focused
canary proves they are needed beyond the dedicated browser-source
lifecycle/payload path. Examples:

- `WebSocket.messages : WebSocketConfig -> Sub(WebSocketEvent)`;
- `Storage.changes : StorageArea -> Sub(StorageEvent)`; the cross-tab scope
  decision is recorded in `wip/BROWSER_ENV_DESIGN_PREP.md`.

The first promoted slice was the browser location source, which proved the
initial lifecycle and payload semantics before the visibility and online
canaries reused the same path. Add an app-specific interop channel only if the
promoting maintained app or focused canary needs the escape-hatch shape.

## App-Specific JS Interop

A ports-like interop layer should be reserved for cases where a capability is
app-specific rather than platform-general. Examples:

- integrating a chart/map/editor widget;
- analytics or host-shell messages;
- app-specific storage/service-worker messages;
- temporary experiments before promoting a capability into the platform.

Requirements:

- channels are declared explicitly by the Roc app;
- JS handlers are registered at mount time, not discovered dynamically by Roc;
- payload format is platform-owned and layout-independent;
- inbound messages are tied to subscription ids and generations;
- outbound commands are batched through the host boundary, not direct JS calls
  from Roc;
- native specs can fake inbound and outbound messages;
- channels are scoped to a mount and cleaned up on unmount.

Non-goals:

- exposing arbitrary JS function calls to Roc;
- letting JS mutate engine state outside declared source updates;
- making framework packages depend on application interop channels;
- making the browser runtime a reactive runtime.

## Payload Boundary

This question is now settled in direction: the shared boundary vocabulary
shipped for event payloads as schema tags embedded in `Node.EventExtractionPlan`
bytes. `src/signals/boundary.zig` parses and validates those bytes, currently
covering unit, text, bool, and non-empty records of primitive leaves.
Subscriptions and interop payloads must reuse that vocabulary rather than
introducing a JSON-like or string-only format.

Remaining payload work when subscriptions are promoted:

- define the subscription-side producer descriptor (the analogue of the DOM
  `EventExtractionPlan`) for host/JS-originated messages;
- add new leaves or containers only when a subscription canary needs them,
  with the same fail-closed validation and diagnostics as event extraction;
- keep typed decoding in Roc-provided capabilities; hosts move bytes/scalars
  only.

Event payloads, interop payloads, and subscription payloads must not become
three unrelated formats.

## Multiple Mounting

`design.md` now treats one Wasm instance per active mount as the current
production stance. The wasm host state is module-global inside an instance, and
`mountSignalsApp` creates a fresh instance per root. Multiple roots on a page are
therefore multiple `WebAssembly.Instance` values, each with its own
`SignalsRuntime`.

This question is part of JS integration because subscriptions and interop need
mount-local ownership:

- DOM ids are per mount;
- event ids are per mount;
- subscription ids/generations are per mount;
- interop channels are per mount;
- JS cleanup on unmount must release listeners, intervals, sockets, and widget
  resources for only that mount.

Options:

1. **Current stance: one WASM instance per mount.**
   - simplest engine model;
   - easy resource isolation;
   - aligns JS registries with one `SignalsRuntime`;
   - heavier memory/startup for pages with many tiny widgets.
2. **Deferred alternative: one WASM instance with explicit mount handles.**
   - better if many-widget embedding measurements prove per-instance overhead is
     too high;
   - requires every host export to take a handle;
   - forces all command buffers, ids, and JS registries to be mount-scoped.

Interop channels should target the current stance first: register handlers and
source ids on the `SignalsRuntime` / Wasm instance that owns the mount. Do not
design global channel registries that would make a future handle-based model
harder to introduce.

## Browser Runtime Requirements

- Keep a per-mount subscription registry.
- Start/stop browser resources from explicit host commands or effect/subscription
  descriptors.
- Use generation/request tokens so late messages after stop are ignored.
- Encode inbound payloads without reading Roc layouts.
- Refresh WASM memory views after host calls that may allocate.
- Run cleanup on `roc_ui_unmount` for every live subscription and interop channel.
- Expose registration hooks for app-specific JS handlers without giving them
  direct access to engine internals.
- Keep the existing `data-signals-behavior` registry element-scoped; do not reuse
  it as the subscription or app-port route table.
- Record telemetry for subscribe/start, message, stop, ignored-late, handler
  error, and unmount cleanup.

## Native Host Requirements

- Deterministic fake subscriptions.
- Spec commands to send inbound subscription values by semantic name or declared
  test id.
- Assertions for start/stop counts and ignored-late events.
- Work metrics proving subscription diffing is bounded by changed scopes.
- Teardown assertions that retained callbacks/values and external-resource records
  are released.

## Relationship to HTTP / Effects

HTTP remains a first-class task capability using `roc-lang/http` types. It should
not wait for app-specific interop.

Shared concerns:

- request/subscription ids and generations;
- cancellation/stop semantics;
- payload boundary format;
- native fake infrastructure;
- browser telemetry;
- effect capability registry.

The typed effect capability registry in `wip/NEXT_STEPS.md` should be designed
with subscriptions, because both tasks and subscriptions need owned ids,
generations, payload validation, native fakes, and browser telemetry. It should
replace the current HTTP `http:send:` task-name prefix routing only when that
shared registry has a subscription or interop canary to prove the
task/subscription routing model.

Different concerns:

- HTTP is one-shot and returns `Done`/`Failed`;
- subscriptions are long-lived and publish many values;
- ports-like interop is app-specific and should not shape package-level HTTP.

## Promotion Validation Plan

Original focused-source trigger: the browser location source (popstate route
changes) named in the browser-environment priority of `wip/NEXT_STEPS.md` was
the first focused canary. It had to prove lifecycle, payload, stale-message,
cleanup, and work-budget semantics on this note's descriptor design. The routed
`service-ops-center` workflow was the maintained app that drove it.

Current status: the browser location canary has landed through the
browser-environment implementation slice: startup seeding, push/replace
commands, live popstate updates, stale/unmounted telemetry, native history
primitives, focused Wasm fixture exercises, and the `service-ops-center`
route/back-forward workflow are in place. The focused location fixtures prove
seeded URL pieces, popstate updates, Back/Forward, command-backed replace, and
popstate listener cleanup through the same Wasm mount gate used by the public
apps. The second focused canary, `Browser.visibility`, has also landed: native
and Wasm hosts seed/update a one-byte boundary payload, the JS runtime
installs/removes a per-mount `visibilitychange` listener with stale-generation
telemetry, and `service-ops-center` pauses interval polling while hidden and
starts a catch-up request when visible again. The third focused canary,
`Browser.online`, has landed through `live-search`: it seeds/updates the same
one-byte payload shape from `navigator.onLine` and `online`/`offline` events,
suppresses task starts while offline, re-runs the current query when online
returns, and proves branch-scoped cleanup when the panel closes.

Done for the first three focused browser-source canaries: the browser location
source landed through the browser-environment priority, `Browser.visibility`
landed through the service-ops polling-pause expansion, and `Browser.online`
landed through the live-search offline expansion. Use `Signal.interval` only as
lifecycle prior art unless a later promoted source proves shared internals are
the smaller route.

For a future generic subscription or app-specific interop slice, add focused
coverage for the missing generalization points:

- Native semantics for descriptor retention and restart: unchanged descriptors
  do not restart, parameter changes restart, scope disposal stops, late
  messages after stop are ignored, and retained values are released at teardown.
- Browser contract coverage for generic registration or handler dispatch:
  subscribe/start or handler registration, inbound payload encoding, stop and
  unmount cleanup, stale generation ignored, and handler error telemetry.
- A tiny app-specific interop spike only if needed: one outbound command
  channel, one inbound subscription channel, JS registration at mount, and
  native fake coverage.
- Validate the current one-Wasm-instance-per-mount strategy before stabilizing
  JS handler registration; revisit explicit mount handles only with many-widget
  measurements.

## Focused Gates

For prep-only edits that do not change current behavior claims, run:

```sh
git diff --check
zig build run-check-tidy
```

For edits that change current browser-integration claims around
`Html.behavior`, mounting, timers, tasks, or runtime cleanup, run the focused
browser contract coverage:

```sh
node --test --test-name-pattern "behavior lifecycle|protocol checks|timer|task|clear_event|remove_node" scripts/browser/runtime_contract.test.mjs
```

When the priority is promoted into a concrete implementation slice, use the
smallest gate that proves the slice, then the repository gate before committing.
A promoted subscription slice should include at least:

```sh
python3 scripts/test.py native --native always
zig build run-test-browser
python3 scripts/test.py roc-check
```

Add `python3 scripts/test.py bench --native always` when subscription diffing or
work-budget claims change, and `python3 scripts/test.py wasm` when wasm/app
build coverage changes.

## Outstanding Questions

- What is the concrete `Sub(a)` app-facing API and where is it declared in the
  `Elem` tree?
- Which later source or interop canary, if any, proves that the internal
  dedicated browser-source path should become a public `Sub` shape?
- What identity key does a subscription use: construction site, explicit channel
  name, parameters, or a host-generated descriptor id?
- How are subscription parameter changes detected without app-authored equality
  footguns?
- What subscription-side producer descriptor should reuse the existing shared
  boundary vocabulary for host/JS-originated messages?
- What ergonomic app-specific interop API can expose that shared vocabulary
  without falling back to string-only or JSON-like channels?
- Are ports-like channels application-only, package-usable, or explicitly outside
  package contracts?
- Should outbound interop messages be `Cmd`s, command-buffer ops, or a separate
  effect channel?
- How do inbound interop messages identify their target source inside the owning
  `SignalsRuntime`?
- What many-widget memory/startup measurement would justify revisiting explicit
  same-instance mount handles?
- What JS handler registration API should the browser runtime expose for
  subscriptions and ports beyond the existing behavior registry?
- How are handler errors surfaced: console telemetry, failed source value,
  diagnostics, or app-visible errors?

## Suggested Next Promoted Slice

The first three focused browser-source canaries have landed without exposing a
generic public `Sub` surface: location/popstate, visibilitychange, and
online/offline. Keep generic `Sub` deferred until a parameterized source,
cross-tab storage events, or app-specific interop proves the app-facing shape.

If another subscription slice is promoted, it should use a maintained app or
focused fixture to prove the missing generalization point directly:
unchanged-descriptor retention, parameter restart, source diffing across
dynamic descriptors, and browser handler error telemetry outside the dedicated
browser-source paths.
