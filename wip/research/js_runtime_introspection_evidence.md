# JS Runtime Introspection Evidence

Captured: 2026-07-05.

Purpose: record the spike outcome for the `NEXT_STEPS.md` candidate "JS runtime
debug/introspection hooks." The question is whether tests or demos need a new
generic mount/route/storage/task introspection API beyond the runtime telemetry
hook and app-local adapters.

Refresh check: re-run on 2026-07-05:

- `node --test --test-name-pattern "telemetry|task|storage|location|visibility|online" scripts/browser/runtime_contract.test.mjs`
  passed 28/28.

## Focused Gates

For edits to this note:

```sh
git diff --check
zig build run-check-tidy
```

If runtime telemetry code or browser contract claims change, also run:

```sh
node --test --test-name-pattern "telemetry|task|storage|location|visibility|online" scripts/browser/runtime_contract.test.mjs
```

## Current Surface

The browser runtime already accepts a telemetry option on both `mountSignalsApp`
and direct `SignalsRuntime` construction. `telemetry` may be `true`, a callback,
or an object with `log(entry)`. Every entry carries
`source: "signals-runtime"`, a monotonically increasing `seq`, `timeMs`, and a
typed `kind`.

Current telemetry covers the debug/introspection needs named in the backlog:

- mount lifecycle and host calls: `prepare_mount`, `mount`, browser-source
  updates, timers, task resolution, and `unmount`;
- environment and route state: initial location/visibility/online snapshots,
  location updates, and popstate listener install/remove/ignored-stale events;
- browser sources: visibility and online listener install/remove/update and
  ignored stale/unmounted dispatches;
- storage: declared-key startup snapshots, snapshot kind and payload length,
  storage set/remove command telemetry with stored values redacted, and command
  batch op counts;
- tasks: `start_task`, `task_resolution`, `cancel_task`,
  `ignored_task_resolution`, and `unknown_task_resolution`;
- command batches: phase, count, fixed-record bytes, fixed-string bytes,
  dynamic-buffer bytes, op counts, and decoded command details;
- DOM/event diagnostics: event binding, DOM event delivery, payload extraction,
  payload errors, and command batches emitted by events;
- behavior lifecycle: missing behavior, attach, update, and cleanup telemetry;
- unmount cleanup: `clear_dom` includes DOM node, event listener, interval, and
  task counts before cleanup.

The runtime also keeps `lastCommands` and `commandDecodeStats` as local
inspection fields for browser contract tests. Those are test/runtime internals,
not an app-facing public debug API.

## Current Consumers

`scripts/browser/runtime_contract.test.mjs` already asserts the telemetry path
for command batches, DOM events, event payload dispatch, task
start/resolve/cancel/stale/unknown states, environment snapshots, storage
snapshots and storage command coalescing, navigation commands, and
location/visibility/online listener cleanup plus stale-message handling.

`scripts/browser/mount_wasm_example.mjs --telemetry-summary` consumes telemetry
from mounted public examples to summarize command volume and decode work. Its
example-specific smoke checks use DOM queries and browser doubles directly
instead of requiring a generic `window.__app_debug__` shape.

Maintained public examples do not require a platform-level debug object. Any
demo-specific route/task/storage assertions can stay in the app adapter or the
test harness until repeated examples prove a shared shape.

## Decision

Do not promote a new JS runtime debug/introspection API from the current
evidence.

Keep the runtime debug surface as:

- the existing telemetry callback,
- browser contract tests that assert telemetry entries directly,
- app/demo-specific adapters when a demo wants a custom debug object,
- direct runtime internals only inside runtime contract tests.

This keeps the browser host as a boundary executor. A public introspection API
would otherwise expose route, task, storage, or mount state as a second
browser-only state channel before an app proves that telemetry is insufficient.

## Reopen Triggers

Reopen only with a maintained app, public demo, or focused browser test that
cannot be served by telemetry plus app-local adapters. Examples:

- a reusable external test harness that needs a stable cross-app runtime
  inspection contract rather than telemetry events;
- multi-mount diagnostics that need a public mount handle or snapshot summary
  beyond per-runtime telemetry;
- app-specific interop or generic subscriptions proving a shared handler-error
  diagnostic shape;
- privacy/redaction requirements that make the current command/task telemetry
  unsuitable for public demos.

Do not reopen merely to standardize a demo's `window.__app_debug__` object; that
shape remains app adapter code until repeated demos prove a platform need.
