+++
title = "Structuring an App"
description = "Organize modules, choose state lifetimes, and separate user actions from derived values."
weight = 8
template = "page.html"
+++

# Structuring an App

As an app grows, decide where each piece of state belongs and how long it needs
to live. Module boundaries help you find the code; scope boundaries determine
when the runtime releases its state and effects. They serve different purposes.

[Conduit](@/examples/conduit.md) is a useful example to read alongside this
page. It has routed pages, feeds, authentication, article editing, and comments.
Its source includes older patterns as well as newer APIs; the guidance below
explains which patterns to use in new code.

## Module layout

Conduit separates its application code into these groups:

| Modules | Responsibility |
| --- | --- |
| `main.roc` | Page selection, header, navigation, guards, document title |
| `Route.roc`, `Nav.roc` | Parse locations, construct links, request navigation |
| `Api.roc` | Request construction, response decoding, API data types |
| `Session.roc` | Read and update the stored session |
| `Home.roc`, `Article.roc`, `Editor.roc`, `Profile.roc`, `Settings.roc`, `Auth.roc` | Page state, requests, and rendering |
| `Feed.roc`, `Markdown.roc`, `Format.roc` | Shared list rendering, rich text, and display formatting |
| `Styles.roc` | Shared CSS class strings |
| `specs/` | Native tests of application behavior |

Start with a module per feature or page. Extract shared code when callers need
the same behavior. A request helper belongs with API code; a repeated article
card belongs with UI code. You do not need a separate module for every function
or element.

## The shell

The shell owns values that several pages need, such as the current route and
session. Conduit derives both from browser sources:

```roc
location : Signal.Signal(Browser.Location)
location = Browser.location()

route : Signal.Signal(Route)
route = location.map(Route.from_location)

session : Signal.Signal(Session)
session = Session.current()

Ui.on_change_initial(route.map(Route.title), Browser.set_title)
```

These are fragments from the shell's setup: the lifecycle sink must be included
in the returned element tree. `on_change_initial` sets the title for the initial
URL as well as later navigation.

Keep URL parsing in ordinary Roc functions. The UI can then derive navigation
links, selected tabs, and page content from the parsed route. Authentication
guards can derive a redirect and issue `Browser.replace_state`; use
`Browser.push_state` for navigation that should create a Back-button entry.
See [routing](@/docs/effects-and-browser.md#routing) for the browser boundary.

## Layering

Decode external data before rendering it. For example, `Api.roc` can turn an
HTTP response into article data or a domain error, while a page decides how to
show that error and whether to offer a retry. This keeps status-code and JSON
handling out of individual text and button helpers.

CSS classes may be local to a component or shared through a module. Share a
class constant when several views should change together; keeping all CSS
strings in one file is not required by Signals.

### Container and presentational

A rendering helper can accept signals and event messages without owning state.
A component that needs its own lifetime wraps its body in `Ui.component`.
Functions and modules alone do not establish a runtime scope.

Prefer a named record of signals when inputs change independently. A header's
unread count and display name need not become one shared dependency. Use a
single `Signal(Props)` when consumers need a coherent record that changes as a
unit. Combine inputs with `{ first: first, second: second }.Signal` at the place
that actually needs both.

This choice affects recomputation: a transform depending on a combined record
runs when any field changes, even if it reads only one field. Its output may
then compare equal and stop further propagation.

### Choose state lifetimes

Place state in the smallest scope that covers everyone who needs it, for as
long as they need it:

- A disclosure's open flag can belong to its component.
- An article draft that must survive switching pages belongs above the route
  switch, or in explicit persistent storage.
- A row's temporary editing flag can belong inside `Ui.each` if removing the
  row should discard it.
- Edits that must survive filtering or pagination need an owner outside the
  rendered row scopes, indexed by the domain key.

A surviving key preserves row-local state during reorder and same-key item
updates. Removing that key disposes the row. Reintroducing it later creates a
new lifetime; reusing the key does not restore its old state.

Use `Ui.switch` to select a page from a route value or route kind. Switching on
the whole route rebuilds the page scope when any unequal route value arrives.
Switching on the route kind keeps that scope alive for parameter changes within
the same kind; pass the route signal into the page so its requests and content
can follow those parameters. Choose based on whether local page state should
survive that navigation. Conduit's existing shell uses `Ui.when` branches;
new code can express the same choice with `Ui.switch`.

## Remote data

A remote-data type makes request states explicit:

```roc
Remote(a) : [Loading, Ready(a), Failed(Str)]
```

Fold task results into this type near the request code, then render loading,
success, and failure states. An exhaustive `match` checks those three cases.
An empty list is still `Ready([])`, so decide separately how an empty result
should appear. The type does not automatically supply an empty-state view.

Put retry controls where the request-starting scope will survive the transition
to Loading. Removing that scope cancels its request, even if the task-result
signal remains available elsewhere.

## Server-confirmed mutations

Separate a value that should stay synchronized from an action a user requests.
Filters can drive a fetch through `Ui.on_change_initial`. A Favorite or Submit
button should use `Ui.action`, which runs once per accepted event even when its
input values equal those from the previous event.

Conduit's article page uses this form for favorites:

```roc
favorite_action = Ui.action(
    { article: article_state, slug: slug, token: token }.Signal,
    |request|
        if request.slug.is_empty() {
            Signal.noop
        } else if article_favorited(request.article) {
            Http.start(favorite_task, Api.delete_request(Api.favorite_uri(request.slug), request.token))
        } else {
            Http.start(favorite_task, Api.post_request(Api.favorite_uri(request.slug), "", request.token))
        },
)
```

The page binds this message to its favorite control and derives the displayed
state from the response. Changing the article signal alone does not run the
action. You do not need to increment a serial counter to make repeated clicks
distinct. Some Conduit mutations still use that older pattern; it is not needed
for new actions.

Give independently active operations separate task sources. Starting a new
request for the same task in the same owning scope replaces its pending request.
Cancellation prevents a late response from updating that task, but it cannot
undo a write the server has already performed.

When one action needs to replace several state sources together, return
`Ui.update_states` with each state's `write` proposal. Derived values and
observers then see the complete replacement. Do not use a chain of change
observers to repair intermediate combinations of state.

## Sessions

`Session.roc` combines declared storage sources for the JWT and username into a
session signal. Storage is read before the first render, so the shell can render
from the saved session immediately. A missing or unavailable value becomes an
anonymous session in this example.

That is local UI state, not server-side verification of the saved token. Handle
an expired or rejected token in response handling. Keep storage decoding and
session policy in one module so pages use the same rules.

Namespace keys such as `conduit.jwt` because applications on the same origin
share local storage. See [storage](@/docs/effects-and-browser.md#storage) for
unavailable stores and write failures.

## Rich text without raw HTML

`Markdown.roc` renders parsed text as `Elem` structure, using `Html.text` leaves
for user-controlled strings. This avoids interpreting those strings as HTML.
It also checks link schemes before constructing links.

Keep those checks when adapting the renderer. Text nodes do not make arbitrary
URLs, attributes, or JavaScript integrations safe; each external-data boundary
still needs an appropriate policy.

## Testing at this scale

Conduit's native specs cover feeds, navigation, session restoration, errors,
stale responses, and mutations without starting a server. Use that layer for
request sequencing and state lifetimes: retry the same input, navigate while a
request is pending, and remove and restore a keyed row.

Use browser tests for browser behavior, including actual link navigation,
keyboard interaction, focus, storage access, and integrations. The native host
shares the reactive engine, but its simulated DOM does not establish those
browser properties.

## Next

[Testing](@/docs/testing.md) explains how to write native semantic specs and
assert the work an interaction performs.
