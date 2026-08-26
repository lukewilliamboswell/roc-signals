+++
title = "Testing"
description = "Browser-style tests without a browser — semantic locators, deterministic async, history and storage control, and work budgets."
weight = 9
template = "page.html"
+++

# Testing

Your app compiles to a **native binary** that runs behaviour specs against a
simulated DOM. No browser, no WebDriver, no waiting. A 363-line suite covering a
full RealWorld app runs in milliseconds and cannot flake, because there is no
real clock, no real network, and no real event loop to race.

```sh
roc build --target=arm64mac --output=/tmp/app examples/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples/my-app/specs
```

Exit code `0` and no output means everything passed. Failures name the line:

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

Elements are found the way a user or screen reader finds them — never by CSS
selector or DOM position:

| Locator | Example |
| --- | --- |
| Role and accessible name | `(role button :name "Send invite")` |
| Associated label | `(label "Invite email")` |
| Exact visible text | `(text "Submit status: idle")` |
| Test id | `(test-id "traffic-chart")` |

A locator must resolve to exactly one element. Matching several is an error
(*locator matched 2 elements*), which catches ambiguous labels early — a real
accessibility problem, not just a test problem.

This is why `Html.section`, `Html.form_label`, `Html.link`, and every input take
an accessible name. Naming things properly is not extra work for tests; it is
the same work that makes the app usable.

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
(expect-text (text "Submit status: sending") "Submit status: sending")
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

## Async, deterministically

Tasks and timers are driven by the spec, not by a clock. There is no sleeping
and no polling.

```lisp
(expect-pending-task "form-submit" 1)
(resolve-task "form-submit" "queued")
(reject-task "lookup" "offline")
(resolve-stale-task "lookup" "late")
(expect-canceled-task "lookup" 1)

(tick-interval 1000)
(tick-interval-if-active 1000)
(expect-interval 1000 1)

(expect-cleanup "live search panel cleanup" 1)
```

`resolve-stale-task` is the interesting one: it delivers a result for a request
that has already been superseded. Pair it with an assertion that the UI did
**not** change, and you have locked out an entire class of race condition:

```lisp
(fill (label "Search") "ro")
(fill (label "Search") "roc")
(resolve-stale-task "lookup" "results for ro")
(expect-text (text "Search status: loading") "Search status: loading")
(resolve-task "lookup" "results for roc")
(expect-text (text "Results: results for roc") "Results: results for roc")
```

Task names come from `Signal.fake_task(name, ...)` or, for HTTP, from
`Http.request_task(purpose)` — which registers as `http:send:<purpose>`.

## Browser environment

Location, history, visibility, online status, and storage are all controllable:

```lisp
(test "restored navigation"
  (setup
    (initial-location "/article/keyed-lists")
    (initial-visibility hidden)
    (initial-online offline)
    (local-storage "conduit.jwt" "test-token")
    (session-storage "draft" "hello"))
  (steps
    (navigate "/profile/alice")
    (history-back)
    (history-forward)
    (set-visibility visible)
    (set-online online)
    (expect-current-location "/about")
    (expect-document-title "About")
    (expect-local-storage "conduit.jwt" "test-token")
    (expect-no-local-storage "conduit.jwt")
    (expect-session-storage "draft" "hello")
    (expect-no-session-storage "draft")))
```

The forms in `(setup ...)` run **before** the first render, which
is how you test deep links and restored sessions — exactly the paths that are
awkward to test in a real browser.

A full navigation test:

```lisp
(expect-document-title "Home")
(expect-text (text "You are home") "You are home")
(click (role link :name "Go to About"))
(expect-current-location "/about")
(expect-document-title "About")
(history-back)
(expect-current-location "/")
(expect-text (text "You are home") "You are home")
(history-forward)
(expect-current-location "/about")
(navigate "/nowhere")
(expect-document-title "Not found")
```

## Work budgets

This is the capability with no real equivalent elsewhere: **asserting how much
work an interaction did.**

Call `mark-metrics`, perform an action, then assert exact or maximum deltas:

```lisp
(mark-metrics)
(click (role button :name "Reverse rows"))
(expect-metric-delta rows_reused 4)
(expect-metric-delta rows_created 0)
(expect-metric-delta rows_removed 0)
(expect-metric-delta-at-most stream_nodes_scanned 4096)
(expect-metric-delta signal_record_table_rebuilt 0)
```

That turns "reordering reuses rows instead of rebuilding them" from a claim into
a regression test. If a refactor breaks the keyed-row path, the suite fails —
rather than the app just quietly getting slower.

Commonly useful metrics:

| Metric | Meaning |
| --- | --- |
| `nodes_recomputed` | derived signal transforms that ran |
| `patches_emitted` | DOM patches produced |
| `rows_created` / `rows_removed` / `rows_reused` | keyed-row churn |
| `scopes_created` / `scopes_disposed` | scope lifecycle |
| `events_processed` | events dispatched into the graph |
| `propagation_prunes` | propagations stopped by `is_eq` |
| `stale_task_results_ignored` | superseded task results discarded |
| `active_intervals_synced` | timer bookkeeping |
| `retained_alloc_delta` | retained Roc allocations |
| `host_retained_bytes_delta` | retained host bytes |

The authoritative list is in `src/spec/spec_runner.zig`.

**A practical way to use these:** write the assertion loosely first, run it, read
the actual number from the failure, then pin it. Ratchet it down when you
improve something. `expect-metric-delta-at-most` is the right form for anything
that legitimately varies.

`propagation_prunes` is worth watching specifically — it counts how often
`is_eq` stopped work. A zero where you expected pruning usually means a missing
or wrong equality definition.

For a retained-allocation delta that should not be there, rerun the built native
app with `--trace-allocations`:

```sh
.test-out/bin/signals-my-example --trace-allocations examples/my-example/specs/case.scm
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

In the browser, enabling the runtime's existing `telemetry` option also emits an
`allocation_checkpoint` after each applied command batch. It includes total live
Roc blocks and bytes plus phase-and-size cohorts, so a long-running browser repro
can be captured without a native reproduction or a custom wasm build.

Teardown is also a leak gate. Native specs fail if either the Roc ledger or the
host debug allocator is non-empty after the runtime is dismantled. The wasm
mount harness checks that both exported live-allocation gauges and the HostValue
registry are zero after `unmount`.

## What belongs where

Native specs are the right home for **app semantics**: what the user sees, what
the app requests, what state survives. They are not a browser.

Keep in browser tests instead: exact IME event ordering, CSS layout, real
network behaviour, and anything about actual rendering. This repository has
JavaScript contract tests (`zig build run-test-browser`) and a Node mount
harness for those.

The split is deliberate. Semantics get a fast deterministic suite; genuinely
browser-shaped concerns get a slower one that runs less often.

## Running suites

Individual app:

```sh
roc build --target=arm64mac --output=/tmp/app examples/my-app/main.roc
python3 scripts/spec_driver.py /tmp/app examples/my-app/specs
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
