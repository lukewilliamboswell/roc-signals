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
roc build --target=arm64mac --output=/tmp/app examples/my-app/app.roc
/tmp/app examples/my-app/spec.txt
```

Exit code `0` and no output means everything passed. Failures name the line:

```text
TEST FAILED at line 4: locator did not resolve to one element
```

Targets: `arm64mac`, `x64mac`, `arm64musl`, `x64musl`.

## Locators are semantic

Elements are found the way a user or screen reader finds them — never by CSS
selector or DOM position:

| Locator | Example |
| --- | --- |
| Role and accessible name | `role:button name:"Send invite"` |
| Associated label | `label:"Invite email"` |
| Exact visible text | `text:"Submit status: idle"` |
| Test id | `test_id:"traffic-chart"` |

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

```txt
click role:button name:"Save"
real_click role:button name:"Open note"
fill label:"Message" "draft"
check label:"Accept terms"
uncheck label:"Accept terms"
change label:"Plan" "growth"
select_option label:"Plan" "enterprise"
submit role:form name:"Signup form"
focus label:"Message"
blur label:"Message"
key_down label:"Command search" "Enter" false
pointer_down role:region name:"Release card"
pointer_up role:region name:"Release card"
pointer_enter role:region name:"Drop target"
pointer_leave role:region name:"Drop target"
composition_start label:"Message"
composition_end label:"Message"
custom_event test_id:"traffic-chart" "chart-select" "point-1"
```

**`click` versus `real_click`.** `click` dispatches directly to the target's own
click binding. `real_click` dispatches `pointerdown → pointerup → click` through
the full propagation path — capture, bubble, `self`, and stop policies — and
runs default actions. Use `real_click` for nested controls inside clickable or
draggable parents, and for submit buttons inside forms.

`key_down` takes the key name and a shift-key boolean. `custom_event` sends its
final argument as `event.detail`.

Checkboxes use the checked-change path, so use `check` / `uncheck` — or
`real_click`, which runs the browser's default toggle action. A bare `click` on
a checkbox with no click binding fails with *target has no click binding*.

## Assertions

```txt
expect_visible role:heading name:"Team Checkout"
expect_absent role:region name:"Queue Widget"
expect_text text:"Submit status: sending" "Submit status: sending"
expect_value label:"Invite email" "ops@example.com"
expect_attr label:"Invite email" aria-invalid ""
expect_no_attr label:"Invite email" aria-invalid
expect_checked label:"Accept terms" true
expect_disabled role:button name:"Send invite" true
expect_updates label:"Message" 2
```

`expect_updates` asserts how many times a specific element was patched, summed
across its text, value, checked, and disabled sinks — a direct way to prove that
an unrelated change did *not* touch something.

## Async, deterministically

Tasks and timers are driven by the spec, not by a clock. There is no sleeping
and no polling.

```txt
expect_pending_task "form-submit" 1
resolve_task "form-submit" "queued"
reject_task "lookup" "offline"
resolve_stale_task "lookup" "late"
expect_canceled_task "lookup" 1

tick_interval 1000
tick_interval_if_active 1000
expect_interval 1000 1

expect_cleanup "live search panel cleanup" 1
```

`resolve_stale_task` is the interesting one: it delivers a result for a request
that has already been superseded. Pair it with an assertion that the UI did
**not** change, and you have locked out an entire class of race condition:

```txt
fill label:"Search" "ro"
fill label:"Search" "roc"
resolve_stale_task "lookup" "results for ro"
expect_text text:"Search status: loading" "Search status: loading"
resolve_task "lookup" "results for roc"
expect_text text:"Results: results for roc" "Results: results for roc"
```

Task names come from `Signal.fake_task(name, ...)` or, for HTTP, from
`Http.request_task(purpose)` — which registers as `http:send:<purpose>`.

## Browser environment

Location, history, visibility, online status, and storage are all controllable:

```txt
set_initial_location "/article/keyed-lists"
set_initial_visibility hidden
set_initial_online offline
seed_local_storage "conduit.jwt" "test-token"
seed_session_storage "draft" "hello"

navigate "/profile/alice"
history_back
history_forward
set_visibility visible
set_online online

expect_current_location "/about"
expect_document_title "About"
expect_local_storage "conduit.jwt" "test-token"
expect_no_local_storage "conduit.jwt"
expect_session_storage "draft" "hello"
expect_no_session_storage "draft"
```

The `set_initial_*` and `seed_*` commands run **before** the first render, which
is how you test deep links and restored sessions — exactly the paths that are
awkward to test in a real browser.

A full navigation test:

```txt
expect_document_title "Home"
expect_text text:"You are home" "You are home"
click role:link name:"Go to About"
expect_current_location "/about"
expect_document_title "About"
history_back
expect_current_location "/"
expect_text text:"You are home" "You are home"
history_forward
expect_current_location "/about"
navigate "/nowhere"
expect_document_title "Not found"
```

## Work budgets

This is the capability with no real equivalent elsewhere: **asserting how much
work an interaction did.**

Call `mark_metrics`, perform an action, then assert exact or maximum deltas:

```txt
mark_metrics
click role:button name:"Reverse rows"
expect_metric_delta rows_reused 4
expect_metric_delta rows_created 0
expect_metric_delta rows_removed 0
expect_metric_delta_at_most stream_nodes_scanned 4096
expect_metric_delta signal_record_table_rebuilt 0
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
improve something. `expect_metric_delta_at_most` is the right form for anything
that legitimately varies.

`propagation_prunes` is worth watching specifically — it counts how often
`is_eq` stopped work. A zero where you expected pruning usually means a missing
or wrong equality definition.

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
roc build --target=arm64mac --output=/tmp/app examples/my-app/app.roc
/tmp/app examples/my-app/spec.txt
```

Repository suites:

```sh
python3 scripts/test.py native --native always   # all native specs
python3 scripts/test.py roc-check                # type-check every app
python3 scripts/test.py wasm                     # build every app to wasm
python3 scripts/test.py browser                  # JavaScript contract tests
python3 scripts/test.py                          # everything
```

## Next

[Under the Hood](@/docs/under-the-hood.md) — what actually crosses the
WebAssembly boundary.
