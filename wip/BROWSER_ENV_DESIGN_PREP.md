# Browser Environment Design Prep

Historical working note for the browser environment surface in the Signals UI
framework: the startup environment snapshot, browser location/history,
visibility, online/offline status, document-title commands, and browser
storage. The shipped API and enduring behavior now live in `design.md` and the
app-author guide; this note keeps the slice rationale, validation detail, and
open follow-up questions for the browser-environment priority in
`wip/NEXT_STEPS.md`.

The generic subscription machinery (descriptors, identity, generations,
lifecycle, payload producer) is owned by `wip/JS_INTEGRATION_DESIGN_PREP.md`;
this note owns the browser-environment surface that consumes it. The
motivating analysis is `wip/research/realworld_gap_analysis.md`.

Refresh check: re-checked 2026-07-05 after the browser-environment phases
landed. Re-check the current-state claims (entry contract, mount sequence, and
remaining deferred list) whenever the platform ABI, `platform/main.roc`, or the
browser runtime mount path changes. Focused browser contract spot-check:
`node --test --test-name-pattern "location|storage|visibility|online|document title|mount seeds" scripts/browser/runtime_contract.test.mjs`
passed 15/15 for the current location, storage, visibility, online/offline,
document-title, and startup snapshot claims.

## Why This Exists

A RealWorld-class SPA needs an honest browser environment:

- the first render must reflect the real initial URL and any persisted
  session, not a fake default patched after mount;
- deep links must mount the right view directly;
- back/forward must work through popstate;
- programmatic navigation must update the URL without a reload;
- route-derived document titles must be explicit effects, not hidden router
  behavior;
- background tabs and offline state must be observable when app work depends on
  them;
- drafts and sessions must persist across reloads through browser storage.

At creation, none of this existed. The first location/history slice now exists:
`Browser.location`, push/replace commands, live popstate updates, native
history spec primitives, and a routed `service-ops-center` workflow are
implemented. The storage foundation now exists through declared local/session
text sources, write/remove commands, native storage spec primitives, and Wasm
startup reads seeded by the runtime's prepared-mount discovery pass. The
maintained `team-checkout` persistence workflow now proves restore, write, and
clear behavior. The service-ops route workflow now proves explicit
document-title updates through `Browser.set_title` and visibility-aware
polling through `Browser.visibility`; `live-search` proves online/offline task
gating through `Browser.online`. App-visible recovery from failed write
commands remains deferred.

## Current Coverage in `design.md` and the Repository

- `platform/main.roc` still requires `main : () -> Elem`; host-owned seeded
  sources provide the first environment values without changing the app entry
  contract.
- Mounting keeps the `main()` entry shape; `SignalsRuntime.mount()` seeds
  host-owned environment payloads before the first render so sources such as
  `Browser.location` can reflect the real startup state.
- `design.md` treats one Wasm instance per active mount as the production
  stance; per-mount ownership is the established registration model.
- `Signal.interval` is the shipped prior art for a host-backed source with a
  token, start/cancel commands, and per-mount cleanup.
- HTTP tasks prove the command/task boundary with request ids, cancellation,
  and stale-result suppression.
- Link clicks can already be intercepted with the shipped `prevent_default`
  static event policy.

Still missing or intentionally deferred:

- no app-visible storage write-failure recovery path yet; the current
  validation is recorded in
  `wip/research/storage_command_result_evidence.md` and keeps this behind a
  broader command/effect-result design.

## Design Goals

1. **Honest first render.** The first frame reflects the real initial
   environment; no render from fake defaults patched after mount.
2. **Typed environment, no flags bag.** Initial values cross the boundary as
   declared typed values, not an untyped JSON blob.
3. **Per-mount ownership.** One environment snapshot per active mount, owned
   by the mounting `SignalsRuntime`; no global registries.
4. **One payload vocabulary.** Inbound values reuse the shared boundary schema
   tags; outbound navigation, document-title, and storage commands ride the
   existing command boundary.
5. **Deterministic native fakes.** Every capability gets native injection and
   assertion primitives so semantics and work budgets are asserted without a
   browser.
6. **Hosts stay boundary executors.** Roc describes browser effects and sources
   as explicit data; hosts execute descriptors and report diagnostics.

## Conceptual Model: Startup Snapshot

The snapshot is the typed set of browser-environment values captured once per
mount, before the first render:

- location pieces (path, query, hash);
- visibility and online/offline state;
- declared storage reads (specific keys/areas the app asks for, not a
  whole-store dump).

Two decisions dominated the promoted design:

**Sync-only versus task-backed.** Location and Web Storage are synchronous
browser APIs, and visibility/online state are synchronously readable from the
browser environment, so the shipped snapshot is synchronous and avoids forcing
Loading states onto the first paint. Task-backed reads would reuse the existing
task path but reintroduce render-then-patch for values that are cheaply
available. Anything genuinely async stays a task.

**Impact on `main : () -> Elem`.** The shipped design keeps
`main : () -> Elem` and exposes platform-provided sources/values seeded from the
snapshot. Changing the app contract to `main : Env -> Elem` would still be a
platform-ABI change: every example, the public guide,
`wip/PUBLIC_API_SHRINK_AUDIT.md`, and the `roc-check` gate would move in the
same slice. That future slice must never be treated as small and would need to
define how the native spec runner injects the environment under the new shape.

Post-mount environment changes are not snapshots: they arrive as source
updates (popstate, visibilitychange, online/offline, and any future storage
events) through the subscription path.

Decision for the first promoted slice: keep `main : () -> Elem` and introduce
typed, host-owned environment sources seeded from a synchronous per-mount
snapshot. This avoids an ABI-wide `main : Env -> Elem` migration while still
letting the first structural render read the real initial location, visibility,
online state, and declared storage values. The typed values are not an untyped
flags bag: the location source yields a `Location` record, visibility yields
`Browser.Visibility`, online yields `Bool`, and storage sources yield
declared-key result values. The native runner injects the host snapshot before
descriptor ingestion; the JS runtime captures it before the first command
drain. A future `main : Env -> Elem` shape stays available only if repeated
evidence shows descriptor-declared sources cannot express required startup
data.

## Conceptual Model: Location and History

- The host supplies the current location as raw text pieces (path, query,
  hash). `path` is the URL pathname with its leading `/`; `query` omits the
  leading `?`; `hash` omits the leading `#`. Route parsing, pattern matching,
  and route tables are app/package land; the platform does not ship a router
  DSL.
- The initial location comes from the startup snapshot. Live updates arrive
  through popstate as the first promoted focused browser source, using the
  descriptor/id/generation/lifecycle design in
  `wip/JS_INTEGRATION_DESIGN_PREP.md` without exposing a generic public `Sub`.
- pushState/replaceState are explicit commands through the existing command
  boundary. push and replace stay distinct so redirects do not pollute
  history.
- Ordering guarantee: a location update propagates and its resulting commands
  drain in the same turn, so the URL and the rendered page never diverge
  between turns. Scope teardown/creation on a view switch stays app land
  (`Ui.when` / `Ui.each`); the platform guarantees update ordering, not view
  semantics.
- In-app links keep `href` for accessibility and middle-click, and intercept
  plain clicks with the shipped `prevent_default` static policy; the handler
  updates state and issues the navigation command in the same event turn.
- `Browser.set_title` is a separate command, not an implied part of location.
  Apps derive titles from route or domain state and emit them explicitly.

## Conceptual Model: Storage

- Startup reads are declared keys/areas resolved into the snapshot, with
  honest absence semantics (missing key versus present-empty versus
  malformed).
- Writes and removals are explicit commands through the command boundary,
  coalesced per drain so text input does not emit one write per keystroke.
- Read failures are surfaced typed: unavailable storage (privacy mode,
  security error) and malformed values map to app-visible states, not console
  noise.
- localStorage and sessionStorage are distinct declared areas.
- Storage keys need per-app/mount namespacing: all public examples share one
  origin on the public site, so collisions are real today. Namespacing stays in
  app/package code; the platform reads, writes, and removes the exact keys an
  app declares.
- Stored values are text; apps encode with builtin `Json` or `Str`. No
  serialization framework in the platform.
- Cross-tab storage events are a recorded open question; if adopted they ride
  the subscription machinery, never a second inbound path.

## Payload and Command Boundary

- Inbound snapshot and source values reuse the shared boundary schema
  vocabulary (unit, text, bool, records of primitive leaves) validated in
  `src/signals/boundary.zig`; add leaves only when a canary needs them, with
  the same fail-closed diagnostics as event extraction.
- First landed sub-contract: location payloads are the schema-only
  `{ path : text, query : text, hash : text }` record encoded as bytes in that
  field order. Zig exposes `SchemaTag.location_schema` plus
  `encodeLocationPayload`; JS exposes `LocationBoundarySchema`,
  `locationSnapshotFromHref`, and `encodeBoundarySchemaPayloadBytes`.
- Second landed sub-contract: `Browser.location : Signal(Location)` consumes
  that payload through `Node.SignalExpr.LocationSource`. The signal record and
  engine retain the source token, payload capability, decoder callable, and
  typed location capability; the JS runtime captures the mount's current
  location and calls `roc_ui_set_location` before `roc_ui_mount`; the native
  spec runner can pre-seed the fake environment with `set_initial_location`.
- Third landed sub-contract: `Browser.push_state` and `Browser.replace_state`
  widen `Node.Cmd` with explicit navigation variants. Native and Wasm hosts
  execute those variants through the command boundary, update the host current
  location payload, and refresh active `Browser.location` sources in the same
  engine turn.
- Fourth landed sub-contract: live updates for the dedicated location source
  enter through `roc_ui_update_location`. `SignalsRuntime` owns a per-mount
  `popstate` listener, encodes the current URL pieces with the same location
  payload schema, drains resulting commands in the popstate host-call turn,
  removes the listener on unmount, and records ignored stale/unmounted
  dispatch telemetry.
- Fifth landed sub-contract: the native spec runner owns a deterministic
  fake history stack. `navigate`, `history_back`, `history_forward`,
  `expect_current_location`, and `assert_current_location` update/assert the
  current location and refresh active `Browser.location` sources.
- Sixth landed sub-contract: `Browser.set_title` widens `Node.Cmd` with an
  explicit document-title variant. The browser runtime writes
  `document.title`, records telemetry, and native specs assert the host title
  with `expect_document_title`.
- Seventh landed sub-contract: visibility and online/offline use one-byte bool
  payloads over the same host-backed source path. JS seeds
  `Browser.visibility` from `document.visibilityState`, seeds `Browser.online`
  from `navigator.onLine`, registers per-mount `visibilitychange`,
  `online`, and `offline` listeners, and removes those listeners on unmount.
  Native specs seed and update the same sources with `set_initial_visibility`,
  `set_visibility`, `set_initial_online`, and `set_online`.
- Eighth landed sub-contract: storage sources use a one-byte status plus typed
  text payload (`missing`, `value`, `unavailable`). Native hosts resolve
  declared local/session keys from deterministic spec storage. Wasm hosts avoid
  JS imports: `SignalsRuntime` calls `roc_ui_prepare_mount`, reads declared
  storage keys from the prepared root, queries local/session storage
  synchronously, writes encoded payloads through `roc_ui_set_storage_payload`,
  and only then commits `roc_ui_mount`.
- Outbound navigation, document-title, and storage writes are command-buffer
  operations beside the existing DOM, timer, and task commands; no direct JS
  calls from Roc and no stringly side channel.
- Event payloads, subscription payloads, and environment values must not
  become three unrelated formats.

## Browser Runtime Requirements

- Capture the environment snapshot once per mount on the owning
  `SignalsRuntime`, before the first command drain.
- Register popstate, visibilitychange, online, and offline listeners per mount;
  remove them on `roc_ui_unmount`.
- Validate source ids/generations so late location, visibility, or online
  dispatch after unmount or descriptor change is ignored with diagnostics.
- Map storage snapshot/read failures (unavailable, malformed) into the typed
  failure vocabulary. Storage command failures still report as host/runtime
  errors unless a future command/effect-result design is promoted.
- Refresh WASM memory views after host calls that may allocate.
- Record telemetry for snapshot capture, navigation commands, document-title
  commands, visibility/online updates, storage reads/writes/failures, listener
  cleanup, and ignored-late dispatch.

## Native Host Requirements

- Spec primitives: set the initial location, seed initial storage, set
  visibility and online state, simulate navigate/back/forward, assert the
  current location, assert document title, and assert storage writes/removals.
- Deterministic fake environment: the runner injects values; it does not
  emulate a browser. URL edge-case parsing and DOM dispatch ordering stay in
  JS contract tests.
- Work metrics proving navigation, source-update, and storage handling are
  bounded by changed scopes.
- Teardown assertions that listeners, retained values, and per-mount
  environment records are released.

## Relationship to Subscriptions, HTTP, and Events

- popstate was the first promoted focused browser source; visibilitychange and
  online/offline now use the same machinery. These canaries co-promoted the
  source id/generation and lifecycle pieces in
  `wip/JS_INTEGRATION_DESIGN_PREP.md` without stabilizing a public generic
  `Sub` surface.
- The typed effect capability registry remains a shared concern with HTTP task
  routing, but it should wait for a future subscription or interop canary that
  proves a common task/subscription routing model.
- Link interception uses the shipped static event policy; no dynamic event
  response is required for navigation.

## Driving Examples and Fixtures

- `service-ops-center` routed workflow: landed for deep links, back/forward,
  replaceState redirects, and intercepted navigation links. Visibility-aware
  polling has also landed on the same machinery.
- `team-checkout` persistence expansion: landed for restored checkout state,
  edit writes, and clear-saved removals. Startup storage unavailability can
  render through `StorageUnavailable`; the write-failure notice remains deferred
  behind a command/effect-result design question.
- Landed fixtures: `examples/_fixtures/location-source` for seeded location,
  popstate-style updates, and Back/Forward coverage in native and Wasm, and
  `examples/_fixtures/location-navigation` for command-backed replace coverage
  in native and Wasm.
- Landed storage fixture: `examples/_fixtures/storage-commands` for declared
  local/session startup reads, missing-key state, write/remove commands, and
  coalescing coverage.

See `wip/research/realworld_gap_analysis.md` for the full roadmap and phase
ordering.

Current validation evidence: `service-ops-center` now drives route state from
`Browser.location`, uses intercepted links with `Browser.push_state`, redirects
unknown ready routes with `Browser.replace_state`, emits route-derived
`Browser.set_title` commands, and proves deep-link mount plus Back/Forward in
native and Wasm. It also proves visibility-aware polling through
`Browser.visibility`; `live-search` proves `Browser.online` task gating and
branch cleanup. The focused location fixtures prove seeded URL pieces, popstate
updates, Back/Forward, command-backed replace, and popstate listener cleanup
through native specs and the Wasm mount gate. The focused `storage-commands`
fixture proves native and Wasm storage startup reads plus command
writes/removes, and `team-checkout` proves restored checkout state, edit writes,
and clear-saved removals in native and Wasm.

## Promotion Validation Plan

Slice 1: startup snapshot plus location.

1. Done: decide the snapshot shape and app contract (recorded here first).
2. Done for location: initial snapshot capture, the seeded location source,
   push/replace command refresh, and live popstate source refresh have landed.
3. Done for location: native initial-location injection, first-frame
   assertions, command-backed replace coverage, history back/forward,
   current-location assertions, and matching Wasm fixture exercises have
   landed.
4. Done for location: JS snapshot encoding, URL-piece parsing, pre-mount Wasm
   seeding, push/replace opcode execution, popstate dispatch ordering,
   listener unmount cleanup, and ignored stale/unmounted telemetry have
   landed.

Slice 2: storage.

1. Done for the focused fixture: declared startup reads through native seeded
   storage and the Wasm prepared-mount snapshot path.
2. Done for the focused fixture: write/remove commands with per-drain
   coalescing and host-level unavailable-storage failure surfacing.
3. Done for the focused fixture: native specs seed initial storage and assert
   write/remove results.
4. Done for the focused fixture: JS contract tests cover snapshot encoding,
   prepared-mount storage seeding, unavailable storage, command coalescing,
   and value-redacted telemetry.

Slice 3: focused browser sources and title command.

1. Done for title: `Browser.set_title` uses the command boundary, native specs
   assert `expect_document_title`, and browser contract tests assert
   `document.title` updates plus command telemetry.
2. Done for visibility: native and Wasm hosts seed/update a one-byte payload,
   `service-ops-center` pauses and resumes polling from `Browser.visibility`,
   and browser contract tests assert listener install/remove, command drain,
   and stale-dispatch telemetry.
3. Done for online/offline: native and Wasm hosts seed/update a one-byte
   payload, `live-search` suppresses offline task starts and replays on return
   online, and browser contract tests assert listener cleanup plus stale
   online/offline dispatch telemetry.
4. Done for the generic-subscription boundary decision: these focused browser
   sources proved mount-scoped ids/generations, payload reuse, and cleanup
   without stabilizing a public `Sub` API.

## Focused Gates

For prep-only edits that do not change current behavior claims, run:

```sh
git diff --check
zig build run-check-tidy
```

When a slice is promoted into implementation, use the smallest gate that
proves the slice, then the repository gate before committing. A promoted
browser-environment slice should include at least:

```sh
python3 scripts/test.py native --native always
zig build run-test-browser
python3 scripts/test.py roc-check
```

Add `python3 scripts/test.py wasm` when wasm/app build coverage changes, and
both `python3 scripts/serve.py --no-server` app-opt modes when public examples
change.

## Outstanding Questions

- How should app-visible recovery from failed storage write/remove commands
  surface, and can that be solved as part of a broader command/effect-result
  design rather than a storage-only side channel?
- Are cross-tab storage events in scope, and if so do they ride the
  subscription machinery unchanged?
- Hash-based routing: does the platform need to distinguish hash navigation,
  or are raw pieces enough for apps to decide?
- Scroll restoration: browser default, platform command, or app concern?
- One location signal, or split path/query/hash signals?
- Multiple mounts share one browser URL and history: per-mount snapshots hold
  the same values, and navigation commands from any mount mutate shared
  history. Which mount owns navigation, and is multi-mount navigation
  supported at all?

## Promotion Status

The initial snapshot mechanism, seeded location source, command-backed
push/replace navigation, live popstate updates, native history-stack spec
primitives, routed `service-ops-center` proof, document-title commands,
visibility and online/offline sources, local/session text storage sources,
storage write/remove commands, focused storage fixture, JS storage contract
tests, and maintained `team-checkout` persistence proof have landed. Future
browser-environment work is limited to the outstanding questions above until a
maintained app or focused canary proves a new gap.
