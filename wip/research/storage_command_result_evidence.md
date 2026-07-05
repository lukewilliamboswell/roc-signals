# Storage Command Result Evidence

Captured: 2026-07-05.

Purpose: record the validation outcome for the browser-environment follow-up
"app-visible recovery from failed storage write/remove commands." The question is
whether `team-checkout` or a focused canary currently justifies a public
storage-specific command-result API, or whether this should stay behind a
broader command/effect-result design.

## Focused Gates

For edits to this note:

```sh
git diff --check
zig build run-check-tidy
```

If storage runtime or browser contract claims change, also run:

```sh
node --test --test-name-pattern "storage" scripts/browser/runtime_contract.test.mjs
```

If maintained-app behavior claims change, include the native app/spec gate:

```sh
python3 scripts/test.py native --native always
```

Refresh check: re-run on 2026-07-05 with
`node --test --test-name-pattern "storage" scripts/browser/runtime_contract.test.mjs`.
It passed 4/4, covering storage payload encoding, prepared-mount storage
snapshots, command coalescing, and unavailable-storage command failures.

## Current Surface

Storage reads and storage writes are intentionally different today.

Reads are app-visible sources:

- `Browser.local_storage_text(key) : Signal(Browser.StorageText)`
- `Browser.session_storage_text(key) : Signal(Browser.StorageText)`
- `Browser.StorageText := [StorageMissing, StorageValue(Str), StorageUnavailable(Str)]`

The browser runtime resolves declared keys before first render. If storage is
blocked or unavailable during that read, Roc receives `StorageUnavailable` and
the app can render recovery or fallback UI.

Writes and removals are fire-and-forget commands:

- `Browser.set_local_storage_text(key, value) : Cmd`
- `Browser.set_session_storage_text(key, value) : Cmd`
- `Browser.remove_local_storage(key) : Cmd`
- `Browser.remove_session_storage(key) : Cmd`

The Zig engine sinks these command-buffer operations and returns no updated
source value. The browser runtime coalesces commands by area/key before touching
storage. If browser storage is missing, `setItem` / `removeItem` is missing, or
the browser throws during the mutation, the runtime raises a host/runtime error.
`scripts/browser/runtime_contract.test.mjs` currently locks this in with
`storage commands fail clearly when browser storage is unavailable`.

The native fake storage path is deterministic and infallible; native specs can
seed initial storage and assert final writes/removals, but they do not model
browser quota/security write failures.

## Current Consumer

`team-checkout` now restores checkout state from localStorage, writes edits with
`Ui.on_change(..., Browser.set_local_storage_text(...))`, and clears saved
values with remove commands. It also renders startup read unavailability through
the existing `StorageUnavailable` source path:

```roc
StorageUnavailable(_) => "Saved draft storage is unavailable in this browser."
```

The earlier "draft could not be saved" write-failure notice remains
unimplemented because write/remove commands do not produce app-state results.
Implementing that notice honestly requires a result-producing effect shape, not
just another storage command opcode.

## Decision

Do not promote a storage-specific app-visible write-failure API from the current
evidence.

Keep storage writes/removals as plain commands until a maintained app or focused
canary proves a broader command/effect-result surface. A storage-only result API
would create a second effect feedback path beside tasks, browser sources, and
future subscriptions. It would also need answers that are not storage-specific:

- how a command result is addressed back to the producing scope;
- whether result state is a `Signal`, a task-like source, or an event response;
- how coalesced commands report success/failure when multiple writes to the same
  key collapse into one browser mutation;
- whether a result resets on retry, replacement, scope disposal, or unmount;
- how native specs inject deterministic command failures without becoming a
  browser clone;
- how host/runtime errors, telemetry, and user-visible failures divide
  responsibility.

Do not overload `Browser.local_storage_text` / `session_storage_text` with write
results. Those signals represent declared startup reads today. If cross-tab
storage events are promoted later, they should still represent storage value
changes, not command completion status.

## Reopen Triggers

Reopen with a maintained app or focused canary that needs rendered recovery from
a failed command distinct from the current host/runtime error path. Examples:

- `team-checkout` needs to keep editing while showing "draft could not be saved"
  after a browser write throws;
- a retry/clear action needs to distinguish a failed write from a stale restored
  value;
- multiple host commands beyond storage need app-visible completion or failure,
  proving a general command/effect-result model;
- browser quota/security failures need deterministic JS contract coverage and
  portable native spec semantics.

If promoted, co-design the result shape with the subscriptions/app-interop and
typed effect capability work. Do not add a storage-only side channel.
