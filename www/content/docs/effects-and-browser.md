+++
title = "Effects, HTTP, and the Browser"
description = "Start requests, handle results, follow browser state, and give effects the right lifetime."
weight = 7
template = "page.html"
+++

# Effects, HTTP, and the Browser

An action commits state changes and can then run effectful Roc code. The
effect returns another action, whose reducers enter the same propagation engine
as UI events. Timers and browser environment values remain explicit signals.

## Actions and HTTP

Import `pf.Action exposing [Action]` and `pf.Http`. An effectful function
can call HTTP and return the state changes that follow. For example, given a
`Ui.State(Str)` named `status`:

```roc
fetch! : Ui.State(Str) => Action({})
fetch! = |status| {
    text = match Http.get_text!("/api/dashboard") {
        Ok(value) => value
        Err(Timeout) => "Timeout"
        Err(Status(code)) => "HTTP ${code.to_str()}"
        Err(_) => "Request failed"
    }
    Action.update([status.set(text)])
}
```

Bind it to a button:

```roc
Html.button(
    "Refresh",
    Action.run(
        Signal.const({}),
        |_| Action.then([status.set("Loading")], |_| fetch!(status)),
    ),
)
```

The Loading update commits before the effect runs. Every accepted click admits
a distinct occurrence, even when the declared reads are identical. A change in
those reads alone does not fire the handler.

`Action.then(changes, effect!)` supplies a fresh snapshot of the action's
declared reads after committing `changes`. Each effect returns the next action.
Use `State.write` when the result must be reduced against the state that exists
at completion; do not overwrite newer state with a record captured before an
HTTP call.

### Race policy and lifetime

There is no implicit latest-request-wins rule. If a refresh supersedes an older
request, keep a generation or request identity in application state. The result
reducer compares that identity with the current state and ignores an obsolete
result. Independent effects may complete in either order.

Disposing the originating scope does not cancel an admitted effect. The engine
reparents it to a live scope; returned writes apply to surviving destinations
and skip retired ones. External work cannot be undone by removing its UI.
Full application teardown is a separate host lifecycle boundary.

The maintained latest-wins, coordinated-write, and disposal fixtures demonstrate
these policies. Native specs use `(setup (manual-effects))`,
`expect-pending-effects`, service stubs, and `run-effect` to execute whole
closures in a chosen order. They do not simulate suspension inside a closure.
See [Testing](@/docs/testing.md).

## HTTP requests and responses

`Http.get_text!(uri)` performs a GET with a thirty-second timeout and returns
UTF-8 text only for a successful status. It returns `Status(code)` for non-2xx
responses and `InvalidUtf8` for malformed text; it never substitutes replacement
characters.

Use `Http.send!(request)` for methods, headers, binary bodies, custom timeouts,
or response metadata:

```roc
request = Http.request_from_method(Http.method_get)
    |> Http.with_uri("/api/articles")
    |> Http.with_headers([{ name: "accept", value: "application/json" }])
    |> Http.with_timeout_ms(8000)

result = Http.send!(request)
```

This fragment belongs inside an effectful function. Requests and responses use
the pinned `roc-lang/http` package through the platform's thin helpers.
`Http.send!` and `Http.get!` return responses even for HTTP 404 or 422.
Inspect `Http.response_status`, `Http.response_headers`, and
`Http.response_body` according to the endpoint's contract.

`Http.Error` distinguishes `InvalidRequest(Str)`, `Network(Str)`, `Timeout`,
`TooLarge(Str)`, `Status(U16)`, `InvalidUtf8`, and `Unavailable(Str)`.
Map these into an application-specific result type and render loading, empty,
successful, and failed states deliberately.

For structured bodies, first handle `Str.from_utf8(Http.response_body(response))`,
then parse the text with a declared JSON type. Keep transport errors, decoding
errors, and domain validation separate.

### Browser boundary

The runtime supplies method, headers, body, and an abort signal to Fetch and
enforces the request timeout. It does not override credentials, redirects,
mode, cache, or referrer policy. Browser header processing still applies; do not
depend on original wire ordering or duplicate header spelling.

Pass a Fetch-compatible `fetchImpl` to `mountSignalsApp` for a demo backend
or browser test. The site uses ordinary HTTP requests and responses with
`www/static/conduit_backend.mjs`; there is no task handler or string-envelope
router. This tests the application contract, not compatibility with a real server.

The browser executor requires WebAssembly JSPI for suspended hosted effects.
Deploy the Wasm app and JavaScript runtime together; their protocol versions
must match.

## Lifecycle and timers

Actions can also be driven by lifecycle sinks:

| Sink | Runs |
| --- | --- |
| `Action.on_mount(handler)` | once when the owning scope mounts |
| `Action.on_change(signal, handler)` | after changes, excluding the initial value |
| `Action.on_change_initial(signal, handler)` | initially and after changes |
| `Action.every(period_ms, reads, handler)` | on each interval tick with current reads |
| `Ui.on_cleanup(Signal.cleanup(name))` | records named scope cleanup |

Include these elements in the returned tree. For example:

```roc
Action.on_mount(|| Action.then([], |_| fetch!(status)))
Action.every(5000, Signal.const({}), |_| Action.then([], |_| fetch!(status)))
```

These are separate elements: include either or both as children depending on
whether polling should fetch immediately. Changes to `reads` between ticks
do not trigger `Action.every`.

For requests derived from filters or pagination, use
`Action.on_change_initial` over an equality-aware request signal. Equal request
descriptions are pruned. Use an event-bound `Action.run` for explicit refresh,
where identical clicks should remain distinct.

To stop future polling while hidden or offline, own the interval inside the
appropriate `Ui.when` branch. Leaving it stops the timer, not already admitted
effects. The [status-page example](@/examples/status-page.md) demonstrates
visibility-controlled polling.

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

Cleanup is mostly automatic. Disposing a scope cancels its timers and releases
its scoped registrations. Admitted effects retain their own closures until
completion or host teardown. `Ui.on_cleanup(Signal.cleanup("name"))`
registers a *named* cleanup that native specs can assert on:

```lisp
(expect-cleanup "live search panel cleanup" 1)
```

Pair this with interval assertions and a manual-effect disposal test to verify
that closing a panel stops future ticks without recreating retired state.

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
`State.update_detail`.

The typed widget and subscription vocabulary in `design.md` describes the target
architecture. It is not an additional implemented API to import today.

## Next

[Structuring an App](@/docs/app-architecture.md) covers module boundaries,
state lifetimes, and request ownership.
