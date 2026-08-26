+++
title = "Effects, HTTP, and the Browser"
description = "Tasks, fetch, timers, routing, storage, and cleanup — effects as descriptors rather than side effects."
weight = 7
template = "page.html"
+++

# Effects, HTTP, and the Browser

Roc is pure, so your app cannot perform a `fetch`. What it can do is **describe**
one. The host performs the work and feeds the result back into the graph as a
source update, where it propagates exactly like a click.

Two halves to every effect:

- **Sources** — values the host owns and pushes into your graph: task results,
  timer ticks, the current URL, online status, storage values.
- **Commands** — descriptors your tree emits that ask the host to do something:
  start a request, navigate, set the title, write to storage.

## Tasks

A **task** is a named async operation with a `Loading` / `Done` / `Failed`
lifecycle. Create one, fold its status into your own type, and start it with a
command.

```roc
task = Http.get_text_task("dashboard")

status : Signal.Signal(Status)
status = Signal.fold_task(task, Loading, |body| Ready(body), |err| Failed(err))
```

`Signal.fold_task(task, loading_value, on_done, on_failed)` gives you an
ordinary signal — there is no separate "async state" concept to learn.

Start it with a lifecycle sink placed anywhere in your tree:

```roc
Ui.on_mount(|| Http.get_text(task, "/api/dashboard"))
```

Task identity is the pair of *owning scope* and *task source*. That gives you
three behaviours for free:

- **Latest wins.** Starting a request on a task that already has one pending
  cancels the older one. A late result from the cancelled request is discarded,
  not applied. Rapid typing or fast route switching cannot produce a stale
  render.
- **Disposal cancels.** When the owning scope is disposed — a `Ui.when` arm
  closes, a row is removed, the app unmounts — in-flight requests are aborted.
- **No manual bookkeeping.** No `AbortController`, no "is this response still
  relevant?" checks, no cleanup functions returning cleanup functions.

### Deterministic tasks for tests

`Signal.fake_task(name, on_done, on_failed)` creates a task the native test
runner drives directly:

```roc
task = Signal.fake_task("lookup", |value| value, |err| err)
```

```lisp
(expect-pending-task "lookup" 1)
(resolve-task "lookup" "3 results")
(reject-task "lookup" "offline")
```

Use these for examples and for testing async flows without a server.

## HTTP

Two levels of API.

**Text-only, for simple GETs:**

```roc
task = Http.get_text_task("dashboard")
Ui.on_mount(|| Http.get_text(task, "/api/dashboard"))
```

**Full request/response, for everything else** — methods, headers, bodies,
timeouts, and status codes:

```roc
auth_headers : Str -> List(Http.Header)
auth_headers = |token|
    if token.is_empty() {
        []
    } else {
        [{ name: "authorization", value: "Token ${token}" }]
    }

get_request : Str, Str -> _
get_request = |uri, token|
    Http.with_timeout_ms(
        Http.with_headers(
            Http.request_from_method(Http.method_get).with_uri(uri),
            auth_headers(token),
        ),
        8000,
    )
```

Requests and responses use the pinned `roc-lang/http` package types through
thin platform wrappers: `Http.method_*`, `Http.request_from_method`,
`Http.with_uri`, `Http.with_body`, `Http.with_headers`, `Http.add_header`,
`Http.with_timeout_ms`, and the `Http.response_*` accessors.

### Handling responses

**Non-2xx statuses are successes, not failures.** A 404 or 422 resolves as a
`Done` response with that status; only transport-level problems fail. That is
the right split — a validation error is data your UI should render, not an
exception.

`Http.HttpError` is `Network(Str)`, `Timeout`, `Canceled`, `Unsupported(Str)`,
or `ResponseMaterialization(Str)`. Use `Http.error_text` for a display string.

A pattern worth copying — flatten the response into a small plain record first,
then classify it into a domain type:

```roc
ResponseState : { status : U16, body : Str, error : Str, ready : Bool }

response_state : _ -> Signal.Signal(ResponseState)
response_state = |task|
    Signal.fold_task(
        task,
        { status: 0, body: "", error: "", ready: False },
        |response| {
            status: Http.response_status(response),
            body: Str.from_utf8_lossy(Http.response_body(response)),
            error: "",
            ready: True,
        },
        |err| { status: 0, body: "", error: Http.error_text(err), ready: True },
    )
```

Then every endpoint classifies the same shape:

```roc
Remote(a) : [Loading, Ready(a), Failed(Str)]

classify : ResponseState -> Remote(Str)
classify = |response|
    if !response.ready {
        Loading
    } else if !response.error.is_empty() {
        Failed(response.error)
    } else if response.status == 200 {
        Ready(response.body)
    } else {
        Failed("status ${response.status.to_str()}")
    }
```

Conduit uses exactly this across nineteen endpoints. The intermediate record
also sidesteps a compiler stack overflow this used to trigger (roc#9964), which
no longer reproduces on current nightlies.

A `Remote(a)` type like this is worth adopting early. It makes loading, empty,
error, and success states impossible to forget, because the `match` is
exhaustive.

### JSON

> **Escape sequences are not supported yet.** Roc's builtin JSON parser rejects
> `\n`, `\"`, `\\`, `\t`, and `\uXXXX` inside strings. Any API returning
> free-text fields will hit this. Conduit works around it by substituting
> private-use codepoints before parsing and restoring them afterwards
> (`shield_escapes` / `restore_text` in its `Api.roc`); `\uXXXX` remains
> unsupported even then. Plan for this before choosing Roc Signals for an API
> with rich text.

With that caveat, use Roc's builtin `Json`. Declare the record type and derive a
parser:

```roc
parse : Str -> Try({ article : Article }, [InvalidJson(Str), MissingRequiredField(Str)])
parse = Json.parser_camel()
```

`Json.parser_camel()` maps `camelCase` JSON fields to `snake_case` Roc fields.
`Json.to_str(value)` encodes. See
[Conduit's `Api.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples/conduit/Api.roc)
for the full treatment.

### What the browser does

The runtime passes method, headers, body, timeout, and an abort signal to
`fetch`. It does **not** set `credentials`, `redirect`, `mode`, `cache`, or
referrer policy — browser defaults apply, meaning same-origin credentials,
followed redirects, and normal CORS. A CORS denial or DNS failure arrives as
`Http.Network(message)`.

Headers are preserved as ordered pairs including duplicates; lookups are
case-insensitive first-match.

You can intercept tasks entirely in JavaScript by passing a `taskHandler` to
`mountSignalsApp`. Every example on this site uses one to serve deterministic
canned data — Conduit ships a full in-page RealWorld backend
(`www/static/conduit_backend.mjs`) with seeded data, validation envelopes, and
pagination. Unhandled routes fall through to real `fetch`, so the same
WebAssembly binary can point at a real server by changing a base URL.

## Lifecycle sinks

These are `Elem` nodes that render nothing and run commands:

| Sink | Runs |
| --- | --- |
| `Ui.on_mount(to_cmd)` | once, when the owning scope mounts |
| `Ui.on_change(signal, to_cmd)` | whenever the signal's value changes |
| `Ui.on_change_initial(signal, to_cmd)` | on the first mounted value **and** on changes |
| `Ui.on_cleanup(cleanup)` | when the owning scope is disposed |

`on_change` versus `on_change_initial` matters for deep links: use
`on_change_initial` when the very first value must take effect, such as setting
the document title from the URL on a cold load.

Place them anywhere in the tree; they are ordinary children:

```roc
Html.section_c(
    "Feed",
    "grid gap-3",
    [
        Html.paragraph_s(remote.map(status_text)),
        Ui.on_mount(|| Http.start(task, get_request("/api/articles", ""))),
        Ui.on_change(path, |value| Http.start(task, get_request("/api/articles?path=${value}", ""))),
        Ui.on_cleanup(Signal.cleanup("feed cleanup")),
    ],
)
```

`Signal.noop` is a command that does nothing — useful when a branch should not
act:

```roc
Ui.on_change(
    poll_ok,
    |ok| if ok { Http.start(task, request) } else { Signal.noop },
)
```

### Requests follow from state

The idiomatic shape is: **derive a request description, and let a change to it
trigger the fetch.**

```roc
request = { page: page, tag: tag, token: token }.Signal
Ui.on_change(request, |value| Http.start(task, feed_request(value)))
```

You never write "when the user clicks, fetch". You write "the request is a
function of these values", and the host fires when they change. Deduplication
comes free from `is_eq` — an identical request does not re-fire.

The corollary: when the *same* action must fire twice (retry, submitting the
same form again), include a serial number in the derived value so it actually
changes. Conduit's mutation state carries a `favorite_serial` for exactly this.

## Timers

```roc
ticks = Signal.interval(5000)
Ui.on_change(ticks, |_| Http.get_text(task, "/api/dashboard"))
```

`Signal.interval(period_ms)` counts up from zero while its scope is mounted.
Disposal stops it. Combine it with page visibility so background tabs stay quiet:

```roc
visible = Browser.visibility().map(|v| v == Visible)
poll_ok = { online: online, visible: visible }.Signal.map(|v| v.online and v.visible)
```

## Browser environment

Environment values are signals, seeded before the first render — so a deep link
renders the right route immediately, with no post-mount flash.

| Source | Type |
| --- | --- |
| `Browser.location()` | `Signal(Location)` — `{ path, query, hash }` |
| `Browser.visibility()` | `Signal([Visible, Hidden])` |
| `Browser.online()` | `Signal(Bool)` |
| `Browser.local_storage_text(key)` | `Signal(StorageText)` |
| `Browser.session_storage_text(key)` | `Signal(StorageText)` |

And the matching commands: `Browser.push_state`, `Browser.replace_state`,
`Browser.set_title`, `Browser.set_local_storage_text`,
`Browser.set_session_storage_text`, `Browser.remove_local_storage`,
`Browser.remove_session_storage`.

`Location` is deliberately raw: `path` keeps its leading `/`, while `query` and
`hash` omit `?` and `#`. Parsing is your job.

### Routing

There is no router. Routing is a `.map` over the location signal:

```roc
location : Signal.Signal(Browser.Location)
location = Browser.location()

route = location.map(Route.from_location)
title = route.map(Route.title)
```

Render with nested `Ui.when` over the route, intercept link clicks with
`event_policy_prevent_default`, and emit history commands:

```roc
Ui.on_change(route_intent.signal(), |intent| Browser.push_state(Nav.location(intent))),
Ui.on_change_initial(title, Browser.set_title),
```

Auth guards are the same shape — derive a redirect decision and emit
`replace_state`:

```roc
Ui.on_change_initial(
    guard,
    |target|
        match target {
            Redirect(location) => Browser.replace_state(location)
            Stay => Signal.noop
        },
)
```

Conduit implements all of this in ~270 lines of
[`Route.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples/conduit/Route.roc)
plus ~66 lines of `Nav.roc`, covering nine route shapes with query parameters,
deep links, back/forward, per-route titles, and guarded redirects.

> **Static hosting note.** Conduit uses hash-style routes (`#/article/slug`)
> because GitHub Pages has no SPA fallback — every deep link must resolve to one
> real HTML file. With a server that can rewrite unknown paths to `index.html`,
> use clean history paths instead. Both work; the choice is about hosting.

### Storage

Storage reads are declared keys, resolved before first render:

```roc
saved : Signal.Signal(Browser.StorageText)
saved = Browser.local_storage_text("app.draft")
```

`StorageText` is `StorageMissing`, `StorageValue(text)`, or
`StorageUnavailable(message)`. Handle all three — `StorageUnavailable` is what
you get in private browsing modes or when storage is blocked, and an app should
still boot.

Writes are commands:

```roc
Ui.on_change(draft, |text| Browser.set_local_storage_text("app.draft", text))
```

Namespace your keys (`app.draft`, not `draft`) — several apps can share an
origin. Write failures surface as host errors, not as app-visible results.

This is how Conduit restores a session: the JWT and username are declared
storage signals, so a signed-in user is signed in on the very first frame.

## Cleanup

Cleanup is mostly automatic. Disposing a scope cancels its timers and requests
and releases its retained closures. `Ui.on_cleanup(Signal.cleanup("name"))`
registers a *named* cleanup that native specs can assert on:

```lisp
(expect-cleanup "live search panel cleanup" 1)
```

Useful for proving that closing a panel really did tear its work down.

## JavaScript widgets

For things Roc has no vocabulary for — a charting library, a map — mark an
element with `Html.behavior(name)` and register the behaviour at mount:

```roc
Html.div([Html.behavior("traffic-chart"), Html.test_id("chart")], [])
```

```js
await mountSignalsApp({
  wasmUrl: "./app.wasm",
  root,
  behaviors: {
    "traffic-chart": {
      // Called when the element is attached. Return a cleanup function.
      attach(el, { runtime }) {
        draw(el);
        return () => teardown(el);
      },
      // Called when ONE dynamic custom attribute changes. `attrName` is its name.
      update(el, attrName, { runtime }) {
        if (attrName === "data-points") draw(el);
      },
    },
  },
});
```

Note the exact shape — there is no `mount` or `unmount`. Teardown is the
**function you return from `attach`**, and `update` receives a single changed
attribute *name*, not a bag of attributes. If a behaviour is missing an `attach`
function the runtime does nothing and emits a `behavior_missing` telemetry
event, so a wrong shape here fails **silently**. The working reference is
`www/static/service_ops_charts.mjs`.

`update` fires only for dynamic custom attributes — `Html.attr_s` and
`Html.attr_maybe_s` — not for fixed fields like text, class, value, or checked.

The runtime attaches and cleans up behaviours with the scope. Values flow back
into Roc through declared events only — dispatch a `CustomEvent` and receive it
with `Html.on_custom` / `on_detail`. A behaviour is not a general message
channel, deliberately: every value entering the graph does so through a declared
edge.

## Next

[Structuring a Real App](@/docs/app-architecture.md) — how these pieces fit
together at Conduit's scale.
