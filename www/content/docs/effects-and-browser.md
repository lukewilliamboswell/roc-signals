+++
title = "Effects and the Browser"
description = "HTTP, storage, timers, navigation, title, focus and cleanup, through one typed effect channel."
weight = 7
template = "page.html"
+++

# Effects and the Browser

Apps never call JavaScript. Everything that reaches outside the page — a
request, a timer, the URL, local storage, focus — is a value of type
`Engine.Req` that an *effect site* asks for, and every answer comes back as a
value of type `Engine.Res` delivered in a turn of its own. The snippets come
from `www/samples/effects.roc`, a search page.

## Effect sites

An effect site watches a value and turns it into a list of requests:

- `Engine.watch(v, plan, reaction)` issues `plan(value)` at mount and again
  every time `v` changes;
- `Engine.on_change(v, plan, reaction)` issues only on changes after mount.

The reaction is a reducer over one state, built with `st.on_result(f)`. It
receives the state, the value the request was issued for, and the result:

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

A save, an add or a write to a store is asked for by a click, not by a value
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
  as with `on_change`. Disposing the site follows the usual rules: an HTTP
  request or a port call still completes, in the nearest surviving owner.
- The reducer that changes the state posts in the same step, so an `expect`
  sees both: `box.last()` is `Unposted` or `Posted(item)`.
- Post at most once per turn to one outbox. A change that sends several
  things posts a list (`Engine.Outbox(List(Write))`, sent as
  `|writes| writes.map(request)`). A second post in the same turn would
  replace the first before the site saw it, so it is a contract error.

## Superseding sites

`watch` and `on_change` never cancel what they issued. When only the newest
value's answer matters — a search box, the selected item — say so with a
superseding site instead of filtering answers in the reaction:

- `Engine.latest(v, plan, reaction)` issues like `watch`, but before it issues
  for a new value it cancels everything it still has in flight for earlier
  ones: the fetch is aborted, a subscription stops, a timer is cleared, and a
  late answer never reaches the reaction. A `plan` that returns `[]` makes a
  change a pure cancel.
- `Engine.resource(input, { init, pending, plan, resolve }, body)` keeps the
  answers in a layer that `body` reads like a `derive` value. `pending(s, a)`
  sets the layer when the input changes, in the same turn (a loading state
  that still holds the previous answer, say); `resolve(s, a, res)` sets it
  from each answer for the current input. Readers below do no work when
  either returns an equal value. `Worker.derive` and `Port.derive` (taught
  in [Workers](@/docs/workers.md#showing-its-answer) and
  [Ports](@/docs/ports.md)) are resources that follow one answer, held as
  an `Engine.Remote`.

- `Engine.gather(asker, inputs, body)` asks one request per input, all at
  once, and keeps the answers in an `Engine.Gathered` layer: `jobs`, each
  input's job as `Working`, `Answered(output)` or `Failed(error)`, and
  `all`, an `Engine.Remote` of the whole list in input order once no job is
  working (or the first failure). `Worker.gather` is this for a task's jobs;
  see [Workers](@/docs/workers.md#one-question-several-jobs).

Both cancel only on a new value. Disposing them follows the same rules as any
effect site: subscriptions and timers stop, and an admitted request still
completes in the nearest surviving owner, where its write to the disposed
layer is skipped.

A reaction that compares a serial, or the value it was issued for, with the
state to drop an old answer is asking for `latest`: let the site cancel the
old request instead. Keep `watch` and such a check only where cancelling an
in-flight request would be wrong, such as a write the server must finish.

An `Engine.Remote` layer is read with `remote.answered()`, the latest answer
as a `Try`: `?? default` shows a fallback, `.map_ok(f)` picks from it, and a
handler matches `Ok(output)`. It keeps the answer while a newer request is
pending, and is `Err(NoAnswer)` before the first answer and after a
failure. To combine the answer with state outside the layer (the page a
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
| `OnlineChanges` | `Online(Bool)` on every change |
| `VisibilityChanges` | `Visible(Bool)` on every change |
| `Work({ task, input, files, deadline_ms, on_dispose, on_cancel, prepared })` | `Work({ output, files })`, `WorkLost(fault)` or `Timeout`: a job of a registered task in a Web Worker. Apps use the typed `Worker` module instead; see [Workers](@/docs/workers.md) |
| `ReadBytes({ file, max_bytes })`, `ReadUtf8({ file, max_bytes })` | `FileBytes(bytes)` or `FileText(text)`, or `FileFailed(error)`: a file read into the page. Made with `File.read_bytes` and `File.read_utf8`; see [Files](@/docs/files.md) |
| `Upload({ method, url, headers, body, timeout_ms })` | As `Http`, with a [file](@/docs/files.md) as the body; made with `File.upload` |
| `Sha256(file)`, `ObjectUrl(file)` | `Digest(bytes)` or `FileUrl(url)`, or `FileFailed(error)`: made with `File.sha256` and `File.object_url`; see [Files](@/docs/files.md) |
| `Fetch({ method, url, headers, timeout_ms })` | `Fetched({ status, headers, body })` with the body as a [file](@/docs/files.md), `Network(message)`, `Timeout` or `FileFailed(TooLarge)`: made with `File.fetch`, read with `Engine.fetched`; see [Files in Tasks](@/docs/files-in-tasks.md) |
| `PortCall({ port, message, timeout_ms })` | `PortReply(message)` or `PortFailed(failure)`, once. Made by a typed [port](@/docs/ports.md) call |
| `PortSubscribe({ port, message })` | `PortReply(message)` for every message, or `PortFailed(failure)`, until the site is disposed or the JavaScript ends it. Made by a typed port subscription |
| `Self` | `Now`, in a follow-up turn |
| `Push(url)`, `Replace(url)`, `Title(text)`, `StorageSet(key, value)`, `StorageRemove(key)`, `Focus(ref)`, `Blur(ref)`, `SelectText(ref)`, `Save({ file, name })` (made with `File.save`), `PortCommand({ port, message })` (made by a typed port command) | None: commands |

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

## Navigation

{{ sample(file="effects.roc", region="routing") }}

Keep the app's navigation *intent* separate from the current location, so
that following the back button updates the location without pushing a new
entry: post each place the app asks to go to an outbox, and push what is
posted. Links inside the app should use a handler with the `click:prevent`
event (`Engine.on("click:prevent", ...)`) so the browser does not navigate on
its own.

## Subscriptions and lifetime

Subscriptions (`Interval`, `Popstate`, `OnlineChanges`, `VisibilityChanges`,
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
Writes to states that were disposed with the site are skipped. Only
unmounting the whole app abandons them.

## Focus

Focus is a command on a named reference. Mark the element with
`Engine.ref(name)` and ask for `Focus(name)`, `Blur(name)` or
`SelectText(name)`. The request is resolved at the end of the turn, so it can
target an element the same turn created:

{{ sample(file="effects.roc", region="focus") }}

## Cleanup

`Engine.on_cleanup(name, v, plan)` runs when its scope is disposed, in the
disposing turn, with the last value of `v`. It may only issue commands: a
request that awaits a result would outlive its owner, so asking for one is a
contract error.

{{ sample(file="effects.roc", region="cleanup") }}

Specs can count cleanup runs by name with `expect-cleanup`;
`Engine.cleanup(name)` is a cleanup that only counts.

## Third-party widgets

A JavaScript widget, such as a chart, is integrated as a standard custom
element. The app renders the element with an ordinary attribute holding the
widget's input — `Engine.element("plume-chart", [Engine.attr_v("data-figure", json)], [])` —
and a script on the page defines the element with `customElements.define`,
redrawing when the attribute changes and cleaning up when it is removed. The
engine and runtime see an ordinary element and an ordinary attribute write, so
nothing app-specific enters the platform. The
[Status Page](@/examples/status-page.md) example draws its chart this way with
[Plume](https://github.com/lukewilliamboswell/plume).

## Bounds

- At most 32 awaited requests are in flight per app (set `max_inflight` in
  `program_boot` to change it). A request beyond the bound is not sent: its
  reaction receives `Refused` in a follow-up turn.
- Follow-up turns (`Self` and refusals) may chain at most 64 deep per event:
  a follow-up whose reaction leads to another follow-up, and so on. A deeper
  chain is a feedback loop, such as retrying a refused request while the
  table is still full, and stops the app with a contract error. How many
  follow-ups one turn queues does not count: a hundred rows that each fetch
  at mount, most of them refused, are fine. As a backstop, one event runs at
  most 64 follow-up turns per in-flight slot (at least 4096).
- An HTTP timeout is capped at 600 seconds.
- An outbox takes one post per turn; a second is a contract error.
