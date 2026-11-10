+++
title = "Testing"
description = "Write .scm specs against the rendered UI, control effects and intervals, and assert how much work an update did, natively and in Chrome."
weight = 14
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
parser, written in Roc (`platform/Scm.roc`), which turns the text into a
typed list of steps. Two runners consume that list:

- **The native runner.** The app's `main.roc` built with
  `--target=x64musl`: the platform bundles the runner, which mounts the
  app's `Program` and drives it with the same bytes
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

Both runners implement every step of the language with the same meaning,
and a check fails the build if the grammar gains a step the browser runner
has no handler for. Nothing is ever skipped or weakened, and no spec is
allowed to pass in one runner and fail in the other.

A sample app needs only its module and two small entry points. This one
searches over HTTP, with an optional auto-refresh interval:

{{ sample(file="search/Search.roc", region="view") }}

Its effect site issues one request per search or refresh and keeps the
typed result:

{{ sample(file="search/Search.roc", region="requests") }}

Its one entry point, `main.roc`, binds that `program` as `main`; built for
`wasm32` it is the browser module, and built for `x64musl` it is the native
spec runner:

{{ sample(file="search/main.roc") }}

## Anatomy of a spec

{{ sample(file="search/specs/search.scm", syntax="scheme") }}

A spec file holds exactly one `(test "name" ...)` form:

- `(setup ...)` is optional and comes first. It holds declarative state
  applied before the app mounts: initial location, storage, connectivity
  and visibility.
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
| `(text "Loading")` | The element holding a text node whose content is exactly `Loading` |
| `(test-id "status")` | An element whose `data-testid` is `status` |

The implicit roles are `button`, `link` (`a`), `region` (`section`),
`form`, `dialog` and `heading` (`h1`–`h6`). The accessible name is the
`aria-label`, or else the element's text content. Inputs have no implicit
role here, so find controls by `label`: the `Html` controls put their name
in `aria-label` (see [Reference](@/docs/reference.md)). Give text you assert
on a `test-id` with `Engine.test_id`.

## Step reference

This is every form the parser accepts, and both runners implement every
one: Chrome is the reference for what a step does, and the native runner
models it. `LOC` is a locator, `"…"` a string, `N` a non-negative integer,
`BOOL` is `true` or `false`.

### Setup forms

| Form | Effect |
|---|---|
| `(initial-location "/path?q#h")` | The URL the app boots at; must start with `/`. Without it, `/` |
| `(initial-online online)` | Boot connectivity, `online` or `offline` |
| `(initial-visibility hidden)` | Boot page visibility, `visible` or `hidden` |
| `(local-storage "key" "value")` | Seed local storage before mount |
| `(local-storage-unavailable)` | Every local-storage access throws, as with site data disabled. Seeding storage in the same setup is a spec error |
| `(file "name" "type" "text" [REPEAT])` | Declare a file the steps can give the app: its name, its MIME type, and its contents, `text` repeated `REPEAT` times (once without it) |
| `(max-output-bytes N)` | The most bytes a [task](@/docs/workers.md)'s job may append to its builders, the runtime's `maxOutputBytes` mount option (256 MiB without it) |

Effects never run on their own in a spec: HTTP requests, timers and worker
jobs wait for `run-effect`, and intervals for `tick-interval`. A worker
job's deadline never expires on its own either: `time-out-work` expires it.
Storage reads answer by themselves, from storage.

### Actions

| Step | What happens |
|---|---|
| `(click LOC)` | A real mouse click: `mousedown`, focus moves to the nearest focusable element (or away), `mouseup`, `click`, then the default action unless the click handler prevented it — a checkbox toggles and a radio checks (each with `input` and `change`), a submit button submits its form if the form's controls are valid, a link navigates. A disabled control gets no click |
| `(real-click LOC)` | The same click, but a disabled control fails the step |
| `(fill LOC "text")` | Playwright's `fill`: focus an enabled text input or textarea and deliver the whole value as one `input` event. A value the control cannot hold (`"2x"` in an `<input type=number>`) fails the step |
| `(change LOC "value")` | Set the value and fire `change`; on a radio or checkbox the value must equal the control's `value`, and it becomes checked |
| `(select-option LOC "value")` | Choose an option of a `<select>`, firing `input` and `change`; the option must exist |
| `(check LOC)` / `(uncheck LOC)` | Click a checkbox or radio that is not in that state; it must then be in it. A radio cannot be unchecked |
| `(submit LOC)` | Submit a `<form>` as `requestSubmit` does: nothing is submitted while a control is invalid |
| `(focus LOC)` / `(blur LOC)` | Move focus, delivering `blur` and `focus` to handlers that listen. Focusing an element that cannot take focus does nothing |

Focus follows Chrome in both runners: a text control the user changed gets
`change` when it loses focus, and a controlled input's rewritten value waits
for blur while it has focus. A handler with no listener for its event is not
an error: the event simply reaches nothing, as in a browser.

### Assertions

| Step | Passes when |
|---|---|
| `(expect-text LOC "text")` | The element's text content is exactly `text` |
| `(expect-value LOC "value")` | The control's value is `value` |
| `(expect-checked LOC BOOL)` | The control's checked state is `BOOL` |
| `(expect-disabled LOC BOOL)` | The control's disabled state is `BOOL` |
| `(expect-attr LOC name "value")` | The attribute `name` is present with that value; `checked` and `disabled` read `"true"`/`"false"` and `value` the live value |
| `(expect-no-attr LOC name)` | The attribute `name` is absent. `checked`, `disabled` and `value` are live state, asserted with their own steps |
| `(expect-visible LOC)` | The locator matches an element in the document |
| `(expect-absent LOC)` | The locator matches nothing |

### Location, history, title and storage

| Step | Meaning |
|---|---|
| `(navigate "/path")` | The user goes to a URL. One that differs from the current URL only in its `#fragment` stays in the document: a new history entry, and every live `Popstate` subscription hears it. Any other URL loads a new document, where the app mounts afresh with the same local storage |
| `(history-back)` / `(history-forward)` | The browser's back and forward buttons within the document; fails with no entry to move to, or when the entry belongs to another document |
| `(expect-current-location "/path")` | Path, query and hash equal this |
| `(expect-document-title "Title")` | The document title |
| `(expect-local-storage "key" "value")` | Local storage holds `value` at `key` |
| `(expect-no-local-storage "key")` | Local storage has no `key` |

App `Push` and `Replace` requests move the location without a popstate, as
browsers do.

### Effects

| Step | Meaning |
|---|---|
| `(stub-http "label" :url "/api/x" :status 200 :body "…")` | Stage an HTTP answer; optional `:headers (("name" "value") …)`, default `content-type: application/json`. `:status` is 100–999. Staging a second answer before one is used fails |
| `(stub-http-reject "label" :kind network :detail "offline")` | Stage a failure: `network` with the browser's message, or `timeout` with an empty `:detail` |
| `(run-effect N)` | Answer the N-th HTTP request, upload, fetch, timer, worker job or operation on a file the current document issued (1-based, in issue order; port calls share the numbering but are answered with `answer-port` (see [Ports](#ports)); subscriptions, commands and storage reads not counted). It must still be pending. A timer fires; a worker job runs its task (in Chrome in a real worker, natively in a child process that serves the job's effects from the setup files, the step waiting for its result: a task that crashes loses its job with the crash's fault class, and one that has not finished after 30 s fails the step); an HTTP request or an upload takes the staged answer, and a reply's `:url` must equal the request's; a page read, a digest or a file URL is performed on the setup file (see [Files](#files)) |
| `(expect-pending-effects N)` | Exactly N HTTP requests, uploads, fetches, timers, worker jobs, operations on files and port calls are waiting to be answered |
| `(expect-pending-work "task" N)` | Exactly N worker jobs of the task of that name are waiting |
| `(lose-work N FAULT)` | Answer the N-th effect occurrence, a pending worker job, as `WorkLost(FAULT)` without running it. `FAULT` is `contract`, `resource_limit`, `out_of_memory`, `app_crash`, `expect_failed`, `unavailable` or `executor` |
| `(time-out-work N)` | Expire the deadline of the N-th effect occurrence, a pending worker job: it is answered `Timeout` without running. A job without a deadline fails the step |
| `(tick-interval MS)` | Deliver one tick to every live `Interval(MS)`; fails when none is live |
| `(tick-interval-if-active MS)` | The same, but a no-op when none is live |
| `(expect-interval MS N)` | Exactly N `Interval(MS)` subscriptions are live |
| `(set-online offline)` | Change connectivity and notify `OnlineChanges` subscribers |
| `(set-visibility hidden)` | Change page visibility and notify `VisibilityChanges` subscribers |
| `(expect-cleanup "name" N)` | The `on_cleanup` site named `name` has run N times |

Stage one answer immediately before each `run-effect` that answers an HTTP
request: both runners hold a single staged answer, which that `run-effect`
consumes. A request that is answered after its owner was disposed is still
delivered to the surviving owner (see [Effects and the browser](@/docs/effects-and-browser.md)),
and a request the app never issued, or that is already answered, fails the
step.

A worker job is numbered with the HTTP requests and timers, in issue order,
so the order of the steps is the order the jobs finish: `(run-effect 2)`
then `(run-effect 1)` says the newer job finishes first. `lose-work` and
`time-out-work` let a spec state how the app handles a job that fails
without writing a task that fails (see [Workers](@/docs/workers.md#testing)
for a sample); a task that really crashes on some
input loses its job under `run-effect`, with the class `app_crash`, in both
runners. A job cancelled by disposing its site is no longer pending, and the
`effects_cancelled` metric below counts it.

In Chrome, `set-online` and `set-visibility` override `navigator.onLine` and
`document.visibilityState` and dispatch the browser's own events, so the
runtime's real listeners run.

This spec checks the auto-refresh interval: it mounts with the checkbox,
ticks, answers the refetch, and is gone when unchecked.

{{ sample(file="search/specs/auto-refresh.scm", syntax="scheme") }}

### Files

| Step | Meaning |
|---|---|
| `(choose-files LOC "name" …)` | The user chooses the named setup files in the file input |
| `(drop-files LOC "name" …)` | The user drops the named setup files on the element |
| `(paste-files LOC "name" …)` | The user pastes the named setup files into the element |
| `(expect-files N)` | The app holds exactly N [file handles](@/docs/files.md) |
| `(expect-upload N "name" START LEN)` | The N-th effect occurrence is a pending upload whose body is `LEN` bytes from `START` of the setup file `name` |
| `(expect-saved K "name" "text")` | The K-th file (from 1) the app saved in this document (`File.save`) was saved under `name` and held exactly `text` |
| `(expect-saves N)` | The app saved exactly N files in this document |

A spec writes out the contents of the files it uses, so both runners give
the app the same bytes; a step that names a file no `file` form declares
fails.
`expect-files` counts handles, so it shows when the app lets a file go:
after the state that held it is written without it, or its scope is
disposed. In Chrome a chosen file gets its type from its name, and the step
fails if that is not the type the spec declares. See
[Files](@/docs/files.md#testing) for a sample.

Operations on a file wait for `run-effect` like any awaited request, and
are then performed on the setup file's bytes: a page read answers them (or
`TooLarge` over the default 8 MiB), a digest is computed for real (natively
by the runner's host, in Chrome by WebCrypto), so a spec asserts the same
digest in both runners, and a file URL is answered with a URL of the
runner's own making, so a spec asserts what the app does with it rather
than its text. An upload is an HTTP request: `expect-upload` checks which
file and range it sends, and `run-effect` answers it with the staged reply.

Every worker job runs the same way, whatever its [task](@/docs/workers.md)'s
body does: `run-effect` runs it, in Chrome in a real worker and natively in
a child process whose effects read the setup files' bytes, and a
preparation's task is prepared afresh for each job natively, which is what
any reuse in the browser must equal. The files its answer holds are then
handles the app holds, with the bytes the job built, in both runners, so a
later read, digest or save of them gives the same bytes. A `File.fetch`
takes the staged `stub-http` answer, its body becoming the file. Neither
runner downloads anything: a save is logged, and `expect-saved` reads its
name and contents.

### Ports

Neither runner calls the page's [port](@/docs/ports.md) handlers: a spec
answers a port call as it answers an HTTP request, and plays the
JavaScript's side of a subscription. A call is numbered with the other
awaited requests.

| Step | Meaning |
|---|---|
| `(expect-port-call N "port" "json")` | The N-th effect occurrence is a pending call on `port` whose message is exactly `json` |
| `(answer-port N reply "json")` | Answer that call with `json`, as written (so a spec can answer what the app's type does not accept) |
| `(answer-port N throw "message")`, `(answer-port N too-large)`, `(answer-port N timeout)` | Answer it `Threw`, `TooLarge` or, for a call with a timeout, `Timeout` |
| `(emit-port "port" "json")` | Deliver a message to every live subscription on `port`; fails when none is live |
| `(close-port "port")`, `(fail-port "port" "message")` | End every live subscription on `port` with `Closed` or `Threw` |
| `(expect-port-subscriptions "port" N)` | Exactly N subscriptions on `port` are live |
| `(expect-port-sent "port" K "json")` | The K-th command (from 1) sent on `port` carried exactly `json` |
| `(expect-port-sends "port" N)` | Exactly N commands were sent on `port` |

`run-effect` on a port call fails and names `answer-port`. Commands are
not awaited, so `expect-pending-effects` does not count them. See
[Ports](@/docs/ports.md#testing) for a sample.

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
| `effects_issued` | Awaited requests issued (HTTP, timers, storage reads, subscriptions, worker jobs); a refused request is not issued |
| `effects_delivered` | Results delivered to a reaction, a `Refused` answer included |
| `effects_stale` | Results dropped because their request was no longer in flight |
| `effects_refused` | Requests refused because the in-flight table was full |
| `effects_cancelled` | Requests stopped because their site was disposed or superseded |
| `effects_reparented` | Admitted requests handed to a surviving ancestor when their site was disposed |
| `effects_skipped` | Writes a reparented result made to state that no longer exists |

Any other metric name is a parse error. Two more steps measure work on one
element or service:

- `(expect-updates LOC N)` — the element was written N times: its creation
  plus every later attribute or text write on it or a text node directly
  inside it. In the work spec above, `results` is created, then shows
  `Searching…`, then the answer: 3.
- `(expect-interval MS N)` and `(expect-cleanup "name" N)` (above) check
  that a disposed scope released its subscriptions and ran its cleanups.

Natively, every work step also checks that the engine's per-command
counters agree with the commands the oracle decoded, and that every issued
request was one `FX` command and every cancelled one a `CANCEL`, so the
counters cannot drift from what was emitted.

## The settle check

After mount and after every step, the native runner also asks the engine
whether the step left anything stale. The engine runs one more observation
pass over a copy of the instance, as if every layer had changed: every text
and attribute is re-read, every `when` and `switch` decides again, every
`each` reconciles, every `derive`, `resource`, component prop and effect site
re-reads its input, and the pass reaches into every row and component. Each
of those compares with what it last emitted, so after a complete turn the
pass emits nothing. If a write never reached one of its readers, the pass
emits the update the turn should have, and the step fails naming it:

```text
click: a reader was left stale: a settle pass over every layer emitted
SETTEXT=1; first write: <p data-testid="late">late 0</p> -> <p
data-testid="late">late 1</p> (in test-id "late")
```

A settle failure is an engine defect, not a spec error: the step did what
it says, and the engine left a reader showing an old value. Do not change
the spec to avoid it; reduce it and report it against the engine.

The check needs nothing from the spec, so every spec guards against stale
readers without asserting them. It is an oracle on the engine, not a step:
the browser runner has no equivalent and needs none, since it replays the
same engine. It sees only propagation. A handler that writes the wrong value,
or a command the engine encodes wrongly, settles as faithfully as a correct
one; specs and the fuzz models catch those.

## Running specs

The project's tasks run the registered apps' specs:

| Command | Runs |
|---|---|
| `blueprint run spec` | Every app's specs, natively |
| `blueprint run spec -- kanban-board` | One app's specs, natively |
| `blueprint run spec -- --browser kanban-board` | Natively, then in headless Chrome |
| `blueprint run spec -- --filter 'add*' kanban-board` | Only specs whose file name matches the glob |
| `blueprint run check` | The pull-request gate: every app's specs in both runners, the documentation samples' specs, and the rest of the suite |

For an app of your own, build its entry point for the native target and pass
the runner spec files:

- `roc build --target=x64musl main.roc --output=build/app-specs`
- `build/app-specs specs/*.scm` runs them and prints one JSON result line
  per spec, with the failing step's file, line and column; `--filter GLOB`
  selects by file name.
- `build/app-specs --emit-steps specs/*.scm` prints the parsed steps that
  the browser runner (`tests/browser/replay.mjs`) replays.

## Fuzzing and soak

Specs check the paths you thought of. For sequences you did not, an app can
add a `main-fuzz.roc` beside its modules, built with `roc build --fuzz` on the
repository's fuzz platform (`platform/fuzz.roc`, which needs roc-fuzz's own
entry and host, so it cannot share the app's `main.roc`): a roc-fuzz target that decodes
arbitrary bytes into a valid session — random events found by exploring the
live DOM — and checks it against an oracle, with every session leak-checked.
The walk's `after` hook (`Soak.settled`) runs the settle check after every
event, so a generated session that leaves a reader stale fails at the event
that did it, in any app, with no model of the app. The same file declares the
app's soak runs: long random walks whose live allocations must stay flat
across repeated round trips. While a worker job is pending, the walk also
answers it now and then: usually with a stand-in made from the app's own
pure function (a walk has no host to run a job's effects on, so the target
passes `task.stand_in(f)` to `Soak.walk_with`, and the answer goes through
`SpecRunner.answer_work`), so that function runs inside the leak check (and
one that crashes on an input the UI produced is a finding), sometimes by
losing it, timing it out or leaving it pending for disposal to cancel. The
task's real body runs in the specs, in both runners. A stand-in cannot carry
files: only a worker holds a file's bytes, so a stand-in whose input or
answer holds a `File` is a contract error. An app whose tasks take or give
files fuzzes its pure parts instead, as the Log Explorer's target fuzzes
its index against a model of the whole text, and leaves its tasks to the
specs and the Chrome tests. The settle check runs on a copy that is freed
before the walk goes on, so it never counts as a leak, and it stays out of
the measured round trips.

Fixed apps only exercise the nestings they contain. The `structure` target
(`fuzz/structure/main.roc`) decodes its bytes into a site tree instead,
nesting `state`, `derive`, `resource`, `when`, `switch`, `each`, components
and effect sites, then clicks through it and answers its timers, with the
settle check after every step. In its pure mode every button writes the root
state, so the rendered page must also equal a fresh mount started at the
root's current value.

- `blueprint run check` replays the parser target's saved examples, and
  `blueprint run check-slow` every target's.
- `blueprint run fuzz -- --time 600 kanban-board` runs a fuzz campaign.
- `blueprint run check-slow` also runs a long session of every app in
  Chrome.

When a campaign finds a failure, reduce it to a saved example beside the
target so `check` keeps it fixed. See
[Contributing](@/docs/contributing.md) for the details.
