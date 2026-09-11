+++
title = "Testing"
description = "Test app behaviour, control effects and timers, and check update work with native specs."
weight = 9
template = "page.html"
+++

# Testing

Native specs run your app against a simulated DOM using the same reactive engine
as the browser build. They let you check rendered values, state lifetime,
requests, and update work. You control effect execution and timer ticks explicitly,
so a test does not need a network connection or a delay to exercise those paths.

## Controlling action effects

Native specs normally execute prepared action effects synchronously. Add
`(manual-effects)` to a test's `setup` to leave them queued instead. The engine
still prepares each owned snapshot when its action commits.

```scheme
(setup (manual-effects))
(steps
  (expect-pending-effects 2)
  (stub-http "second answer" :url "/api/search" :status 200 :body "new")
  (run-effect 2)
  (expect-pending-effects 1)
  (stub-http "first answer" :url "/api/search" :status 200 :body "old")
  (run-effect 1)
  (expect-pending-effects 0))
```

This fragment assumes earlier mount or input actions admitted two effects.
Occurrence IDs start at `1` in each fresh runtime and increase for every prepared
effect, including chained effects. They are not queue positions or request keys:
running `2` first does not rename `1`. Unknown or already-consumed IDs fail the
spec. `run-effect` requires manual mode.

Each selected effect runs its real Roc closure against the existing service
stubs, then applies its returned action through normal engine propagation.
Chained effects remain queued for another explicit step. Unexecuted effects
remain owned by the engine and are released during teardown. Sorting, stale
application generations, and scope disposal can therefore be tested with the
same native structural-work assertions as other actions.

Manual mode controls execution order, not suspension inside a closure. It does
not simulate a network, run worker threads, or interleave events between two
hosted calls in one closure. Browser suspension and memory-boundary tests cover
those additional executor concerns.

For a checkout-based app, build for your machine and run its specs:

```sh
roc build --target=arm64mac --output=/tmp/app examples-web/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples-web/my-app/specs
```

The driver prints a result for each case and a summary. Exit code `0` means
every selected case passed. Failures include the assertion line:

```text
TEST FAILED at line 4: locator did not resolve to one element
```

Targets: `arm64mac`, `x64mac`, `arm64musl`, `x64musl`.

Each `*.scm` file is one data-only S-expression test case. Put cases under the
app's `specs/` directory; the driver discovers them recursively, sorts their
relative paths, and runs each against a fresh app process. It supports bounded
parallelism, glob filters, deterministic sharding, per-case timeouts, and
fail-fast scheduling.

```lisp
(test "checkout succeeds"
  (steps
    (fill (label "Email") "team@example.com")
    (click (role button :name "Place order"))
    (expect-visible (text "Order confirmed"))))
```

## Locators are semantic

Locators identify elements by role, name, label, text, or an explicit test id.
The native host models a subset of browser naming and roles; a matching locator
is not an accessibility audit.

| Locator | Example |
| --- | --- |
| Role and accessible name | `(role button :name "Send invite")` |
| Associated label | `(label "Invite email")` |
| Exact visible text | `(text "Submit status: idle")` |
| Test id | `(test-id "traffic-chart")` |

Locator strings use the same escapes as any other spec string: `\\` is one
backslash, `\"` one quote, and `\n` a newline. A locator can therefore name an
element whose text contains a separator, such as a Windows path in a breadcrumb.

A locator must resolve to exactly one element. Matching several is an error
(*locator matched 2 elements*). Repeated controls may legitimately share a name;
use a unique test id when the role and name cannot distinguish the target.

`Html.section`, `Html.form_label`, `Html.link`, and input helpers provide name
metadata for these locators. Give controls useful names and check their browser
accessibility separately.

For repeated rows, derive a unique test id from the row key:

```roc
Html.checkbox_attrs("Read", read, [Html.test_id("book-${id}")], msg)
```

## Actions

```lisp
(click (role button :name "Save"))
(real-click (role button :name "Open note"))
(fill (label "Message") "draft")
(check (label "Accept terms"))
(uncheck (label "Accept terms"))
(change (label "Plan") "growth")
(select-option (label "Plan") "enterprise")
(submit (role form :name "Signup form"))
(focus (label "Message"))
(blur (label "Message"))
(key-down (label "Command search") "Enter" false)
(pointer-down (role region :name "Release card"))
(pointer-up (role region :name "Release card"))
(pointer-enter (role region :name "Drop target"))
(pointer-leave (role region :name "Drop target"))
(composition-start (label "Message"))
(composition-end (label "Message"))
(custom-event (test-id "traffic-chart") "chart-select" "point-1")
```

**`click` versus `real-click`.** `click` dispatches directly to the target's own
click binding. `real-click` dispatches `pointerdown → pointerup → click` through
the full propagation path — capture, bubble, `self`, and stop policies — and
runs default actions. Use `real-click` for nested controls inside clickable or
draggable parents, and for submit buttons inside forms.

`key-down` takes the key name and a shift-key boolean. `custom-event` sends its
final argument as `event.detail`.

Checkboxes use the checked-change path, so use `check` / `uncheck` — or
`real-click`, which runs the browser's default toggle action. A bare `click` on
a checkbox with no click binding fails with *target has no click binding*.

## Assertions

```lisp
(expect-visible (role heading :name "Team Checkout"))
(expect-absent (role region :name "Queue Widget"))
(expect-text (test-id "submit-status") "Submit status: sending")
(expect-value (label "Invite email") "ops@example.com")
(expect-attr (label "Invite email") aria-invalid "true")
(expect-no-attr (label "Invite email") aria-invalid)
(expect-checked (label "Accept terms") true)
(expect-disabled (role button :name "Send invite") true)
(expect-updates (label "Message") 2)
```

`expect-updates` asserts how many times a specific element was patched, summed
across its text, value, checked, and disabled sinks — a direct way to prove that
an unrelated change did *not* touch something.

Give text that changes a stable locator so failures can show the actual value:

```roc
Html.paragraph_s_attrs(status, [Html.test_id("submit-status")])
```

`(expect-text (text "Done") "Done")` only proves that text exists. Use
`expect-visible` for that intent, or `expect-text` with a stable test id to
compare a changing value. For a container without its own text, `expect-text`
compares concatenated descendant text. `expect-visible` checks presence in the
native model; it does not evaluate CSS visibility.

## Races, timers, and cleanup

Use manual effects to exercise application race policy without a network or a
simulated coroutine scheduler. For the maintained latest-wins fixture, the
mount admits effect 1 and Refresh admits effect 2:

```lisp
(expect-pending-effects 1)
(click (role button :name "Refresh"))
(expect-pending-effects 2)
(stub-http "older request" :url "/api/latest/0" :status 200 :body "stale result")
(run-effect 1)
(expect-text (test-id "status") "Loading")
(stub-http "newest request" :url "/api/latest/1" :status 200 :body "fresh result")
(run-effect 2)
(expect-text (test-id "status") "Done: fresh result")
(expect-pending-effects 0)
```

The app's generation guard rejects the older result; the engine still executes
both admitted effects. A complementary test can run effect 2 first and effect 1
last, then assert that the newer result remains visible. Stub labels explain the
scenario to readers; they are not task names or effect identities.

`expect-pending-effects` checks an absolute count. Assert visible outcomes as
well: a pending count alone cannot prove that the app handled a result correctly.

Timers and named scope cleanup remain explicit:

```lisp
(tick-interval 1000)
(tick-interval-if-active 1000)
(expect-interval 1000 1)
(expect-cleanup "live search panel cleanup" 1)
```

Disposing a scope cancels its interval registrations, but does not cancel
admitted action effects. A disposal spec should run the outstanding effect and
show that retired state destinations are not recreated while surviving state
destinations can still update.

Use setup values to test startup with a saved draft, a deep link, or an offline
environment. For example, an app that leaves the initial URL and storage intact
can assert:

```lisp
(test "restored navigation"
  (setup
    (initial-location "/article/keyed-lists")
    (initial-visibility hidden)
    (initial-online offline)
    (local-storage "conduit.jwt" "test-token")
    (session-storage "draft" "hello"))
  (steps
    (expect-current-location "/article/keyed-lists")
    (expect-local-storage "conduit.jwt" "test-token")
    (expect-session-storage "draft" "hello")))
```

The forms in `(setup ...)` run before the first render. Within `(steps ...)`,
use `navigate`, `history-back`, `history-forward`, `set-visibility`, and
`set-online` to change the environment. Storage assertions can check values or
absence with `expect-no-local-storage` and `expect-no-session-storage`.

A full navigation test:

```lisp
(expect-document-title "Home")
(expect-visible (text "You are home"))
(click (role link :name "Go to About"))
(expect-current-location "/about")
(expect-document-title "About")
(history-back)
(expect-current-location "/")
(expect-visible (text "You are home"))
(history-forward)
(expect-current-location "/about")
(navigate "/nowhere")
(expect-document-title "Not found")
```

## Work budgets

Work metrics help catch regressions that leave the visible result unchanged,
such as rebuilding rows during a reorder.

Call `mark-metrics`, perform an action, then assert exact or maximum deltas:

```lisp
(mark-metrics)
(click (role button :name "Reverse rows"))
(expect-metric-delta rows_reused 4)
(expect-metric-delta rows_created 0)
(expect-metric-delta rows_removed 0)
(expect-metric-delta signal_record_table_rebuilt 0)
```

This example assumes four live rows. It checks that reversing them preserves
their scopes and does not rebuild the signal record table. Use the row count
and work bounds appropriate to your fixture.

Commonly useful metrics:

| Metric | Meaning |
| --- | --- |
| `derived_calls_into_roc` | derived signal transforms that ran |
| `rows_created` / `rows_removed` / `rows_reused` | keyed-row churn |
| `scopes_created` / `scopes_disposed` | scope lifecycle |
| `events_processed` | events dispatched into the graph |
| `propagation_prunes` | propagations stopped by `is_eq` |
| `active_intervals_synced` | timer bookkeeping |
| `retained_alloc_delta` | retained Roc allocations |
| `host_retained_bytes_delta` | retained host bytes |

The authoritative list is in `src/spec/spec_runner.zig`.

Assert structural outcomes exactly: rows created, removed, and reused, and
scopes created or disposed. Bound incidental engine work with
`expect-metric-delta-at-most`. Choose a bound from the work the interaction
should require, then compare small and large fixtures when testing scaling.
Copying an observed number into a test without that reasoning can preserve an
existing regression.

Say which kind of path an assertion is about. Selecting a row, appending an
event, or moving one item is *changed-set* work: assert the structural counters
exactly, and expect zero rows created, removed or rebuilt for anything the
change did not touch. Filtering, sorting and importing are *whole-dataset* work
by construction — every item is examined — so the claim worth asserting there is
not a small number but that identity survives: rows reused rather than rebuilt,
and scopes disposed only for items that really left. Repeating an action that
changes nothing belongs in the same specs as an equality no-op
(`propagation_prunes`). Show that a disposed branch cancels its timers and that
outstanding effect results do not recreate its retired state. For latest-wins
behavior, assert that the application's reducer preserves the newest result
when an older effect runs later.

`derived_calls_into_roc` counts derived evaluations, while `dirty_source_roots`
counts changed sources. One source can wake many transforms. `propagation_prunes`
records equality cutoffs; interpret it alongside the graph and visible result,
since a low count alone does not establish an equality bug.

Do not pin `patches_emitted` in semantic specs: it combines unrelated command
kinds. Use row and scope counters for structural behaviour and benchmark
telemetry to track overall command traffic.

For a retained-allocation delta that should not be there, rerun the built native
app with `--host-trace-allocations`:

```sh
.test-out/bin/signals-my-example --host-trace-allocations examples-web/my-example/specs/case.scm
```

The host writes an allocation checkpoint after mount and after every spec
command. Each summary separates Roc allocations freed since the previous
checkpoint from newly allocated blocks that are still live, and reports
host-only live allocation/byte deltas alongside them. Roc backing blocks are
subtracted from the host allocator totals, so this immediately distinguishes
Roc retention from growth in host-owned collections. The following cohort lines
group surviving Roc blocks by requested size, runtime debug phase, and native
return address. This makes repeated growth attributable: reproduce the same
interaction several times, find the cohort that grows each time, then symbolize
its `caller` address with the platform debugger or `addr2line` against that app
binary. Phase values come from the `debugPhase` sites in `src/signals/engine.zig`
and the host-value boundary sites in `src/native_host.zig`.

Tracing is opt-in because retaining provenance and scanning live allocations at
every checkpoint is diagnostic work. Ordinary specs and benchmarks continue to
pay only for the existing allocation ledger and counters.

`roc_metric_live` is the independent alloc-minus-dealloc counter. It should
equal the ledger's `roc_live` block count at every checkpoint; a mismatch means
the instrumentation itself is observing an ownership boundary at the wrong
time.

In the browser, the runtime's `telemetry` option emits an
`allocation_checkpoint` after each applied command batch when the allocation
exports are available. Meaningful Roc allocation counts and phase-and-size
cohorts require a host built with the allocation ledger enabled, such as Debug,
ReleaseSafe, or the instrumented benchmark host. Ordinary ReleaseSmall and
ReleaseFast hosts omit that ledger; zero debug counts from those builds are not
evidence that no Roc allocations remain. See
[Contributing](@/docs/contributing.md) for host builds and the instrumented
benchmark workflow.

Teardown is also a leak gate. Native specs fail if either the Roc ledger or the
host debug allocator is non-empty after the runtime is dismantled. The Wasm
mount harness checks that the HostValue registry is empty after `unmount` and
also checks the exported Roc allocation count and byte total. Those latter
checks establish ledger balance only when the host has the ledger enabled.

## Window scenarios

Native specs run without a presentation layer, so they cannot see a control laid
out beyond the window or a native editor that kept the previous document's undo
history. For the GUI examples those states are covered by `(scenario ...)`
specs beside the `(test ...)` specs in `examples-gui/<app>/specs/`, written in
the same language and parsed by the same engine parser, and run against the
real window by `python3 scripts/gui_scenarios.py` through the GUI host's
`--host-scenario` flag. They name controls by test id or visible label rather
than by pixel coordinates, and record their observations — and on macOS the
window itself — as artifacts. See [Contributing](@/docs/contributing.md) for
the window-only steps, the diagnostic convention, and what is macOS-only.

Keep the two forms apart by what they prove. Semantic and work-budget
assertions belong in a test; presentation assertions belong in a scenario. A
scenario is not the place to re-check what a test already proves.

## What belongs where

Native specs are the right home for **app semantics**: what the user sees, what
the app requests, what state survives. They are not a browser.

The JavaScript contract tests (`zig build run-test-browser`) and Node mount
harness check the JS/Wasm protocol and runtime behaviour with a DOM double.
They do not render a page in a real browser.

Use real-browser tests for CSS layout, focus and selection, IME interaction,
keyboard navigation, network integration, and accessible names and relationships.
Include manual accessibility checks where automation cannot establish usability.
A native pass establishes behaviour within the native model only.

## Running suites

Individual app:

```sh
roc build --target=arm64mac --output=/tmp/app examples-web/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples-web/my-app/specs
```

Repository suites:

```sh
python3 scripts/test.py native --native always   # all native specs
python3 scripts/test.py roc-check                # type-check every app
python3 scripts/test.py roc-test                 # run every app's `expect` tests
python3 scripts/test.py wasm                     # build every app to wasm
python3 scripts/test.py browser                  # JavaScript contract tests
python3 scripts/test.py                          # everything
```

## Next

[Under the Hood](@/docs/under-the-hood.md) — what actually crosses the
WebAssembly boundary.
