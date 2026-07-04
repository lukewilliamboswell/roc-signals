# Browser Environment Design Prep

Deferred working note for the browser environment surface in the Signals UI
framework: the startup environment snapshot, browser location/history, and
browser storage. This is not an enduring design document yet and is not an
active implementation milestone. Its purpose is to capture the plan shape,
requirements, and open questions before the browser-environment priority in
`wip/NEXT_STEPS.md` promotes into concrete implementation slices and the final
design is folded into `design.md` and the app-author guide.

The generic subscription machinery (descriptors, identity, generations,
lifecycle, payload producer) is owned by `wip/JS_INTEGRATION_DESIGN_PREP.md`;
this note owns the browser-environment surface that consumes it. The
motivating analysis is `wip/research/realworld_gap_analysis.md`.

Refresh check: created 2026-07-04 from the RealWorld gap analysis. Re-check
the current-state claims (entry contract, mount sequence, absence list)
whenever the platform ABI, `platform/main.roc`, or the browser runtime mount
path changes.

## Why This Exists

A RealWorld-class SPA needs an honest browser environment:

- the first render must reflect the real initial URL and any persisted
  session, not a fake default patched after mount;
- deep links must mount the right view directly;
- back/forward must work through popstate;
- programmatic navigation must update the URL without a reload;
- drafts and sessions must persist across reloads through browser storage.

None of this exists today: the repository has no location, history, popstate,
storage, or document-title surface (verified by search; see the gap analysis).
Routing built on app-local state and anchors is not enough for a production
SPA, and storage semantics decided ad hoc per app would fracture the boundary.

## Current Coverage in `design.md` and the Repository

- `platform/main.roc` requires `main : {} -> Elem`; there is no environment,
  flags, or seed mechanism.
- Mounting runs `SignalsRuntime.mount()`, `roc_ui_mount()`, `roc_ui_init()`,
  then `main({})`; the app receives nothing from the host at startup.
- `design.md` treats one Wasm instance per active mount as the production
  stance; per-mount ownership is the established registration model.
- `Signal.interval` is the shipped prior art for a host-backed source with a
  token, start/cancel commands, and per-mount cleanup.
- HTTP tasks prove the command/task boundary with request ids, cancellation,
  and stale-result suppression.
- Link clicks can already be intercepted with the shipped `prevent_default`
  static event policy.

Missing details, intentionally unresolved until promotion:

- no environment snapshot shape or app contract for receiving it;
- no location value shape or navigation command surface;
- no storage read/write/remove surface or failure vocabulary;
- no native spec primitives for initial environment, navigation, or storage;
- no browser runtime capture/cleanup model for popstate listeners.

## Design Goals

1. **Honest first render.** The first frame reflects the real initial
   environment; no render from fake defaults patched after mount.
2. **Typed environment, no flags bag.** Initial values cross the boundary as
   declared typed values, not an untyped JSON blob.
3. **Per-mount ownership.** One environment snapshot per active mount, owned
   by the mounting `SignalsRuntime`; no global registries.
4. **One payload vocabulary.** Inbound values reuse the shared boundary schema
   tags; outbound navigation and storage writes ride the existing command
   boundary.
5. **Deterministic native fakes.** Every capability gets native injection and
   assertion primitives so semantics and work budgets are asserted without a
   browser.
6. **Hosts stay boundary executors.** Roc describes navigation and storage as
   explicit data; hosts execute descriptors and report diagnostics.

## Conceptual Model: Startup Snapshot

The snapshot is the typed set of browser-environment values captured once per
mount, before the first render:

- location pieces (path, query, hash);
- declared storage reads (specific keys/areas the app asks for, not a
  whole-store dump).

Two open decisions dominate the design:

**Sync-only versus task-backed.** Location and Web Storage are synchronous
browser APIs, so a synchronous snapshot avoids forcing Loading states onto the
first paint. Task-backed reads would reuse the existing task path but
reintroduce render-then-patch for values that are cheaply available. Expected
lean: sync-only for the initial snapshot; anything genuinely async stays a
task.

**Impact on `main : {} -> Elem`.** Candidate shapes:

- change the app contract to `main : Env -> Elem`, passing a typed environment
  record;
- keep `main : {} -> Elem` and expose platform-provided sources/values seeded
  from the snapshot.

Changing the `requires` clause in `platform/main.roc` is a platform-ABI
change: every example, the public guide, `wip/PUBLIC_API_SHRINK_AUDIT.md`, and
the `roc-check` gate move in the same slice. That slice must never be treated
as small. The decision must also define how the native spec runner injects the
environment under each shape.

Post-mount environment changes are not snapshots: they arrive as source
updates (popstate, and any future storage events) through the subscription
path.

## Conceptual Model: Location and History

- The host supplies the current location as raw text pieces (path, query,
  hash). Route parsing, pattern matching, and route tables are app/package
  land; the platform does not ship a router DSL.
- The initial location comes from the startup snapshot. Live updates arrive
  through popstate as the first promoted inbound subscription source, using
  the descriptor/id/generation/lifecycle design in
  `wip/JS_INTEGRATION_DESIGN_PREP.md`.
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
- `document.title` is a recorded open question, not an implied part of this
  surface.

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
  origin on the public site, so collisions are real today.
- Stored values are text; apps encode with builtin `Json` or `Str`. No
  serialization framework in the platform.
- Cross-tab storage events are a recorded open question; if adopted they ride
  the subscription machinery, never a second inbound path.

## Payload and Command Boundary

- Inbound snapshot and source values reuse the shared boundary schema
  vocabulary (unit, text, bool, records of primitive leaves) validated in
  `src/signals/boundary.zig`; add leaves only when a canary needs them, with
  the same fail-closed diagnostics as event extraction.
- Outbound navigation and storage writes are command-buffer operations beside
  the existing DOM, timer, and task commands; no direct JS calls from Roc and
  no stringly side channel.
- Event payloads, subscription payloads, and environment values must not
  become three unrelated formats.

## Browser Runtime Requirements

- Capture the environment snapshot once per mount on the owning
  `SignalsRuntime`, before the first command drain.
- Register the popstate listener per mount; remove it on `roc_ui_unmount`.
- Validate source ids/generations so late popstate dispatch after unmount or
  descriptor change is ignored with diagnostics.
- Map storage failures (unavailable, quota, malformed) into the typed failure
  vocabulary.
- Refresh WASM memory views after host calls that may allocate.
- Record telemetry for snapshot capture, navigation commands, storage
  reads/writes/failures, and ignored-late dispatch.

## Native Host Requirements

- Spec primitives: set the initial location, seed initial storage, simulate
  navigate/back/forward, assert the current location, assert storage writes
  and removals.
- Deterministic fake environment: the runner injects values; it does not
  emulate a browser. URL edge-case parsing and DOM dispatch ordering stay in
  JS contract tests.
- Work metrics proving navigation and storage handling are bounded by changed
  scopes.
- Teardown assertions that listeners, retained values, and per-mount
  environment records are released.

## Relationship to Subscriptions, HTTP, and Events

- popstate is the first promoted subscription source; it co-promotes the
  machinery in `wip/JS_INTEGRATION_DESIGN_PREP.md` without stabilizing a
  public generic `Sub` surface.
- Source ids/generations and the typed effect capability registry are shared
  concerns with HTTP task routing; the location slice is where the shared
  routing evidence is expected to originate.
- Link interception uses the shipped static event policy; no dynamic event
  response is required for navigation.

## Driving Examples and Fixtures

- `service-ops-center` routing expansion: deep links, back/forward,
  replaceState redirects, and visibility-aware polling (the visibility source
  is a later canary on the same machinery).
- `team-checkout` persistence expansion: resume, clear, and failure-notice
  flows for a persisted checkout session.
- Fixtures: `examples/_fixtures/env-snapshot` (render every snapshot field;
  first frame is final), `examples/_fixtures/route-source` (two-page app:
  navigation, history, stale popstate, disposal cancels the page task), and
  `examples/_fixtures/storage-commands` (one key: write/remove/failure and
  coalescing counts).

See `wip/research/realworld_gap_analysis.md` for the full roadmap and phase
ordering.

## Promotion Validation Plan

Slice 1: startup snapshot plus location.

1. Decide the snapshot shape and app contract (recorded here first).
2. Implement snapshot capture and the location source with popstate, plus
   pushState/replaceState commands.
3. Native specs: initial-location injection, first-frame-final assertions,
   navigate/back/forward, push-versus-replace ordering within one drain,
   stale popstate ignored, and disposal cancels pending page work.
4. JS contract tests: snapshot encoding from location/storage doubles, URL
   piece parsing, dispatch ordering, and listener unmount cleanup.

Slice 2: storage.

1. Declared startup reads through the snapshot.
2. Write/remove commands with per-drain coalescing and typed failure
   surfacing.
3. Native specs: seeded initial storage, write/remove assertions, coalescing
   counts, and failure rendered as app state.
4. JS contract tests: unavailable storage, malformed values, cleanup, and
   ordering.

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

- Sync-only or task-backed startup snapshot? Expected: sync-only.
- `main : Env -> Elem`, or `main : {} -> Elem` plus platform-provided seeded
  sources? What does the native runner inject under each shape?
- Is `document.title` part of the navigation surface, a separate command, or
  out of scope?
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
- How are storage keys namespaced per app/mount on shared origins?

## Suggested First Promoted Slice

Snapshot mechanism, location source with popstate, and push/replace commands,
with native and JS coverage as above; storage follows as the second slice.
This corresponds to the browser-environment priority in `wip/NEXT_STEPS.md`
and delivers the first canary for the subscriptions priority. It remains
deferred until the `service-ops-center` routing expansion records its friction
notes (phase 0 of the roadmap).
