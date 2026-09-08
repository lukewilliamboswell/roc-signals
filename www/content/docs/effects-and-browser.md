+++
title = "Effects, HTTP, and the Browser"
description = "Start requests, handle results, follow browser state, and give effects the right lifetime."
weight = 7
template = "page.html"
+++

# Effects, HTTP, and the Browser

A Signals app describes external work with commands. The host executes those
commands and returns results through signals. HTTP responses, timer ticks, and
browser changes use the same propagation engine as UI events.

The API separates inputs from requests to do work:

- **Sources** — values the host owns and pushes into your graph: task results,
  timer ticks, the current URL, online status, storage values.
- **Commands** — descriptors your tree emits that ask the host to do something:
  start a request, navigate, set the title, write to storage.

## Tasks

A task represents an asynchronous result with a `Loading` / `Done` / `Failed`
lifecycle. Its name is useful in tests and diagnostics; it is not a global ID.
Create a task, fold its status into your own type, and start it with a command.
For example, given `Status : [Loading, Ready(Str), Failed(Str)]`:

```roc
task = Http.get_text_task("dashboard")

status : Signal.Signal(Status)
status = Signal.fold_task(task, Loading, |body| Ready(body), |err| Failed(err))
```

`Signal.fold_task(task, loading_value, on_done, on_failed)` gives you a
signal that you can map and render like any other signal.

Include a lifecycle sink in the returned element tree to start it on mount:

```roc
Ui.on_mount(|| Http.get_text(task, "/api/dashboard"))
```

Starting another request for the same task source in the same owning scope
cancels its pending request. Late results from the cancelled request are ignored.
Independent requests need independent task sources or owning scopes. Disposing
the request's scope also cancels it.

Cancellation prevents stale results from updating the graph. It does not undo
work a server may already have performed, such as saving an article.

A request belongs to the scope of the action or lifecycle sink that starts it.
Keeping its task-result signal in a longer-lived scope does not extend the
request's lifetime. In particular, if the new `Loading` value removes the
action's own `Ui.when` branch, that request is canceled in the same turn. Keep
the request-starting action in a scope that survives Loading when the request
must continue; disabling its button need not remove that scope.

### Deterministic tasks for tests

`Signal.cancel(task)` cancels its active request and publishes the task
constructor's typed cancellation error through ordinary propagation. Canceling a
source with no pending request does nothing. A canceled request's late result is
ignored, and a later start gets a fresh request ID. HTTP tasks publish `Canceled`;
the string-based fake task model passes `"canceled"` to its error decoder.
Cancellation cannot reverse external work that already committed. Native host
capacity refusal publishes the constructor's declared resource error and
supersedes any older request for that source; it does not start new host work.

`Signal.fake_task(name, on_done, on_failed)` creates a task the native test
runner drives directly:

```roc
task = Signal.fake_task("lookup", |value| value, |err| err)
Ui.on_mount(|| Signal.start_str(task, "query"))
```

```lisp
(expect-pending-task "lookup" 1)
(resolve-task "lookup" "3 results")
```

Each resolution or rejection needs a pending request. In a separate test, use
`reject-task` to exercise the failure path. Native specs can also drive HTTP
tasks; see [testing](@/docs/testing.md) for their response payloads.

## HTTP

Choose based on whether you need response metadata:

**Text-only, for simple GETs:**

```roc
task = Http.get_text_task("dashboard")
Ui.on_mount(|| Http.get_text(task, "/api/dashboard"))
```

**Full request/response, for everything else** — methods, headers, bodies,
timeouts, and status codes:

```roc
get_request : Str -> _
get_request = |uri|
    Http.with_timeout_ms(
        Http.with_headers(
            Http.request_from_method(Http.method_get).with_uri(uri),
            [{ name: "accept", value: "application/json" }],
        ),
        8000,
    )

task = Http.request_task("articles")
Ui.on_mount(|| Http.start(task, get_request("/api/articles")))
```

Requests and responses use the pinned `roc-lang/http` package types through
thin platform wrappers: `Http.method_*`, `Http.request_from_method`,
`Http.with_uri`, `Http.with_body`, `Http.with_headers`, `Http.add_header`,
`Http.with_timeout_ms`, and the `Http.response_*` accessors.

### Handling responses

`Http.request_task` returns a response for HTTP status codes including 404 and
422. Inspect `Http.response_status(response)` and decode the body according to
your endpoint's contract. A validation response may need field errors; a missing
resource may need a different page.

Transport and boundary failures use `Http.HttpError`: `Network(Str)`, `Timeout`,
`Canceled`, `ResourceLimit(Str)`, `Unsupported(Str)`, or `ResponseMaterialization(Str)`.
`Http.error_text` supplies a display string when you do not need to distinguish
those cases.

The text helper discards response status and headers. It also substitutes
replacement characters for invalid UTF-8. Use the full response API when status
codes matter or when decoding must reject invalid text:

```roc
body = Str.from_utf8(Http.response_body(response))
```

Handle that `Try` before parsing structured data. Avoid lossy conversion on a
path where changing the input text could change its meaning.

Fold decoded responses into a domain type such as
`[Loading, Ready(Articles), Failed(Str)]`. An exhaustive match covers those
variants, but an empty list inside `Ready` still needs an explicit UI decision.

### JSON

Use Roc's builtin `Json` with a declared record type. For an endpoint that
returns an article envelope:

```roc
parse : Str -> Try({ article : Article }, [InvalidJson(Str), MissingRequiredField(Str)])
parse = Json.parser_camel()
```

`Json.parser_camel()` maps `camelCase` JSON fields to `snake_case` Roc fields.
`Json.to_str(value)` encodes. See
[Conduit's `Api.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples-web/conduit/Api.roc)
for endpoint-specific decoding. That example still contains `shield_escapes`
and `restore_text`, a workaround for an upstream JSON escape limitation. It is
not a general JSON decoder: it does not cover all legal escaped input. Before
adapting that code, test representative payloads against your pinned compiler,
including quotes, backslashes, newlines, and Unicode escapes. Keep any necessary
compiler workaround separate from your domain mapping.

### What the browser does

The runtime passes method, headers, body, and an abort signal to `fetch`, and
implements the request timeout around that call. It does **not** set `credentials`, `redirect`, `mode`, `cache`, or
referrer policy — browser defaults apply, meaning same-origin credentials,
followed redirects, and normal CORS. A CORS denial or DNS failure arrives as
`Http.Network(message)`.

Roc request headers use `{ name, value }` records. Browser fetch and Headers
processing still apply, so do not rely on receiving original wire header order
or duplicate header spelling.

You can intercept tasks entirely in JavaScript by passing a `taskHandler` to
`mountSignalsApp`. The site uses handlers for deterministic example data,
including Conduit's in-page backend in `www/static/conduit_backend.mjs`. A handler can leave a
request unhandled to let the runtime use its normal task bridge. This is useful
for demos and browser tests; it does not establish compatibility with a real
server.

## Lifecycle sinks

These are `Elem` nodes that render nothing and register lifecycle behavior:

| Sink | Runs |
| --- | --- |
| `Ui.on_mount(to_cmd)` | once, when the owning scope mounts |
| `Ui.on_change(signal, to_cmd)` | after a changed value settles, excluding the initial value |
| `Ui.on_change_initial(signal, to_cmd)` | on the first mounted value **and** on changes |
| `Ui.on_cleanup(cleanup)` | when the owning scope is disposed |

`on_change` versus `on_change_initial` matters for deep links: use
`on_change_initial` when the very first value must take effect, such as setting
the document title from the URL on a cold load.

Include them as children of the scope that should own the work. This fragment
assumes `remote`, `status_text`, `task`, and `path` are already defined:

```roc
Html.section_c(
    "Feed",
    "grid gap-3",
    [
        Html.paragraph_s(remote.map(status_text)),
        Ui.on_mount(|| Http.start(task, get_request("/api/articles"))),
        Ui.on_change(path, |value| Http.start(task, get_request("/api/articles?path=${value}"))),
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

For data that should follow filters, pagination, or another value, derive a
request description and let changes trigger the fetch:

```roc
request = { page: page, tag: tag, token: token }.Signal
Ui.on_change_initial(request, |value| Http.start(task, feed_request(value)))
```

This also fetches for the first mounted value. Use `on_change` if some other
part of the scope already starts the initial request. Equality pruning means an
unchanged request description does not start another request.

For explicit user actions such as retry, submit, refresh, or favorite, use an
action:

```roc
Html.button(
    "Refresh",
    Ui.action(request, |value| Http.start(task, feed_request(value))),
)
```

Every accepted click runs the command, even with identical reads. A response
that changes one of the reads does not start another request. Conduit's article
favorite button uses this pattern; it needs no serial counter or special equality.

## Timers

```roc
ticks = Signal.interval(5000)
Ui.on_change(ticks, |_| Http.get_text(task, "/api/dashboard"))
```

`Signal.interval(period_ms)` starts at zero and counts ticks while its scope is
mounted. The example fetches on each tick; add a mount hook if it should fetch
immediately too.

To stop polling while a page is hidden or offline, put the interval and its
request-starting hook inside a `Ui.when` branch selected by visibility and online
status. Leaving the branch stops the interval and cancels its requests.
Combining visibility with another signal does not, by itself, stop a timer.

See the [status-page example](@/examples/status-page.md) for polling controlled
by page visibility.

## Browser environment

Environment values are signals seeded before the first render. Route selection
and session rendering can use their initial values during mount.

| Source | Type |
| --- | --- |
| `Browser.entropy_seed()` | `Signal(U32)` — one seed per mount |
| `Browser.location()` | `Signal(Location)` — `{ path, query, hash }` |
| `Browser.visibility()` | `Signal([Visible, Hidden])` |
| `Browser.online()` | `Signal(Bool)` |
| `Browser.local_storage_text(key)` | `Signal(StorageText)` |
| `Browser.session_storage_text(key)` | `Signal(StorageText)` |

`entropy_seed()` is intended for initializing a pure PRNG. The browser samples
it once with `crypto.getRandomValues`, while native specs receive a stable seed
for reproducibility. The returned number is not itself suitable for secrets,
tokens, or other security decisions.

And the matching commands: `Browser.push_state`, `Browser.replace_state`,
`Browser.set_title`, `Browser.set_local_storage_text`,
`Browser.set_session_storage_text`, `Browser.remove_local_storage`,
`Browser.remove_session_storage`.

`Location` is deliberately raw: `path` keeps its leading `/`, while `query` and
`hash` omit `?` and `#`. Parsing is your job.

### Routing

Parse the location signal into an application route type:

```roc
location : Signal.Signal(Browser.Location)
location = Browser.location()

route = location.map(Route.from_location)
title = route.map(Route.title)
```

Render with `Ui.switch` over a route or route kind, or `Ui.when` for a boolean
choice. Intercept in-app link clicks with `event_policy_prevent_default` and
emit history commands. Conduit routes its link messages through a navigation
intent state; its shell includes these hooks:

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

See Conduit's
[`Route.roc`](https://github.com/lukewilliamboswell/roc-signals/blob/main/examples-web/conduit/Route.roc)
and `Nav.roc` for parsing, link construction, and hash-route handling.

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
`StorageUnavailable(message)`. Handle all three: access can fail because of
browser policy or the environment, and a missing value is different from an
unreadable store.

Writes are commands:

```roc
Ui.on_change(draft, |text| Browser.set_local_storage_text("app.draft", text))
```

Namespace keys such as `app.draft` because several apps can share an origin.
Write failures surface as host diagnostics, not command return values. If the
UI needs to observe what was stored, declare the corresponding storage source
and handle its result. Do not treat emitting a write command as proof of a
successful save.

Conduit derives its local session from declared JWT and username storage
signals. The server must still validate the token on authenticated requests.

## Cleanup

Cleanup is mostly automatic. Disposing a scope cancels its timers and requests
and releases its retained closures. `Ui.on_cleanup(Signal.cleanup("name"))`
registers a *named* cleanup that native specs can assert on:

```lisp
(expect-cleanup "live search panel cleanup" 1)
```

Pair this assertion with pending-task and interval assertions when checking
that closing a panel stops its work.

## JavaScript widgets

The implemented integration API uses `Html.behavior(name)` and a `behaviors`
registry supplied at mount. For a chart, mark an element:

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

`attach` receives the element and returns its cleanup function. `update` receives
one changed attribute name, so read the relevant attribute from the element.
The example assumes your JavaScript defines `draw` and `teardown`.

A missing registration or missing `attach` function currently emits
`behavior_missing` telemetry and skips attachment. Check telemetry if the element
appears but its integration does not start. A working example lives in
`www/static/service_ops_charts.mjs`.

`update` fires only for dynamic custom attributes — `Html.attr_s` and
`Html.attr_maybe_s` — not for fixed fields like text, class, value, or checked.

Return cleanup that releases listeners, subscriptions, and resources created
by `attach`. The runtime calls it when the element is removed or the mount is
torn down. Send values back through a declared custom event: dispatch a
`CustomEvent` with text detail and bind it with `Html.on_custom` and
`State.on_detail`.

The typed widget and subscription vocabulary in `design.md` describes the target
architecture. It is not an additional implemented API to import today.

## Next

[Structuring an App](@/docs/app-architecture.md) covers module boundaries,
state lifetimes, and request ownership.
