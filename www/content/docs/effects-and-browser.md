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

Because sites issue on *change*, two equal values in a row issue once. To
repeat a request for an equal value, include a counter in the watched value.

## Superseding sites

`watch` and `on_change` never cancel what they issued. When only the newest
value's answer matters — a search box, the selected item — say so with a
superseding site instead of filtering answers in the reaction:

- `Engine.latest(v, plan, reaction)` issues like `watch`, but before it issues
  for a new value it cancels everything it still has in flight for earlier
  ones: the fetch is aborted, a subscription stops, a timer is cleared, and a
  late answer never reaches the reaction. A `plan` that returns `[]` makes a
  change a pure cancel.
- `Engine.resource(input, { init, begin, plan, fold }, body)` keeps the
  answers in a layer that `body` reads like a `derive` value. `begin(s, a)`
  sets the layer when the input changes, in the same turn (a loading state
  that still holds the previous answer, say); `fold(s, a, res)` folds each
  answer for the current input into it. Readers below do no work when either
  returns an equal value.

Both cancel only on a new value. Disposing them follows the same rules as any
effect site: subscriptions and timers stop, and an admitted request still
completes in the nearest surviving owner, where its write to the disposed
layer is skipped.

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
| `Work({ program, input, deadline_ms })` | `Work(output)`, `WorkLost(fault)` or `Timeout`: a registered pure program run on bytes in a Web Worker |
| `Self` | `Now`, in a follow-up turn |
| `Push(url)`, `Replace(url)`, `Title(text)`, `StorageSet(key, value)`, `StorageRemove(key)`, `Focus(ref)`, `Blur(ref)`, `SelectText(ref)` | None: commands |

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
entry. Links inside the app should use a handler with the `click:prevent`
event (`Engine.on("click:prevent", ...)`) so the browser does not navigate on
its own.

## Subscriptions and lifetime

Subscriptions (`Interval`, `Popstate`, `OnlineChanges`, `VisibilityChanges`),
timers and work belong to their site. Disposing the site — because its branch
switched or its row left a list — cancels them:

{{ sample(file="effects.roc", region="subscriptions") }}

Requests that are already in flight (`Http`, `StorageGet`) are not cancelled
when their site goes. They are handed to the nearest surviving ancestor, and
the reaction runs there when the answer arrives. Writes to states that were
disposed with the site are skipped. Only unmounting the whole app abandons
them.

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
- At most 64 follow-up turns (`Self` and refusals) run per event. More is
  treated as a feedback loop and stops the app with a contract error.
- An HTTP timeout is capped at 600 seconds.
