+++
title = "Testing"
description = "Write .scm specs against the rendered UI, control effects and intervals, and assert how much work an update did, natively and in Chrome."
weight = 9
template = "page.html"
+++

# Testing

An app's behaviour is specified in `.scm` specs: short scripts that click,
type and assert against the rendered UI, the way a user sees it. One spec
runs twice — natively against a model of the DOM, and in headless Chrome
against the real runtime — and both runs must agree.

Specs can also take control of everything that would otherwise depend on
the outside world: HTTP answers, interval ticks, connectivity, page
visibility, history and storage. And they can assert *how much* work an
update did, so a change that makes a keystroke rebuild a whole list fails a
test instead of slipping through.

## How specs run

Specs live in `<app>/specs/*.scm`, one test per file. They are read by one
parser, written in Roc (`test-support/Scm.roc`), which turns the text into a
typed list of steps. Two runners consume that list:

- **The native runner.** The app's `main-test.roc`, built on the test
  platform, mounts the app's `Program` and drives it with the same bytes
  the browser runtime would send: boot data, DOM events and effect results.
  Every assertion reads `Dom.roc`, an oracle that decodes the engine's
  command stream into a small DOM model and shares no code with the engine.
  It is fast (microseconds per spec) and deterministic, and it proves that
  the command stream the engine emitted describes the UI the spec expects.
- **The browser runner.** The same steps, emitted as JSON by the same
  parser, are replayed in headless Chrome against the app's Wasm build and
  `runtime.mjs`. Clicks are real mouse input, `fill` is a real input event,
  history, title and storage are the browser's own. It proves that the
  runtime applies the stream correctly and that real browser events reach
  the app as the native runner modelled them.

Neither runner proves the other's half. The native runner never runs the
JavaScript runtime or real event dispatch; the browser runner is too slow
for long random walks and reads the engine's counters only through its
exports. Run both before you trust a change.

A spec that uses a step a runner cannot honour **fails** in that runner;
nothing is ever skipped or weakened.

A sample app needs only its module and two small entry points. This one
searches over HTTP, with an optional auto-refresh interval:

{{ sample(file="search/Search.roc", region="view") }}

Its effect site issues one request per search or refresh and keeps the
typed result:

{{ sample(file="search/Search.roc", region="requests") }}

`main-web.roc` is the browser build; `main-test.roc` is the native runner,
which hands the same `program` to `SpecRunner`:

{{ sample(file="search/main-test.roc") }}

## Anatomy of a spec

{{ sample(file="search/specs/search.scm", syntax="scheme") }}

A spec file holds exactly one `(test "name" ...)` form:

- `(setup ...)` is optional and comes first. It holds declarative state
  applied before the app mounts: initial location, storage, connectivity,
  visibility, and `manual-effects`.
- `(steps ...)` is required and holds at least one step, run in order from
  a fresh mount.
- `;` starts a comment that runs to the end of the line. Strings accept the
  escapes `\n`, `\r`, `\t`, `\"` and `\\`.

Any malformed form, unknown step, unknown setup form, wrong argument count
or argument of the wrong kind is a parse error naming its file, line and
column. Setup forms are not steps and steps are not setup forms.

### Locators

Steps find elements by what a user or assistive technology sees, never by
CSS selector or DOM position. The first match in document order wins.

| Locator | Matches |
|---|---|
| `(role button :name "Save")` | An element whose explicit `role`, or implicit role, is `button` and whose accessible name is `Save` |
| `(label "Email")` | An element whose `aria-label` is `Email` |
| `(text "Loading")` | A text node whose content is exactly `Loading` |
| `(test-id "status")` | An element whose `data-testid` is `status` |

The implicit roles are `button`, `link` (`a`), `region` (`section`),
`form`, `dialog` and `heading` (`h1`–`h6`). The accessible name is the
`aria-label`, or else the element's text content. Inputs have no implicit
role here, so find controls by `label`: the `Html` controls put their name
in `aria-label` (see [Reference](@/docs/reference.md)). Give text you assert
on a `test-id` with `Engine.test_id`.

## Step reference

This is every form the parser accepts. `LOC` is a locator, `"…"` a string,
`N` a non-negative integer, `BOOL` is `true` or `false`.

### Setup forms

| Form | Effect |
|---|---|
| `(manual-effects)` | Awaited requests wait for `run-effect` instead of running. Declare it in any spec whose app issues HTTP: the native runner always holds requests, but in Chrome without it they reach the real network |
| `(initial-location "/path?q#h")` | The URL the app boots at; must start with `/` |
| `(initial-online online)` | Boot connectivity, `online` or `offline` |
| `(initial-visibility hidden)` | Boot page visibility, `visible` or `hidden` |
| `(local-storage "key" "value")` | Seed local storage before mount |
| `(local-storage-unavailable)` | Every local-storage access throws, as with site data disabled. Seeding storage in the same setup is a spec error |

Intervals never fire on their own in either runner, with or without
`manual-effects`: only `tick-interval` fires them.

### Actions

| Step | What happens |
|---|---|
| `(click LOC)` | Click the element; focus moves to it if it is focusable. A disabled control gets no click |
| `(real-click LOC)` | Chrome's full click: `mousedown`, focus moves, `mouseup`, `click`, then the default action — a checkbox toggles, a radio checks, a submit button submits its form. Fails on a disabled control, or when nothing handles the click and there is no default action |
| `(fill LOC "text")` | Playwright's `fill`: focus the control and deliver the whole value as one `input` event |
| `(change LOC "value")` | Set the value and fire `change`; on a radio or checkbox the value must equal the control's `value`, and it becomes checked |
| `(select-option LOC "value")` | Choose an option of a `<select>`; the option must exist |
| `(check LOC)` / `(uncheck LOC)` | Set a checkbox and fire `change` with `true`/`false`; nothing happens if it is already in that state |
| `(submit LOC)` | Submit a `<form>` |
| `(focus LOC)` / `(blur LOC)` | Move focus, delivering `blur` and `focus` to handlers that listen |

Natively, `click` dispatches only `click`, with no default action; use
`real-click` whenever the default action matters, such as a submit button.
Focus follows Chrome in both runners, so a controlled input's rewritten
value waits for blur while it has focus.

The parser also accepts `key-down`, `pointer-down`, `pointer-up`,
`pointer-enter`, `pointer-leave`, `composition-start`, `composition-end` and
`custom-event`, but no runner honours them yet: a spec that uses one fails.

### Assertions

| Step | Passes when |
|---|---|
| `(expect-text LOC "text")` | The element's text content is exactly `text` |
| `(expect-value LOC "value")` | The control's value is `value` |
| `(expect-checked LOC BOOL)` | The control's checked state is `BOOL` |
| `(expect-disabled LOC BOOL)` | The control's disabled state is `BOOL` |
| `(expect-attr LOC name "value")` | The attribute `name` has that value |
| `(expect-no-attr LOC name)` | The attribute `name` is absent or empty |
| `(expect-visible LOC)` | The locator matches an element in the document |
| `(expect-absent LOC)` | The locator matches nothing |

### Location, history, title and storage

| Step | Meaning |
|---|---|
| `(navigate "/path")` | The user goes to a URL: a new history entry, and every live `Popstate` subscription hears it. Keep it within the app's hash routes: in Chrome, a URL without a `#` is a page load that mounts the app afresh |
| `(history-back)` / `(history-forward)` | The browser's back and forward buttons; fails with no entry to move to |
| `(expect-current-location "/path")` | Path, query and hash equal this (`assert-current-location` is an alias) |
| `(expect-document-title "Title")` | The document title |
| `(expect-local-storage "key" "value")` | Local storage holds `value` at `key` |
| `(expect-no-local-storage "key")` | Local storage has no `key` |

App `Push` and `Replace` requests move the location without a popstate, as
browsers do. Session storage (`session-storage` in setup,
`expect-session-storage`, `expect-no-session-storage`) parses but is not
yet a platform service, so those specs fail.

### Effects

| Step | Meaning |
|---|---|
| `(stub-http "label" :url "/api/x" :status 200 :body "…")` | Stage an HTTP answer; optional `:headers (("name" "value") …)`, default `content-type: application/json`. `:status` is 100–999 |
| `(stub-http-reject "label" :kind network :detail "offline")` | Stage a failure: `network` with the browser's message, or `timeout` with an empty `:detail` |
| `(run-effect N)` | Answer the N-th awaited request the app issued (1-based, in issue order, subscriptions not counted) with the staged answer. It must still be pending, and a reply's `:url` must equal the request's |
| `(expect-pending-effects N)` | Exactly N awaited requests are in flight |
| `(tick-interval MS)` | Deliver one tick to every live `Interval(MS)`; fails when none is live |
| `(tick-interval-if-active MS)` | The same, but a no-op when none is live |
| `(expect-interval MS N)` | Exactly N `Interval(MS)` subscriptions are live |
| `(set-online offline)` | Change connectivity and notify `OnlineChanges` subscribers |
| `(set-visibility hidden)` | Change page visibility and notify `VisibilityChanges` subscribers |
| `(expect-cleanup "name" N)` | The `on_cleanup` site named `name` has run N times |

Stage exactly one answer immediately before each `run-effect`: the browser
runner holds a single staged answer, which the next `run-effect` consumes.
A request that is answered after its owner was disposed is still delivered
to the surviving owner (see [Effects and the browser](@/docs/effects-and-browser.md)),
and a request the app never issued, or that is already answered, fails the
step. There is no step yet that fires a one-shot `Timer`.

In Chrome, `set-online` and `set-visibility` override `navigator.onLine` and
`document.visibilityState` and dispatch the browser's own events, so the
runtime's real listeners run.

This spec checks the auto-refresh interval: it mounts with the checkbox,
ticks, answers the refetch, and is gone when unchecked.

{{ sample(file="search/specs/auto-refresh.scm", syntax="scheme") }}

## Work assertions {#work-budgets}

Work assertions read the engine's own counters, which it returns with every
call. `(mark-metrics)` snapshots them; each following
`(expect-metric-delta METRIC N)` asserts the exact change since the mark,
and `(expect-metric-delta-at-most METRIC N)` an upper bound. A delta without
an earlier mark fails.

{{ sample(file="search/specs/work.scm", syntax="scheme") }}

Assert structural work exactly — elements, rows, scopes, text writes —
because it is the app's observable cost. Bound incidental work, such as how
many app closures were evaluated, with `-at-most`, so an engine improvement
does not fail your spec.

| Metric | Counts |
|---|---|
| `rows_created` | Rows created by mount or keyed reconciliation |
| `rows_removed` | Rows a reconciliation removed (rows disposed with their whole `each` count as disposed scopes instead) |
| `rows_reused` | Old rows a reconciliation kept; a reconciliation whose list equals the old one counts nothing |
| `rows_moved` | Rows moved |
| `create_element` | Elements created |
| `bind_event` | Event listeners bound |
| `set_metadata` | Document title writes |
| `set_text` | Text writes and text nodes created |
| `set_value` / `set_checked` | Control `value` / `checked` the engine set |
| `patches_emitted` | DOM commands of every kind |
| `derived_calls_into_roc` | Evaluations of app closures: holes, conditions, list reads, `derive` inputs, prop reads, watched values, cleanup values |
| `scopes_created` / `scopes_disposed` | `when` and `switch` branches, components and `each` rows mounted / disposed |
| `dirty_source_roots` | State layers written |
| `each_key_hashes` / `each_key_compares` | Keys hashed and full-key comparisons in keyed reconciliation |

Any other metric name is a parse error. Two more steps measure work on one
element or service:

- `(expect-updates LOC N)` — the element was written N times: its creation
  plus every later attribute or text write on it or a text node directly
  inside it. In the work spec above, `results` is created, then shows
  `Searching…`, then the answer: 3.
- `(expect-interval MS N)` and `(expect-cleanup "name" N)` (above) check
  that a disposed scope released its subscriptions and ran its cleanups.

Natively, every work step also checks that the engine's per-command
counters agree with the commands the oracle decoded, so the counters cannot
drift from what was emitted.

## Running specs

The project's tasks run the registered apps' specs:

| Command | Runs |
|---|---|
| `blueprint run spec` | Every app's specs, natively |
| `blueprint run spec -- kanban-board` | One app's specs, natively |
| `blueprint run spec -- --browser kanban-board` | Natively, then in headless Chrome |
| `blueprint run spec -- --filter 'add*' kanban-board` | Only specs whose file name matches the glob |
| `blueprint run check` | The pull-request gate: every app's specs in both runners, the documentation samples' specs, and the rest of the suite |

For an app of your own, build its test entry point and pass it spec files:

- `roc build main-test.roc --output=build/app-specs`
- `build/app-specs spec specs/*.scm` runs them and prints one JSON result
  line per spec, with the failing step's file, line and column;
  `--filter GLOB` selects by file name.
- `build/app-specs spec --emit-steps specs/*.scm` prints the parsed steps
  that the browser runner (`tests/browser/replay.mjs`) replays.

## Fuzzing and soak

Specs check the paths you thought of. For sequences you did not, an app can
add a `main-fuzz.roc` beside its modules: a roc-fuzz target that decodes
arbitrary bytes into a valid session — random events found by exploring the
live DOM — and checks it against an oracle, with every session leak-checked.
The same file declares the app's soak runs: long random walks whose live
allocations must stay flat across repeated round trips.

- `blueprint run check` replays every target's saved examples.
- `blueprint run fuzz -- --time 600 kanban-board` runs a fuzz campaign.
- `blueprint run soak` runs the leak-checked native soaks and a long session
  of every app in Chrome.

When a campaign finds a failure, reduce it to a saved example beside the
target so `check` keeps it fixed. See
[Contributing](@/docs/contributing.md) for the details.
