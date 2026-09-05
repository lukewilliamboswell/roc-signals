+++
title = "Structuring a Real App"
description = "How Conduit, a 3,900-line RealWorld implementation, is organized — modules, layering, routing, sessions, and mutations."
weight = 8
template = "page.html"
+++

# Structuring a Real App

Small examples do not tell you how the model holds up at scale. This page walks
through [Conduit](@/examples/conduit.md), a complete
[RealWorld](https://docs.realworld.show/) implementation — the "Medium clone"
spec that dozens of frameworks implement so they can be compared on equal terms.

It has feeds with pagination and tag filtering, JWT auth persisted across
reloads, profiles with follow/unfollow, markdown article bodies, comments,
favorites, a settings page, and nine routes with deep links and guards. It is
**3,864 lines of Roc** plus a 363-line test spec, and it is built out of exactly
the primitives in the preceding pages — no framework escape hatches.

## Module layout

```text
examples/conduit/
  main.roc          265   shell, route switch, session and history wiring
  Route.roc        272   Location <-> Route, titles, link targets
  Api.roc          399   DTOs, JSON codecs, URIs, request builders
  Session.roc       74   auth state over namespaced localStorage
  Nav.roc           66   in-app links and navigation intent
  Markdown.roc     358   markdown -> Elem, with a link-scheme allowlist
  Feed.roc         355   shared article-list rendering and pagination
  Home.roc         175   page modules
  Article.roc      619
  Editor.roc       410
  Profile.roc      315
  Settings.roc     188
  Auth.roc         268
  Format.roc        45   date display
  Styles.roc        55   shared class-name constants
  specs/           16 cases   native behaviour suite
```

The shape that emerged, which generalizes:

- **One module per page.** Each owns its state, its requests, and its rendering.
- **One module per cross-cutting concern.** Routing, API, session, navigation —
  each is the single place that concern is expressed.
- **Shared rendering that is genuinely shared.** `Feed.roc` exists because the
  home feeds and both profile tabs render the same article list. It was
  extracted when the third caller appeared, not before.
- **A `Styles` module of plain string constants.** No CSS-in-Roc, no theme
  engine — just named class strings so the same tree renders under the browser
  host and the native spec runner.

## The shell

`main.roc` does five things and then delegates:

```roc
main : () -> Elem
main = ||
    Ui.state(
        Nav.initial,
        |route_intent| {
            location = Browser.location()
            route = location.map(Route.from_location)
            session = Session.current()
            document_title = route.map(Route.title)
            guard_inputs = { route: route, session: session }.Signal
            guard = guard_inputs.map(|value| guard_target(value.route, value.session))

            Html.div_c(
                Styles.shell,
                [
                    Ui.on_change(route_intent.signal(), |intent| Browser.push_state(Nav.location(intent))),
                    Ui.on_change_initial(
                        guard,
                        |target|
                            match target {
                                Redirect(redirect_location) => Browser.replace_state(redirect_location)
                                Stay => Signal.noop
                            },
                    ),
                    Ui.on_change_initial(document_title, Browser.set_title),
                    header_view(session, route_intent),
                    Elem.Element({
                        tag: "main",
                        attrs: [Html.class_attr(Styles.main)],
                        children: [page_view(route, session, route_intent)],
                    }),
                    footer_view,
                ],
            )
        },
    )
```

Read that as five declarations rather than five actions:

1. `route` is derived from the URL.
2. `session` is derived from localStorage.
3. Navigation intent becomes `push_state`.
4. The auth guard becomes `replace_state`.
5. The document title follows the route.

Nothing is imperative. The header, the page, and the title cannot drift out of
sync with the URL, because they are all functions of the same signal.

## Layering

Conduit follows a simple layering rule:

> Domain types know nothing about presentation. Presentation types know nothing
> about CSS. CSS lives in one place.

`Api.roc` owns transport types, JSON codecs, and request construction without
knowing how anything is rendered. Page modules own state transitions and turn
domain values into elements. `Styles.roc` owns shared class names without
knowing which state selected them. The payoff is that changing an endpoint does
not require editing presentation code, while changing a shared visual treatment
does not disturb request or state logic.

### Container and presentational

Split by **who owns the signals**:

- **Container functions** own sources and effects: they create tasks, declare
  storage keys, derive the section signals a page needs.
- **Presentational functions** take a `Signal(Props)` and return an `Elem`.
  They derive leaf values with `.map` and own nothing.

Pass **one signal of one props record** across the boundary rather than a long
parameter list of field signals. Derive fields at the leaves, where they are
used.

## Remote data

Conduit's most-copied idea is a single `Remote` type:

```roc
Remote(a) : [Loading, Ready(a), Failed(Str)]
```

Every fetch surface renders from it, so loading, error, and empty states are
impossible to forget — the `match` is exhaustive and the compiler enforces it.
`Feed.roc` renders the four cases once, and every list in the app inherits them:

```roc
Ui.when(
    is_loading,
    || Html.paragraph_c("Loading articles...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
    || Ui.when(
        is_failed,
        || Html.paragraph_s_c(message, Styles.status_error),
        || Ui.when(
            is_empty,
            || Html.paragraph_c("No articles are here... yet.", "rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"),
            || Ui.each(articles, |row| article_row(row.key(), row.signal())),
        ),
    ),
)
```

(Note that only the error arm uses a `Styles` constant — the other two carry
inline classes. Conduit is not perfectly consistent about this, which is itself
worth knowing before you take its layering as gospel.)

Compare that with how many production React apps quietly render nothing on
error. Making the states a type rather than a convention is most of the value.

## Server-confirmed mutations

Conduit deliberately avoids optimistic updates in its first pass. Favoriting an
article disables the control, sends the request, and applies the server's
returned counts:

```roc
request_inputs = { model: model_signal, row: row, token: token }.Signal
request = request_inputs.map(
    |value| {
        serial: value.model.favorite_serial,
        slug: value.row.slug,
        favorited: value.row.favorited,
        token: value.token,
    },
)

Ui.on_change(
    request,
    |value|
        if value.serial == 0 or value.slug.is_empty() {
            Signal.noop
        } else if value.favorited {
            Http.start(favorite_task, Api.delete_request(Api.favorite_uri(value.slug), value.token))
        } else {
            Http.start(favorite_task, Api.post_request(Api.favorite_uri(value.slug), "", value.token))
        },
)
```

Three things to take from this:

- **The serial number.** Clicking favorite twice must fire twice, but the derived
  request would otherwise be equal both times and `is_eq` would suppress it. A
  counter in the state makes each intent distinct. This comes up for every retry
  and resubmit.
- **The guard against serial 0.** The request signal exists from mount, so the
  initial value must not fire a request.
- **The task lives in the row.** Each row owns its own `Http.request_task`, so
  favoriting one article cannot cancel another's request — task identity is
  scope plus source.

## Sessions

`Session.roc` is 74 lines and shows how much a declared source buys you:

```roc
current : () -> Signal.Signal(Session)
current = || {
    stored = {
        jwt: Browser.local_storage_text(jwt_key),
        username: Browser.local_storage_text(username_key),
    }.Signal

    stored.map(
        |value|
            match value.jwt {
                StorageValue(token) =>
                    match value.username {
                        StorageValue(name) => SignedIn({ token: token, username: name })
                        _ => Anonymous
                    }
                _ => Anonymous
            },
    )
}
```

Storage signals resolve **before the first render**, so a returning user is
signed in on the very first frame — no flash of a logged-out header, no
post-mount correction. Login and logout are storage commands; the session signal
updates and the whole app follows.

Keys are namespaced (`conduit.jwt`) because examples share an origin.

## Rich text without raw HTML

There is no `dangerouslySetInnerHTML`, on purpose. `Markdown.roc` parses
markdown into `Elem` nodes, placing all user-controlled text in `Html.text` /
`Html.text_s` leaves. Links go through a scheme allowlist (`https://`,
`http://`, `/`, `#`, `mailto:`); anything else renders as plain text.

Injection is not a class of bug this platform has, because there is no path from
a string to markup.

## Testing at this scale

Conduit's `specs/` directory contains focused cases covering feeds, pagination, auth, guards,
validation envelopes, network failures, stale-response suppression, navigation,
and every mutation. It runs in milliseconds with no browser and no server.

The discipline that makes this work is that **the spec is the specification**.
Each RealWorld feature maps to at least one assertion, and error paths get the
same treatment as happy paths.

## What Conduit revealed

The app was built as an evidence instrument, so its friction is recorded rather
than hidden:

- **Keyed rows only receive their key.** Pagination encodes page and tag into the
  key string (`"2|rust"`) and parses it back. Works, but it is a wart.
- **Multi-way routing is a `Ui.when` chain.** Nine routes means nine nested
  conditionals. Correct and efficient, more ceremony than a `match` would be.
- **Construction-order identity needs discipline.** At 3,900 lines, moving a
  `Ui.state` binder across a scope boundary is a real hazard. Consistent page
  module conventions are the mitigation.
- **Opaque HTTP responses need flattening.** Folding the response type directly
  into a large domain union could overflow the compiler; a small plain
  `ResponseState` record in between fixed it and reads better.
- **Scroll restoration is missing.** There is no scroll command, and a
  feed → article transition wants one.

That list is the honest version of "how did it go". Everything else — auth,
pagination, markdown, optimistic-free mutations, deep links, error matrices —
worked with the primitives as they are.

## Next

[Testing](@/docs/testing.md) — the spec language in full.
