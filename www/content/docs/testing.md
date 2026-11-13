+++
title = "Testing"
description = "Test decisions as functions with expect, write .scm specs against the rendered UI, control effects and intervals, and assert how much work an update did, natively and in Chrome."
weight = 17
template = "page.html"
+++

# Testing

An app is tested at two levels, and each sees what the other cannot.

- **Its logic is tested as functions.** A component's operations on its own
  type, and the decisions that write shared state, are pure functions, so a
  top-level `expect` checks them with no engine and no browser.
- **Its behaviour is specified in `.scm` specs**: short scripts that click,
  type and assert against the rendered UI, the way a user sees it. One spec
  runs twice — natively against a model of the DOM, and in headless Chrome
  against the real runtime — and both runs must agree.

Specs can also take control of everything that would otherwise depend on
the outside world: HTTP answers, interval ticks, connectivity, page
visibility, history and storage. And they can assert *how much* work an
update did, so a change that makes a keystroke rebuild a whole list fails a
test instead of slipping through.

## Decisions as functions

A decision returns the list of writes its transition makes
([Shared State](@/docs/shared-state.md#decisions)), so its test needs only
the store: `store.after(writes)` applies a list to the store's starting
values as a turn applies it, and `read(cell)` reads a cell of the result.

{{ sample(file="shop/Shop.roc", region="expects") }}

- Put a `##` comment before each `expect`: `roc test` prints it with a
  failure.
- `after` enforces the same rule a turn does: a list that replaces a cell an
  earlier write of the same list wrote fails the `expect`.
- Chain `after` to set a scene: `store.after(first).after(second)`. A start
  that depends on the boot data is `store.with_initial(cell, value)`.
- A table is read like any cell, and its rows with `get`:
  `store.after(writes).read(table).get(key)`.
- `after` ends no turn, so a table keeps its changes:
  `store.after(writes).read(table).inverse()` is one write for each row
  the transition wrote. Chained `after`s add to the same changes.

Run them with `roc test` in the app's directory; it runs every top-level
`expect` in `main.roc` and the modules it imports.

This is the test that sees a transition that left out a reset, or wrote the
wrong cell of the right type. No type checker and no check on the engine
can: both are faithful to what the decision said. A spec then checks that
the right control runs the decision, and what the user sees when it does.

## How specs run

Specs live in `<app>/specs/*.scm`, one test per file. They are read by one
parser, written in Roc (`platform/Scm.roc`), which turns the text into a
typed list of steps. Two runners consume that list:

- **The native runner.** The app's `main.roc` built with
  `--target=x64musl` on Linux, `arm64mac` or `x64mac` on macOS, or `x64win`
  on Windows: the platform bundles the runner, which mounts the
  app's `Program` and drives it with the same bytes
  the browser runtime would send: boot data, DOM events and effect results.
  Every assertion reads `Dom.roc`, an oracle that decodes the engine's
  command stream into a small DOM model and shares no code with the engine.
  It is fast and deterministic, and it proves that the command stream the
  engine emitted describes the UI the spec expects.
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
`wasm32` it is the browser module, and built for your system's native target
(`x64musl`, `arm64mac`, `x64mac` or `x64win`) it is the native spec runner:

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

The parser resolves one environment before either runner mounts the app.
Without setup forms its values are:

| Value | Default |
|---|---|
| Location | `/` |
| Local storage | Available, with no seeded pairs |
| Connectivity | Online |
| Visibility | Visible |
| Declared media query | False unless setup gives its match |

Both runners use these values, including when Chrome's real browser facts
differ. A value that later steps can change uses `initial-…` in setup and
`set-…` in steps; a value fixed for the document uses its name directly.
Storage predates that naming rule: `local-storage` seeds it and the app's
own writes change it. Files are fixtures and `max-output-bytes` is a
deployment limit.

| Form | Effect |
|---|---|
| `(initial-location "/path?q#h")` | The URL the app boots at; must start with `/`. Without it, `/` |
| `(initial-online online)` | Boot connectivity, `online` or `offline` |
| `(initial-visibility hidden)` | Boot page visibility, `visible` or `hidden` |
| `(initial-media "QUERY" BOOL)` | A declared media query's boot match |
| `(local-storage "key" "value")` | Seed local storage before mount |
| `(local-storage-unavailable)` | Every local-storage access throws, as with site data disabled. Seeding storage in the same setup is a spec error |
| `(file "name" "type" "text" [REPEAT])` | Declare a file the steps can give the app: its name, its MIME type, and its contents, `text` repeated `REPEAT` times (once without it) |
| `(max-output-bytes N)` | The most bytes a [task](@/docs/workers.md)'s job may append to its builders, the runtime's `maxOutputBytes` mount option (256 MiB without it) |

Effects never run on their own in a spec: HTTP requests, timers and worker
jobs wait for `run-effect`, and intervals for `tick-interval`. A worker
job's timeout never expires on its own either: `time-out-work` expires it.
Storage reads answer by themselves, from storage.

### Actions

| Step | What happens |
|---|---|
| `(click LOC)` | A real mouse click: `pointermove`, `mousemove`, `pointerdown`, `mousedown`, focus moves to the nearest focusable element (or away), `pointerup`, `mouseup`, `click`, then the default action unless the click handler prevented it — a checkbox toggles and a radio checks (each with `input` and `change`), a submit button submits its form if the form's controls are valid, a link navigates. A prevented `pointerdown` suppresses `mousedown`, `mouseup` and the focus change; `click` still fires. A disabled control gets no click |
| `(real-click LOC)` | The same click, but a disabled control fails the step |
| `(fill LOC "text")` | Playwright's `fill`: focus an enabled text input or textarea and deliver the whole value as one `input` event. A value the control cannot hold (`"2x"` in an `<input type=number>`) fails the step |
| `(change LOC "value")` | Set the value and fire `change`; on a radio or checkbox the value must equal the control's `value`, and it becomes checked |
| `(select-option LOC "value")` | Choose an option of a `<select>`, firing `input` and `change`; the option must exist |
| `(check LOC)` / `(uncheck LOC)` | Click a checkbox or radio that is not in that state; it must then be in it. A radio cannot be unchecked |
| `(submit LOC)` | Submit a `<form>` as `requestSubmit` does: nothing is submitted while a control is invalid |
| `(press LOC "Shift+ArrowDown")` / `(press "Escape")` | Focus the locator if supplied, then keydown and keyup; otherwise use current focus or body. See [Keyboard steps](#keyboard-steps) |
| `(dismiss)` | Press and release Escape at current focus, with normal key prevention and native dismissal |
| `(scroll LOC TOP LEFT)` | Scroll to these nonnegative CSS-pixel offsets and report them; Chrome must reach and retain them |
| `(report-size LOC WIDTH HEIGHT)` | Inject a content-box size report into an element with a size observation |
| `(report-seen LOC yes\|no [PERMILLE])` | Inject visibility into an element with a seen observation; ratio defaults to 1000 for yes, 0 for no |
| `(set-media "QUERY" BOOL)` | Report a declared media query's new match |
| `(focus LOC)` / `(blur LOC)` | Move focus, delivering `blur` and `focus` to handlers that listen. Focusing an element that cannot take focus does nothing |

Focus follows Chrome in both runners: a text control the user changed gets
`change` when it loses focus, and a controlled input's rewritten value waits
for blur while it has focus. The engine's `Focus`, `Blur` and `SelectText`
and `FocusInPlace` commands also update focus and raise the same events after the batch, each
as its own turn. A focus loop stops the instance with `resource_limit`
after 4096 turns in one step. A handler with no listener for its event is not
an error: the event simply reaches nothing, as in a browser.

Hover is not driven by specs. Neither runner delivers `pointerover`,
`pointerout`, `pointerenter`, `pointerleave` or their mouse counterparts;
the browser replay filters them before the app sees them. Hover depends on
layout, including changes under a resting cursor, which the native oracle
cannot model. Contract tests cover dispatch of those events, and a hover
handler's pure logic can be tested as a function. The move events in the
click sequence above are delivered in both runners.

`contextmenu`, `gotpointercapture` and `lostpointercapture` are also outside
the spec grammar. Context-menu timing differs by operating system; capture
lifecycle callbacks are outside the four pointer events modeled below.
The browser replay filters them, while production dispatch and its
contract tests retain them.

### Pointer gestures

| Step | Meaning |
|---|---|
| `(pointer-down LOC ...)` | Press; options `:at X Y`, `:button main\|middle\|secondary`, `:pointer mouse\|pen\|touch`, `:id N`, `:modifiers (shift ctrl alt meta)` |
| `(pointer-move LOC ...)` | Move; options `:at X Y` and `:id N` |
| `(pointer-up LOC ...)` | Release; options `:at X Y` and `:id N` |
| `(pointer-cancel ...)` | Cancel one touch; option `:id N` |

Down defaults to main, mouse and no modifiers. Its id defaults to 1 for
mouse or 2 for pen and touch. Move and up default to id 1; a nonmouse
gesture names its id explicitly on them. Cancel defaults to id 2. Mouse
always uses id 1, which nonmouse pointers cannot use. A second down for
an active id, an up for one not down or a cancel for a nontouch pointer
fails. A buttonless mouse move is allowed. Apps compare active pointer
ids; specs do not assert the browser's numeric choices.

Only one non-touch press (mouse or pen) can be active: Chrome's automation
channel shares their compatibility-mouse target. A second non-touch
gesture fails before input in both runners. Touch and non-touch gestures
cannot overlap either: the driver supports one mouse/pen gesture or a
set of up to 16 touch pointers. A 17th touch fails before input. Local ids
can use the full U32 range: replay maps them to reusable driver contact
slots and separately tracks the browser-assigned pointer ids. Production
pointer dispatch has none of these automation limits.

`X Y` are whole percentages, 0–100, in the nearest zone at or above LOC.
Without `:at`, LOC must itself be a zone (its centre is 50 50) or lie in
no zone (`Outside`). If it lies inside another element's zone, give
`:at` explicitly. Chrome verifies that the point hits LOC or a descendant
and the same nearest zone, and checks the reported fractions exactly.
A nested zone covering the point or a box without positive area fails
the step. A `click` reaching a pointer-kind handler follows the same
centre rule; use pointer steps when it needs `:at`.

A paced move is a [report](#reports): outside a hold it is one frame, and
inside a hold only its newest waiting value per pointer reaches the app.
An up delivers the waiting moves first. Capture changes the event target,
while its reported zone remains the one beneath the point.

Mouse and pen also deliver their mouse and focus events: a main release
clicks, while a nonmain release delivers `auxclick`. A single-contact touch tap delivers
compatibility mouse events after its up; preventing its down suppresses
those mouse events while click still occurs. A moved touch produces none,
as do releases from a set that has contained multiple contacts, until the
last contact ends. Chrome checks `touch-action:none` before a touch
press, and a touch move must change its
logical point; Chrome also rejects a physical move inside its tap slop.
If an up's turn moves or removes the pressed element or an ancestor,
mouseup goes to that node's old parent and no click follows.

The browser input API cancels all touches together. To keep a cancel
specific to its named pointer, both runners reject it when more than one
touch is active. A gesture also cannot cross into a new document: release
or cancel before navigating there. Same-document navigation is allowed.
These are step errors, with no fabricated release or cancellation.

### Assertions

| Step | Passes when |
|---|---|
| `(expect-text LOC "text")` | The element's text content is exactly `text` |
| `(expect-value LOC "value")` | The control's value is `value` |
| `(expect-checked LOC BOOL)` | The control's checked state is `BOOL` |
| `(expect-disabled LOC BOOL)` | The control's disabled state is `BOOL` |
| `(expect-attr LOC name "value")` | The attribute `name` is present with that value. On property-table elements, `value` reads the live value and `checked` reads `"true"`/`"false"`; elsewhere they read ordinary attributes. `disabled` reads `"true"`/`"false"` |
| `(expect-no-attr LOC name)` | The attribute `name` is absent. On property-table elements, assert live `checked` and `value` with their own steps; `disabled` also has its own step |
| `(expect-visible LOC)` | The locator matches an element in the document |
| `(expect-absent LOC)` | The locator matches nothing |
| `(expect-focused LOC)` | The located element is the document's active element |
| `(expect-no-focus)` | No page element holds focus; the active element is the document body |

`expect-updates` counts property commands whose row mirrors an attribute,
including control values and checked state. Both runners count the same
work: the native oracle reads the property commands, and Chrome observes
their mirrored attributes. `patches_emitted` includes `PROP` and `HPROP`.

### Dialogs, popovers and scrolling

| Step | Passes when |
|---|---|
| `(expect-shown LOC hidden\|open\|modal\|popover)` | The live dialog or popover has exactly that shown state |
| `(expect-scroll K LOC into-view\|to)` | The K-th performed explicit scroll command targeted this element and had this kind; K starts at 1 |
| `(expect-scrolls N)` | Exactly N explicit scroll commands were performed in this document |

`expect-visible` tests presence in the document, so a closed dialog or
hidden popover can still match it. Use `expect-shown` for shown state.
Actions on hidden dialog/popover content or outside the top modal fail;
assertions can inspect the inert background. No pixel layout or smooth
scroll completion is asserted. A scroll command targeting a missing
reference is stale and adds no performed scroll.

The manual scroll history keeps the newest 4096 commands, with absolute
U64 ordinals and element identity rather than reusable engine ids. An
assertion for an overwritten command fails explicitly. The history and count reset with a new document, unmount or recovery. At ordinal exhaustion, observation fails without
stopping the app or suppressing its scroll. The browser history uses weak
element references so it cannot retain removed subtrees.

Both runners settle native close and toggle callbacks after mount and
after each step. Browser replay passively tracks pending callbacks and
waits up to 20 seconds; it does not assume a timer tick is enough. A
nonsettling app fails the step. Close and toggle use different browser task
sources, whose relative order is unspecified; assert the settled outcome
and test decisions in both orders. In particular, accept automatic
popover hiding rather than making unrelated auto popovers reopen each
other indefinitely.

The parser emits one activation table for both runners. An actual click,
including a check/uncheck that clicks, grants user activation; a disabled
click or already-satisfied check does not. Nonempty `fill` grants it,
while empty `fill` does not. Every supported `press` except Escape grants
it. Mouse/pen pointer down and touch pointer up grant it; move, cancel,
mouse/pen up, scripted changes, selects, submits and focus do not. A new
document starts without activation. This matters to native dismissal:
preventing one `cancel` can consume the activation that allowed it.

### View transitions

| Step | Checks |
|---|---|
| `(expect-transitions N)` | Exactly N marked batches have been applied in this document |
| `(expect-transition K TYPE ...)` | The one-based K-th marked batch has exactly these types, in this order; an empty type list is allowed |

These assert the engine's request to animate, whether or not the browser
supports transitions or the deployment enables them. Mount never adds a
transition. `view_transitions` checks the same intent as a work counter.

Native and browser observations retain the newest 4096 records and at most
1 MiB of encoded type bytes (four length bytes plus UTF-8 bytes for each
type). Counts and ordinals are absolute U64 values; their JSON representation
is a decimal string. An overwritten ordinal fails with a retained-history
diagnostic. A record larger than that byte allowance clears older history
and is itself unavailable, while the total count still advances. Exhausting
U64 fails observation. None of these limits stops the app or caps the types
it may actually ask the browser to animate.

Chrome replay skips the animation once its update has run and awaits the
runtime's `idle()` until `finished` settles before the next step. Thus a
replayed click meets the final DOM without an overlay. Real animation,
capture boundaries and input during animation are runtime contract tests;
application specs assert the final DOM and transition intent.

### Layout and media

`(initial-media "QUERY" BOOL)` in setup supplies a query's boot match. A
query the program declares but setup omits starts false. Both runners use
these same facts; the page's CSS keeps following the real browser.
`(expect-media-subscriptions "QUERY" N)` checks the live subscriptions;
`(expect-observed N)` checks live size/seen registrations. An element with
both observations contributes two. Disposing a row or scope must release
them before its nodes disappear; the native oracle checks that invariant.

Typed scroll, size, seen and media are reports, honor `hold-reports` and
grant no user activation. An ordinary text-kind scroll remains an
occurrence and drains earlier reports even inside a hold. A repeated scroll to the same position raises
nothing. Size and seen are injected in Chrome too, since the native oracle
has no geometry. Real observer behavior belongs in browser contracts.

A scroll step checks the real Chrome position again after its turn, so it
fails if drawing the window moved the scrollbar. `ScrollTo` with `Start`,
`Px` and `Keep` on a handled scroller updates the oracle and, if changed,
reports its position at the end of the step. Chrome waits a frame and
checks the same position, including raw signed offsets; negative physical
movement cannot pass by rounding or clamping its payload to zero. Prefer
`Instant`: `Smooth`, or `Auto` with CSS
smooth scrolling, can still be intermediate at that check. A handled
scroller means one carrying a typed or text-kind scroll handler.

`ScrollTo` with `End` on a handled scroller, or `ScrollIntoView` inside one,
fails in both runners because its destination depends on layout. Chrome
also fails a step that moved a handled scroller without a scroll step or
modelled command, including a click, focus or drawing that shifted it. The
failure names the element and says to scroll first. The native run alone
cannot detect that mistake; running both proves reachability and stable
scroll geometry.

### Keyboard steps

`press` raises keydown and keyup. If keydown loads a new document, the
driver waits for its app to mount before releasing the key there; it
checks physical evidence for both phases.

`press` uses exact `Control`, `Alt`, `Shift` and `Meta` prefixes. Its one
US-key table is declared in `Scm.roc` and emitted for the browser runner:
printable ASCII, Enter, Escape, Tab, Space, Backspace, Delete, arrows,
Home, End, PageUp, PageDown and F1–F12. There is no `ControlOrMeta`.
Write `Shift+?` and `Shift+A`; omitting required Shift is a parse error,
as is `Shift+a` (use `Shift+A`). A named key may also carry Shift.

Tab moves focus by positive tabindex then document order, skipping disabled,
hidden and inert elements. Enter activates a button or link or implicitly
submits a form. Enter on a file or color input clicks the control instead;
the chooser UI is outside the DOM model, as for a mouse click. Ctrl/Meta
suppresses button, file/color and implicit-form activation;
Alt/Shift retains it. Space activates buttons, checkboxes and radios on keyup,
with any modifiers, if the original control still holds focus and its
pressed ancestry has not been detached.
Prevention suppresses the default. Escape performs native dialog and auto
popover dismissal; function keys and caret-only movement have no modelled
change.

Unprevented modified Enter on a link is refused for any Control, Alt,
Shift or Meta modifier: its navigation, download or new-context default
varies by platform. A keymap that prevents it permits the step. Plain Enter
on a link remains supported, and this driver restriction does not limit
production keyboard handling.

Use `fill` for text entry. A press refuses an unprevented default the native
model cannot reproduce: printable keys and Space without Ctrl/Meta,
Backspace/Delete and Ctrl/Meta+A/C/V/X/Y/Z in text entry, Enter in textarea
or contenteditable, and arrows/Home/End/PageUp/PageDown in selects, radios
and number, range, date, time, month, week or datetime-local inputs. The
refusal rules and their input-type selectors are emitted from `Scm.roc`;
Chrome checks the actual event's `defaultPrevented`. A keymap that prevents
the default permits the step. Composition remains a browser contract test.

The sample checks Escape without losing focus and both ends of a Tab loop:

{{ sample(file="keys/specs/keys.scm", syntax="scheme") }}

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
| `(run-effect N)` | Answer the N-th HTTP request, upload, fetch, timer, worker job or operation on a file the current document issued (1-based, in issue order; port calls share the numbering but are answered with `answer-port` (see [Ports](#ports)); subscriptions, commands and storage reads not counted). It must still be pending. A timer fires; a worker job runs its task (in Chrome in a real worker, natively in a child process that serves the job's effects from the setup files, the step waiting for its result: a task that crashes loses its job with the crash's fault class, and one that has not finished after 30 s fails the step); an HTTP request or an upload takes the staged answer, and an HTTP response's `:url` must equal the request's; a page read, a digest or a file URL is performed on the setup file (see [Files](#files)) |
| `(expect-pending-effects N)` | Exactly N HTTP requests, uploads, fetches, timers, worker jobs, operations on files and port calls are waiting to be answered |
| `(expect-pending-work "task" N)` | Exactly N worker jobs of the task of that name are waiting |
| `(lose-work N FAULT)` | Answer the N-th effect occurrence, a pending worker job, as `WorkLost(FAULT)` without running it. `FAULT` is `contract`, `resource_limit`, `out_of_memory`, `app_crash`, `expect_failed`, `unavailable` or `executor` |
| `(time-out-work N)` | Expire the timeout of the N-th effect occurrence, a pending worker job: it receives `Timeout` without running. A job without a timeout fails the step |
| `(tick-interval MS)` | Deliver one tick to every live `Interval(MS)`; fails when none is live |
| `(tick-interval-if-active MS)` | The same, but a no-op when none is live |
| `(expect-interval MS N)` | Exactly N `Interval(MS)` subscriptions are live |
| `(set-online offline)` | Change connectivity and notify `OnlineChanges` subscribers |
| `(set-visibility hidden)` | Change page visibility and notify `VisibilityChanges` subscribers |
| `(expect-cleanup "name" N)` | The `on_cleanup` site named `name` has run N times |

### Reports

A step normally acts as its own frame: any state reports it raises are
delivered before the next step. `set-online`, `set-visibility` and
`emit-port` on a `Latest` subscription raise reports. To check several
reports meeting before a frame, hold and release them explicitly:

| Step | Meaning |
|---|---|
| `(hold-reports)` | Keep reports waiting until a release or an occurrence |
| `(release-reports)` | Deliver all waiting reports in order and end the hold |
| `(expect-reports-replaced N)` | Exactly N waiting reports have been replaced in this document |

Newer reports from one source replace its waiting value in place. An
occurrence inside a hold, such as a click or an effect result, first
delivers reports queued ahead of it; the hold continues. Assertions read
the current drawn page without releasing reports. Setting an unchanged
connectivity or visibility value raises no report.

A hold belongs to one document. Holding twice, releasing without a hold,
ending a spec while holding or navigating to a new document while holding
fails the step. The replacement count starts at zero in each document.
These steps check the same delivery in both runners; browser contract
tests check real frames and the fallback timer.

This spec sends three revisions before releasing the reports. Only the
newest reaches the app:

{{ sample(file="ports/specs/reports.scm", syntax="scheme") }}

### Answering effects

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

In Chrome, `set-online` and `set-visibility` update the runtime's
`environment` readers and dispatch the browser's own events, so the
runtime's real listeners run. Setting an unchanged value dispatches nothing
and causes no turn. The current environment carries into a later document:
setting offline and then following a link boots the next document offline.
Storage is seeded once per spec, so app writes and removals also survive
navigation. Nondeterministic browser facts must come from a spec or its
stated defaults in both runners.

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
file and range it sends, and `run-effect` answers it with the staged HTTP response.

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
| `rows_created` | Rows created by mount, by an `each` reconciliation or by a table view's window |
| `rows_removed` | Rows a reconciliation removed and rows that left a table view's window (rows disposed with their whole site count as disposed scopes instead) |
| `rows_reused` | Old rows an `each` reconciliation kept; a reconciliation whose list equals the old one counts nothing. A table view compares no list and counts nothing here |
| `rows_updated` | Rows kept whose content was written: a row of an `each` whose item changed, and a drawn row a table view draws before and after the event whose row in the table was written. Pinned beside `rows_created`, `rows_removed` and `rows_moved`, it says exactly which drawn rows of a table view a write woke |
| `rows_moved` | Rows moved |
| `view_transitions` | Host-call batches marked for animation, including result turns; never mount |
| `create_element` | Elements created |
| `bind_event` | Event listeners bound |
| `set_metadata` | Document title writes |
| `set_text` | Text writes and text nodes created |
| `set_value` / `set_checked` | Control `value` / `checked` the engine set |
| `patches_emitted` | DOM commands; excludes `RELEASE` and `TRANSITION`, which do not change the DOM |
| `registrations_released` | `RELEASE` commands emitted for nodes owning document-key registrations or layout observations |
| `derived_calls_into_roc` | Evaluations of app closures: holes, conditions, list reads, `derive` inputs, `remount_on` keys, watched values, cleanup values. For a table view: each read of its query or its window, and each row it places with the query's `keep` and `sort` (two for a written key, the row before and after; every row of the table for a mount or a rebuild) |
| `scopes_created` / `scopes_disposed` | `when` and `switch` branches, `remount_on` bodies, and the rows of `each` and table view sites, mounted / disposed |
| `dirty_source_roots` | What a turn wrote: the local states and the cells. A decision that returns no write counts nothing |
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
pass over a copy of the instance, as if every local state and every cell had
changed: every text and attribute is re-read, every `when`, `switch` and
`remount_on` decides again, every `each` reconciles, every `derive`,
`resource` and effect site re-reads its input, and the pass reaches into
every row. Each compares with its last observation: the emitted value, or
for a shown property the browser-echoed state. After a complete turn the
pass emits nothing. The scratch transition collection starts empty, and a
new request fails the check even if its types duplicate the real call's.
If a write never reached one of its
readers, the pass emits the update the turn should have, and the step fails
naming it:

```text
click: a reader was left stale: a settle pass over every signal emitted
SETTEXT=1; first write: <p data-testid="late">late 0</p> -> <p
data-testid="late">late 1</p> (in test-id "late")
```

A table view keeps itself up to date from the rows each turn wrote, not
by comparing values, so in the same pass every table view is also built from
scratch, for its query and window as they are then, and must equal the one
the engine kept: the same rows, in the same order, in the same window.

A settle failure is an engine defect, not a spec error: the step did what
it says, and the engine left a reader showing an old value. Do not change
the spec to avoid it; reduce it and report it against the engine.

The check needs nothing from the spec, so every spec guards against stale
readers without asserting them. It is an oracle on the engine, not a step:
the browser runner has no equivalent and needs none, since it replays the
same engine. It sees only propagation. A reducer or a decision that writes
the wrong value, or a command the engine encodes wrongly, settles as
faithfully as a correct one; `expect`s and specs catch those.

## Running specs

The project's tasks run the registered apps' specs:

| Command | Runs |
|---|---|
| `blueprint run spec` | Every app's specs, natively |
| `blueprint run spec -- kanban-board` | One app's specs, natively |
| `blueprint run spec -- --browser kanban-board` | Natively, then in headless Chrome |
| `blueprint run spec -- --filter 'add*' kanban-board` | Only specs whose file name matches the glob |
| `blueprint run check` | The pull-request gate: every app's specs in both runners, the documentation samples' specs, and the rest of the suite |

For an app of your own, `roc signals.roc test` in the app's directory
builds its native spec runner for the system it runs on and runs every spec
in `specs/`, printing one line per spec and, for a failure, the step that
did not hold with its file, line and column (see
[Getting Started](@/docs/getting-started.md#test-it)). It exits with 1 when
any spec fails, so CI can run it as it is. The runner builds and behaves
alike on Linux x86-64 (`x64musl`), macOS on Apple silicon (`arm64mac`) or
Intel (`x64mac`), and Windows x86-64 (`x64win`, where the runner is
`build/app-specs.exe`); a spec means the same on each, and in Chrome. By
hand, build the entry point for your system's target and pass the runner
spec files:

- `roc build --target=x64musl main.roc --output=build/app-specs`
- `build/app-specs specs/*.scm` runs them and prints one JSON result line
  per spec, with the failing step's file, line and column; `--filter GLOB`
  selects by file name.
- `build/app-specs --emit-steps specs/*.scm` prints the parsed steps that
  the browser runner (`tests/browser/replay.mjs`) replays.

## Walks

The same runner can walk an app: `build/app-specs --walk 300 specs/*.scm`
mounts it as the first spec's setup says and takes 300 seeded steps
(`--seed N` chooses another sequence). Each step is something a user could
do to a control that is live at that moment, or a service the browser would
perform: answering a pending request from the answers the specs stage,
ticking a live interval, delivering a message a spec emits on a port. After
every step the settle check must pass, and at the end nothing the app
allocated may be left live. A failure names the step and the last things
the walk did.

A walk needs nothing written for it: no entry point of its own, no target
and no harness. Its sequences are ones no spec spells out. It checks the
engine under your app rather than your app's rules, so it knows nothing of
what the app should show: `expect`s and specs say that.

## Fuzzing your own logic

Specs check the paths you thought of. Where an app has pure logic of its
own with a rule you can state, check it over inputs you did not think of
with [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz): a parser
that must read back what its writer wrote, a reducer that must agree with a
simpler model of itself, an invariant that must hold after any sequence of
operations. That is a test of your logic, apart from roc-signals: the
target is an ordinary roc-fuzz app whose platform is a roc-fuzz release,
and it imports your pure modules and nothing of the platform. Keep the
logic you fuzz in modules that import nothing from `pf`, as you would to
test it in any Roc program. A component's module imports the platform for
its view, so operations worth fuzzing belong in a domain module the
component uses.

Name the target for what it checks, `fuzz-<subject>.roc`, beside the
modules it imports. The CSV Converter's `examples/csv-converter/fuzz-csv.roc`
is one: it generates tables of awkward fields and checks that what its
`Csv` module writes reads back, and that reading in chunks of any size reads
the same lines. Build and run one with roc-fuzz's own commands:

```sh
roc build --fuzz fuzz-csv.roc --output=build/fuzz-csv
build/fuzz-csv check                     # its declared examples
build/fuzz-csv explore corpus --time=60  # a minute of exploration
```

A round trip, a spec that takes the app back to where it started, stays an
ordinary spec like any other.
