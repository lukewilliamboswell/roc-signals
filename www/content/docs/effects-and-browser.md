+++
title = "Effects and the Browser"
description = "HTTP, storage, timers, navigation, title, focus, scrolling and cleanup, through one typed effect channel."
weight = 10
template = "page.html"
+++

# Effects and the Browser

Apps never call JavaScript. Everything that reaches outside the page — a
request, a timer, the URL, local storage, focus — is a value of type
`Engine.Request` that an *effect site* asks for, and every result comes back as
a value of type `Engine.Result` delivered in a turn of its own. A result is
anything delivered for a request, including a timeout, refusal or timer firing.
An answer is a result the other side produced, such as an HTTP response, a job's
output or its own failure, or a port call's return. Most of the snippets come
from `www/samples/effects.roc`, a search page that keeps its state in one local
state.

## Effect sites

An effect site watches a signal and turns it into a list of requests:

- `Engine.watch(v, plan, reaction)` issues `plan(value)` at mount and again
  every time `v` changes;
- `Engine.watch_changes(v, plan, reaction)` issues only on changes after mount.

The watched signal is any `Signal`: a local state's, a cell's, or a `map` of
several. The *reaction* says what a result writes. For local state it is a
reducer, built with `st.on_result(f)`, which receives the state, the value
the request was issued for, and the result:

{{ sample(file="effects.roc", region="model") }}

{{ sample(file="effects.roc", region="http") }}

Passing the issued-for value is what makes out-of-order answers safe. If the
user typed again before the first answer arrived, the reaction sees an old
query and ignores the answer. Which answer wins is your decision, made in
ordinary Roc.

Because sites issue on *change*, two equal values in a row issue once. A
request the user's action asks for, which must be sent again for an equal
value, is posted to an outbox instead.

### Sending when the user acts

A save, an add or an order is asked for by a click, not by a value
changing. Keep an `Engine.Outbox(item)` in the state, made with
`Engine.outbox({})`; the handler posts to it with `box.post(item)`, and
`Engine.on_post(box, plan, reaction)` issues `plan(item)` in the turn of the
post:

{{ sample(file="effects.roc", region="post") }}

- Each post is sent, an item equal to the last one included: two outboxes
  are equal only when they hold the same post.
- The reaction is given the item it was posted with, so several posts can be
  in flight and each answer knows its own.
- Nothing is sent at mount, and nothing is ever cancelled for a later post,
  as with `watch_changes`. Disposing the site follows the usual rules: an HTTP
  request or a port call still completes, in the nearest surviving owner.
- The reducer that changes the state posts in the same step, so an `expect`
  sees both: `box.last()` is `Unposted` or `Posted(item)`.
- Post at most once per turn to one outbox. A change that sends several
  things posts a list (`Engine.Outbox(List(Note))`, sent as
  `|notes| notes.map(request)`). A second post in the same turn would
  replace the first before the site saw it, so it is a contract error.

An outbox can be a cell of the store as well: a decision posts to it with
`box_cell.update(|box| box.post(item))`, as the shop below does.

### Results that write the store

When a result changes shared state, the reaction is a decision: one pure
function from the result to a list of writes
([Shared State](@/docs/shared-state.md#decisions)). `Engine.react(decide)`
gives `decide` the value the request was issued for and the result.
`Engine.react_by(v, decide)` also gives it the value `v` holds when the
result arrives, read once and before anything is written. This is the
shop's order, from `www/samples/shop/Shop.roc`:

{{ sample(file="shop/Shop.roc", region="answer") }}

`ordered` is tested as a function, with no request made
([Shared State](@/docs/shared-state.md#starting-again) shows its `expect`),
and a spec stages the server's answer:

{{ sample(file="shop/specs/check-out.scm", syntax="scheme") }}

`first.also(second)` makes one reaction of two, both run for one result: a
component's own reducer, and the reaction its owner handed it.

## Superseding sites

`watch` and `watch_changes` never cancel what they issued. When only the newest
value's answer matters — a search box, the selected item — say so with a
superseding site instead of filtering answers in the reaction:

- `Engine.watch_latest(v, plan, reaction)` issues like `watch`, but before it issues
  for a new value it cancels everything it still has in flight for earlier
  ones: the fetch is aborted, a subscription stops, a timer is cleared, and a
  late answer never reaches the reaction. A `plan` that returns `[]` makes a
  change a pure cancel.
- `Engine.resource(input, { init, pending, plan, resolve }, body)` keeps the
  results in a signal that `body` reads like a derived signal. `pending(s, a)`
  sets the signal when the input changes, in the same turn (a loading state
  that still holds the previous answer, say); `resolve(s, a, res)` sets it
  from each result for the current input. Readers below do no work when
  either returns an equal value. `Worker.resource` and `Port.resource` (taught
  in [Workers](@/docs/workers.md#showing-its-answer) and
  [Ports](@/docs/ports.md)) are resources that follow one answer, held as
  an `Engine.Remote`.

- `Engine.gather(asker, inputs, body)` asks one request per input, all at
  once, and keeps the answers in an `Engine.Gathered` signal: `jobs`, each
  input's job as `Working`, `Answered(output)` or `Failed(error)`, and
  `all`, an `Engine.Remote` of the whole list in input order once no job is
  working (or the first failure). `Worker.gather` is this for a task's jobs;
  see [Workers](@/docs/workers.md#one-question-several-jobs).

Both cancel only on a new value. Disposing them follows the same rules as any
effect site: subscriptions and timers stop, and an admitted request still
completes in the nearest surviving owner, where its write to the disposed
resource is skipped.

A reaction that compares a serial, or the value it was issued for, with the
state to drop an old answer is asking for `watch_latest`: let the site cancel the
old request instead. Keep `watch` and such a check only where cancelling an
in-flight request would be wrong, such as a write the server must finish.

An `Engine.Remote` signal is read with `remote.answered()`, the latest answer
as a `Try`: `?? default` shows a fallback, `.map_ok(f)` picks from it, and a
handler matches `Ok(output)`. It keeps the answer while a newer request is
pending, and is `Err(NoAnswer)` before the first answer and after a
failure. To combine the answer with state outside the resource (the page a
list is on, say), lift that state in and map both:
`v.lift().map2(r, |s, remote| ...)`.

## Requests

| Request | Result |
|---|---|
| `Http({ method, url, headers, body, timeout_ms })` | `Http({ status, headers, body })`, `Network(message)` or `Timeout` |
| `StorageGet(key)` | `Value(text)` or `Missing` |
| `Timer(ms)` | `Fired`, once |
| `Interval(ms)` | `Fired`, until the site is disposed |
| `Popstate` | `Location(url)` on every back or forward |
| `OnlineChanges` | `Online(Bool)`, the newest reported state per frame |
| `VisibilityChanges` | `Visible(Bool)`, the newest reported state per frame |
| `MediaChanges(query)` | `Matches(Bool)`, the newest reported state per frame; query must be declared in `ProgramProps.media` |
| `Work({ task, input, files, timeout_ms, on_dispose, on_cancel, prepared })` | `Work({ output, files })`, `WorkLost(fault)` or `Timeout`: a job of a registered task in a Web Worker. Apps use the typed `Worker` module instead; see [Workers](@/docs/workers.md) |
| `ReadBytes({ file, max_bytes })`, `ReadUtf8({ file, max_bytes })` | `FileBytes(bytes)` or `FileText(text)`, or `FileFailed(error)`: a file read into the page. Made with `File.read_bytes` and `File.read_utf8`; see [Files](@/docs/files.md) |
| `Upload({ method, url, headers, body, timeout_ms })` | As `Http`, with a [file](@/docs/files.md) as the body; made with `File.upload` |
| `Sha256(file)`, `ObjectUrl(file)` | `Digest(bytes)` or `FileUrl(url)`, or `FileFailed(error)`: made with `File.sha256` and `File.object_url`; see [Files](@/docs/files.md) |
| `Fetch({ method, url, headers, timeout_ms })` | `Fetched({ status, headers, body })` with the body as a [file](@/docs/files.md), `Network(message)`, `Timeout` or `FileFailed(TooLarge)`: made with `File.fetch`, read with `Engine.fetched`; see [Files in Tasks](@/docs/files-in-tasks.md) |
| `PortCall({ port, message, timeout_ms })` | `PortAnswer(message)` or `PortFailed(failure)`, once. Made by a typed [port](@/docs/ports.md) call |
| `PortSubscribe({ port, message })` | `PortAnswer(message)` for every message, or `PortFailed(failure)`, until the site is disposed or the JavaScript ends it. Made by a typed port subscription |
| `Self` | `Now`, in a follow-up turn |
| `Push(url)`, `Replace(url)`, `Title(text)`, `StorageSet(key, value)`, `StorageRemove(key)`, `Focus(ref)`, `Blur(ref)`, `SelectText(ref)`, `ApplyValue(ref)`, `FocusInPlace(ref)`, `ScrollIntoView(ref, props)`, `ScrollTo(ref, props)`, `Save({ file, name })` (made with `File.save`), `PortCommand({ port, message })` (made by a typed port command) | None: commands, the tags of `Engine.Command` |

`Engine.http_text(res)` reads an HTTP result as the body of a 2xx response,
or a typed `HttpError`: `Network(message)`, `Timeout`, `Status(code)` or
`Refused`. Match on `Http` directly when you need the headers or want to
classify statuses yourself. `timeout_ms` of `0` means no timeout; the most the
runtime will arm is ten minutes.

To see where a worker job's time goes and how busy the pool is, read the
runtime's monitor; see [Monitoring Workers](@/docs/worker-monitoring.md).

## Commands

Commands are emitted and forgotten, so their reaction is `Engine.ignore({})`:

{{ sample(file="effects.roc", region="commands") }}

## Startup data

Values the app needs before its first render come in the boot data.
`Engine.program_boot` declares the storage keys to read, and receives the URL,
those values, and whether the browser is online, the page visible and local
storage usable:

{{ sample(file="effects.roc", region="boot") }}

When local storage is unavailable (disabled site data, a throwing
`localStorage`), `boot.storage_available` is false, the boot storage is empty
and writes persist nothing, so the app can tell the user.

`Engine.program_store` takes the same configuration for an app with a store,
and hands the boot data both to the function that starts the store and to
the view (see [Shared State](@/docs/shared-state.md#starting-values-from-the-boot-data)).

Both functions accept defaulted `ProgramProps`: omit `storage_keys` for
none, `max_inflight` for 32 and `media` for no queries, or pass `{}` for
all defaults.

A page embedding an app can supply `environment.online()` and `visible()`
readers, called at boot and when the corresponding browser event answers a
live subscription. Both return booleans. `environment.matchMedia(query)`
is called for each declared query at boot and when a media subscription
starts. It returns an object with Boolean `matches` and `addEventListener`
and `removeEventListener` methods. The subscription retains that object
and reads `matches` when its `change` event arrives.

Omitted readers use the browser through the runtime's window and document.
Report scheduling also reads `visible()` to choose a frame or the hidden
page's microtask drain. Tests can supply fixed facts while exercising the
real subscription listeners.

Keep services in their own options: `storage` provides reads and writes,
`fetch` performs HTTP requests and `ports` supplies port handlers. The URL
comes from the document's location, and `max…` options cap deployment work.
Unknown environment keys, non-functions and failed boot reads refuse
mount; a reader that throws or returns the wrong type later stops the
instance with an `executor` fault.

## Navigation

{{ sample(file="effects.roc", region="routing") }}

Keep the app's navigation *intent* separate from the current location, so
that following the back button updates the location without pushing a new
entry: post each place the app asks to go to an outbox, and push what is
posted. Links inside the app should use a click handler with the `prevent`
policy (`Engine.on_with("click", { prevent: True }, ...)`) so the browser does not navigate on
its own.

In an app with several pages the location and the outbox are cells of the
store, so a link anywhere asks to go somewhere with one write, and the move
itself is one decision. [Conduit](@/examples/conduit.md) is built this way.

## Subscriptions and lifetime

Connectivity, visibility, media and a port's `Latest` messages report current
state. They wait for the next animation frame; a newer waiting report
from the same subscription replaces the earlier one in place. A visible
page given no frames drains within 100 ms, and a hidden page drains at the
end of the reporting task.

Clicks, key presses, interval ticks, final request results and a port's
`Every` messages are occurrences. Each is delivered separately. An
occurrence first delivers reports queued ahead of it, so a click sees the
latest state reported before that click. Reports raised after it wait
behind it. An `Every` port message joins this order when its subscription's
turn comes; reports raised while it waited in the port's own queue come
first.

The runtime captures a report's value when it arrives. Cancelling its
subscription drops waiting reports without delivering them. Use
[`hold-reports` and `release-reports`](@/docs/testing.md#reports) in a spec
to state what a frame of reports should do.

Subscriptions (`Interval`, `Popstate`, `OnlineChanges`, `VisibilityChanges`,
`MediaChanges`,
a port subscription), timers, operations on files on the page (`ReadBytes`,
`ReadUtf8`, `Sha256`, `ObjectUrl`) and worker jobs belong to their site.
Disposing the site — because its branch switched or its row left a list —
cancels them:

{{ sample(file="effects.roc", region="subscriptions") }}

Requests whose answer may matter after the site has gone are not cancelled
when it goes: `Http`, `Upload`, `Fetch`, `StorageGet`, port calls, and the
jobs of a task that says `on_dispose: Keep` (see
[Workers](@/docs/workers.md#lifetimes)). They are handed to the nearest
surviving ancestor, and the reaction runs there when the answer arrives.
Writes to local states that were disposed with the site are skipped. Writes
to cells of the store are made as they would have been: the store is not
disposed with anything. Only unmounting the whole app abandons such a
request.

## Focus

Focus is a command on a named reference. Mark the element with
`Engine.ref(name)` and ask for `Focus(name)`, `Blur(name)` or
`SelectText(name)`. The request is resolved at the end of the turn, so it can
target an element the same turn created:

{{ sample(file="effects.roc", region="focus") }}

`Engine.ref_s(name_signal)` lets the name follow a signal, including a row's
key in an `each` or table view. A rename changes only the engine's reference
map and writes nothing to the DOM. The empty name names nothing, so only a
selected row need hold a reference. A name is an address you build for a
command; the row's identity remains its key.

Two live references may not hold the same nonempty name. The engine checks
the names mounted or renamed at the end of the turn, before resolving
focus, and reports a contract error naming the name and both construction
sites. A departing row and an entering row can share a name during a turn
as long as only one holds it when the turn ends.

A name that is no longer mounted is counted stale. It can leave in the
same turn that asks for it, so this is not a contract error. Focusing an
element that cannot take focus leaves focus where it was. Both spec runners
apply focus commands and let you assert the outcome with `expect-focused`
and `expect-no-focus`.

### Scrolling and focus in place

`FocusInPlace(name)` moves focus with the browser's scrolling prevented.
Pair it with an explicit scroll when revealing a validation problem:

{{ sample(file="effects.roc", region="scroll") }}

`Engine.scroll_into_view(name, props)` defaults `block` and `inline` to
`Nearest` and `behavior` to `Auto`. Alignments are `Start`, `Center`, `End`
and `Nearest`; behavior is `Auto`, `Instant` or `Smooth`. Its narrow return
tag fits both a request plan and a cleanup's command plan.

`ScrollTo(name, { top, left, behavior })` scrolls the named element. Each
edge is `Keep`, `Start`, `End` or `Px(U32)`. Left is distance from the
logical start edge, including RTL; the browser resolves `End` when
it performs the command. Both scroll commands run after the whole batch,
in order with focus and other commands. They use the same reference map
and stale-name count as focus, and await no result. Layout stays in the
browser. Specs assert the command performed with
[`expect-scroll`](@/docs/testing.md#dialogs-popovers-and-scrolling).

## Scrolling and layout

Layout arrives as reports that handlers write into ordinary state or cells.
`import pf.Layout` supplies three plain records:

| Attach function | Payload | Source |
|---|---|---|
| `Html.on_scroll(handler)` | `Layout.Scroll { top, left }` | The element's offsets when its scroll event is raised |
| `Html.on_size(handler)` | `Layout.Size { width, height }` | The element's content box, observed with ResizeObserver |
| `Html.on_seen(props, handler)` | `Layout.Seen { intersecting, ratio_permille }` | IntersectionObserver entry and exit, with a ratio from 0 to 1000 |

{{ sample(file="layout.roc", region="observations") }}

Offsets and dimensions are U32 rounded CSS pixels. Left is distance from
the container's start edge, including RTL. Negative offsets, including
column-reverse and overscroll, clamp to zero. Seen defaults to observing
on-screen entry and exit. `ahead: True` also admits an element one screen
before it enters view, using both root and scroll margins; on browsers
without scroll-margin support a nested sentinel reports later, when seen.

Each is a report source: the newest value per element and handler (scroll)
or element and kind (size/seen) waits for a frame. Size reports drain when
the observer's callback ends, before paint. Disposing a scope releases its
observations; a row releases the observations on its template elements
together. Observations take no awaited request slot and have no fixed
row-count cap.

A scrolling table view writes its window from these reports. Its spacer
height must come from row count, independent of which rows are drawn, and
its scroller must set `overflow-anchor: none`. Drawing another window must
not move the scrollbar. Likewise, an observed box must take its size from
its container rather than from what its size handler draws. Otherwise the
app can keep creating a report each frame; the platform cannot infer which
CSS should change. [Table windows](@/docs/tables-and-views.md#following-a-scrollbar)
show the fixed-height pattern. Sizes and visibility are observations;
there is no on-demand measurement request or variable-height row model.

### Media preferences

Declare each query in `ProgramProps.media` before boot reads it. There are
at most 32 distinct queries, each 1–256 UTF-8 bytes. `Engine.boot_media`
returns `Ok(matches)` or `Err(Undeclared)`, so the first figure can already
use the preferred colors. `MediaChanges(query)` then reports changes:

{{ sample(file="layout.roc", region="media") }}

An undeclared subscription is a contract error naming its query and site.
Subscriptions use the ordinary in-flight bound and can answer `Refused`.
A page's `environment.matchMedia` reader defaults to the browser's
`window.matchMedia`. Specs set this reader's facts with `initial-media` and
`set-media`; they do not change the page's own CSS media rules.
[Log Explorer](@/examples/log-explorer.md) fits its viewer to the reported
height and colors its Roc-built timeline from a declared color-scheme query.

## Cleanup

`Engine.on_cleanup(name, v, plan)` runs when its scope is disposed, in the
disposing turn, with the last value of `v`. Its plan returns a list of
`Engine.Command`: the requests that are emitted and forgotten, the last row
of the table under [Requests](#requests). A request that awaits a result
would outlive its owner, and `Command` has no such tag, so a cleanup that
asks for one does not compile.

{{ sample(file="effects.roc", region="cleanup") }}

A command written as a tag (`Title("Search")`) fits a list of commands and
a list of requests alike, and so does one built by `File.save` or by a port
command's `send`. A function of your own that builds a command for a
cleanup returns `Engine.Command`, and a plan written as a named function
returns `List(Engine.Command)`.

Specs can count cleanup runs by name with `expect-cleanup`;
`Engine.cleanup(name)` is a cleanup that only counts.

## Third-party widgets

A JavaScript widget, such as a chart, is integrated as a standard custom
element. The app renders the element with an ordinary attribute holding the
widget's input — `Engine.element("plume-chart", [Engine.attr_s("data-figure",
json)], [])` — and a script on the page defines the element with
`customElements.define`, redrawing when the attribute changes and cleaning up
when it is removed. The engine and runtime see an ordinary element and an
ordinary attribute write, so nothing app-specific enters the platform. The
[Status Page](@/examples/status-page.md) example draws its charts this way with
[Plume](https://github.com/lukewilliamboswell/plume), each setting the layout's
`ui_revision: Preserve(name)` so a viewer's zoom survives the redraws. Each
change of the attribute is a whole redraw: build the figure from page state the
app keeps bounded, and from a `derive` that changes only when the figure should.

A widget answers the way a form control does, because an event reaches the
app only as text: the element sets its own `value` and dispatches a bubbling
`change` event, and the app hears it with an ordinary handler such as
`Html.on_change(st.set_value_by(answer, reducer))`, which also reads a value
of the page (the answer the chart was drawn from) when the event fires. The
shared `plume-chart` element does this for a click on a point when it has
`data-click="x"`: its value is the point's x as Plotly gives it, on a date
axis a time such as `2026-11-11 12:05` (or the date alone at midnight). A
spec stands in for the widget with `(change LOC "text")`, which sets the
element's value and fires `change` in both runners. The
[Log Explorer](@/examples/log-explorer.md) opens its viewer at the minute a
click on its timeline names this way.

## Bounds

- At most 32 awaited requests are in flight per app (set `max_inflight` in
  `program_boot` or `program_store` to change it). A request beyond the bound is not sent: its
  reaction receives `Refused` in a follow-up turn.
- Follow-up turns (`Self` and refusals) may chain at most 64 deep per event:
  a follow-up whose reaction leads to another follow-up, and so on. A deeper
  chain is a feedback loop, such as retrying a refused request while the
  table is still full, and stops the app with a contract error. How many
  follow-ups one turn queues does not count: thousands of rows that each
  fetch at mount, nearly all of them refused, are fine.
- As a backstop against a loop that multiplies, where each follow-up leads
  to two or more, one event runs at most 64 follow-up turns per in-flight
  slot (at least 4096) beyond those its own turn queued. More is a resource
  limit. The follow-ups the event's own turn queued are never counted, so
  the bound is reached only by follow-ups that lead to follow-ups: a loop,
  or a reaction to a follow-up that itself mounts thousands of rows that
  fetch.
- An HTTP timeout is capped at 600 seconds.
- An outbox takes one post per turn; a second is a contract error.
- The runtime queues at most 4096 events while applying a batch. A drain
  also delivers at most 4096 turns before returning to idle. Beyond either
  bound the app stops with `resource_limit`; the second catches a focus
  loop that raises only one further event at a time. The native runner
  applies the same turn bound to each step.
