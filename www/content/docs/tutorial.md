+++
title = "Tutorial"
description = "Build a reading list app one concept at a time — state, derived values, forms, keyed lists, and a passing test suite."
weight = 4
template = "page.html"
+++

# Tutorial: A Reading List

We are going to build a small app that adds books to a list, marks them as read,
filters to unread, and keeps a live count. It is about 120 lines, it touches
every concept you need for real work, and it finishes with an automated test
suite that runs in milliseconds.

You should have finished [Getting Started](@/docs/getting-started.md) so that
`zig build build-test-hosts` has been run and `roc check` works. Reading
[Thinking in Signals](@/docs/thinking-in-signals.md) first will make the *why*
of each step obvious.

Create `examples/reading-list/main.roc` and follow along. After each step, run:

```sh
roc check examples/reading-list/main.roc
```

## Step 1 — Static structure

Start with no reactivity at all.

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html

main : () -> Elem
main = ||
    Html.section_c(
        "Reading List",
        "grid gap-4",
        [
            Html.heading_c("Reading List", "text-2xl font-semibold"),
            Html.paragraph("Nothing here yet."),
        ],
    )
```

`Html.section_c` is a labelled region — `"Reading List"` is its accessible name,
`"grid gap-4"` its CSS classes. Element helpers ending in `_c` take a static
class string; you will meet `_s` (signal-backed) and `_attrs` (extra attributes)
shortly.

The accessible names matter. They are how tests and screen readers find things,
and getting them right now costs nothing.

## Step 2 — Your first signal

Add a text input whose value echoes back as you type.

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = ||
    Ui.state(
        "",
        |draft| {
            title = draft.signal()

            echo = title.map(
                |value|
                    if value.is_empty() {
                        "Type a title"
                    } else {
                        "Adding: ${value}"
                    },
            )

            Html.section_c(
                "Reading List",
                "grid gap-4",
                [
                    Html.heading_c("Reading List", "text-2xl font-semibold"),
                    Html.text_input("Title", title, draft.on_str(|_current, value| value)),
                    Html.paragraph_s(echo),
                ],
            )
        },
    )
```

Four new things:

- **`Ui.state("", |draft| ...)`** introduces a source holding a `Str`, starting
  empty. The lambda receives a *handle* and returns the subtree that can use it.
- **`draft.signal()`** reads the state as a signal you can derive from.
- **`title.map(...)`** creates a derived node. The lambda runs whenever `title`
  changes — never at startup-only.
- **`draft.on_str(|_current, value| value)`** builds a reducer. On each `input`
  event the host calls it with the current state and the field's text; whatever
  it returns becomes the new state. Here we discard the old value and keep the
  typed text.

Note `Html.paragraph_s(echo)` — the `_s` suffix. `Html.paragraph` takes a fixed
`Str`; `paragraph_s` takes a `Signal(Str)` and tracks it. Mixing these up is the
single most common beginner mistake, and it fails loudly at the type level.

## Step 3 — Model the data

Real state is more than a string. Define the domain types and render a list.

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Book : { id : Str, title : Str, read : Bool }

Model : { books : List(Book), draft : Str, next_id : U64 }

initial : Model
initial = {
    books: [
        { id: "b1", title: "Structure and Interpretation", read: True },
        { id: "b2", title: "Thinking in Systems", read: False },
    ],
    draft: "",
    next_id: 3,
}

book_row : Str, Signal.Signal(Book) -> Elem
book_row = |_id, book| {
    title = book.map(|value| value.title)
    Html.div_c("flex gap-3", [Html.text_s(title)])
}

main : () -> Elem
main = ||
    Ui.state(
        initial,
        |model| {
            state : Signal.Signal(Model)
            state = model.signal()

            books = state.map(|value| value.books)

            Html.section_c(
                "Reading List",
                "grid gap-4",
                [
                    Html.heading_c("Reading List", "text-2xl font-semibold"),
                    Ui.each_str(books, |book| book.id, book_row),
                ],
            )
        },
    )
```

**`Ui.each_str(books, key_of, row)`** renders a keyed list. It takes a
`Signal(List(item))`, a function producing a stable string key, and a row
renderer receiving `(key, Signal(item))`.

The key must come from the item's identity — a database id, slug, or generated
id — **never the list index**. Rows are matched across updates by key, so a
correct key means reordering, inserting, and filtering reuse existing DOM nodes
and preserve any state a row owns. An index key throws that away.

Notice `book_row` receives a `Signal(Book)`, not a `Book`. Rows are live: when
one book changes, that row's own signals update and nothing else in the list is
touched.

### The annotation that saves you an hour

```roc
state : Signal.Signal(Model)
state = model.signal()
```

That annotation is not decoration. Without it, calling `.map` twice on `state`
with *different* result types fails to compile with a confusing message about
`map` having an incompatible type. Annotating the signal you map from fixes it.
Full explanation in
[State, Events, and Forms](@/docs/state-and-events.md#annotate-the-signal-you-map-from).

## Step 4 — Adding books

Reducers are pure `Model -> Model` functions. Write them as ordinary top-level
functions and they become trivially testable.

```roc
add_book : Model -> Model
add_book = |model|
    if model.draft.is_empty() {
        model
    } else {
        {
            ..model,
            books: model.books.append({ id: "b${model.next_id.to_str()}", title: model.draft, read: False }),
            draft: "",
            next_id: model.next_id + 1,
        }
    }
```

Wire it to a form. Add the `draft` binding next to `books` inside the `Ui.state`
body, and put the `Html.form_label(...)` into `section_c`'s children list, above
the `Ui.each_str`:

```roc
# inside the Ui.state body, with the other derived bindings
draft = state.map(|value| value.draft)

# in the section_c children list
Html.form_label(
    "Add book",
    [Html.on_submit_prevent_default(model.on_unit(add_book))],
    [
        Html.text_input("Title", draft, model.on_str(|value, text| { ..value, draft: text })),
        Html.button("Add book", model.on_unit(add_book)),
    ],
)
```

`on_submit_prevent_default` handles Enter-in-the-field without navigating away;
the button handles clicks. Both run the same reducer, so there is one code path
for "add a book".

`model.on_unit` builds a reducer that ignores the event payload —
`Model -> Model`. `model.on_str` receives the field's text as a second argument.

The input is **controlled**: its displayed value comes from the `draft` signal,
and typing dispatches a reducer that updates the state the signal reads from.
Same contract as React's controlled inputs, without the re-render.

## Step 5 — Per-row events

Each row gets a checkbox that toggles that book. The reducer needs the row's id:

```roc
toggle_read : Model, Str -> Model
toggle_read = |model, id| {
    ..model,
    books: model.books.map(
        |book|
            if book.id == id {
                { ..book, read: !book.read }
            } else {
                book
            },
    ),
}
```

Because the row needs to update the *list's* state, **move** `book_row` from the
top level (where Step 3 put it) into the `Ui.state` body, so it closes over the
`model` handle. Delete the top-level copy — leaving both is a duplicate
definition:

```roc
book_row : Str, Signal.Signal(Book) -> Elem
book_row = |id, book| {
    title = book.map(|value| value.title)
    read = book.map(|value| value.read)

    Html.div_c(
        "flex items-center gap-3",
        [
            Html.checkbox_attrs(
                "Read",
                read,
                [Html.test_id("book-${id}")],
                model.on_bool(|value, _checked| toggle_read(value, id)),
            ),
            Html.text_s(title),
        ],
    )
}
```

`model.on_bool` receives the checkbox's new checked state. We ignore it and
toggle from the model instead, so the model stays the single source of truth.

**Why `Html.test_id("book-${id}")`?** Every row's checkbox has the same
accessible name, `"Read"`, so `label:"Read"` would match several elements and a
test would fail with *locator matched 2 elements*. A row renderer only receives
the static key, so give each row a unique test id derived from it. If your rows
can carry genuinely distinct labels, prefer that — it helps real users too.

## Step 6 — Filtering and empty states

First the model needs somewhere to keep the filter. Add `unread_only` to `Model`
and to `initial`:

```roc
Model : {
    books : List(Book),
    draft : Str,
    unread_only : Bool,
    next_id : U64,
}

initial : Model
initial = {
    books: [
        { id: "b1", title: "Structure and Interpretation", read: True },
        { id: "b2", title: "Thinking in Systems", read: False },
    ],
    draft: "",
    unread_only: False,
    next_id: 3,
}
```

Then two more top-level helpers:

```roc
visible_books : Model -> List(Book)
visible_books = |model|
    if model.unread_only {
        model.books.keep_if(|book| !book.read)
    } else {
        model.books
    }

unread_count : List(Book) -> U64
unread_count = |books| books.keep_if(|book| !book.read).len()
```

These are annotated top-level helpers on purpose. You *could* inline
`items.keep_if(...).len()` inside the `.map` lambda and it would compile — but
pulling it out keeps the reactive wiring readable, and makes `unread_count`
directly unit-testable. It also avoids a class of confusing inference error if
you ever forget the receiver annotation.

In the `Ui.state` body, `books` now derives through the filter, and three new
signals join it:

```roc
books = state.map(visible_books)
unread_only = state.map(|value| value.unread_only)
summary = state.map(|value| "${unread_count(value.books).to_str()} unread")
empty = books.map(|list| list.is_empty())
```

Then in `section_c`'s children, add the checkbox and summary, and replace the
bare `Ui.each_str(...)` with a conditional:

```roc
Html.checkbox(
    "Unread only",
    unread_only,
    model.on_bool(|value, checked| { ..value, unread_only: checked }),
),
Html.text_s(summary),
Ui.when(
    empty,
    || Html.paragraph("Nothing to show."),
    || Ui.each_str(books, |book| book.id, book_row),
),
```

`Ui.when` takes a `Signal(Bool)` and two zero-argument thunks. Each arm is its
own scope: when the condition flips, the losing arm is disposed — its DOM
removed, its state dropped, its timers and requests cancelled — and the winning
arm is mounted. Only the selected thunk runs.

For more than two shapes, use `Ui.switch(signal, |case| ...)`. The builder
receives the selected typed value and runs only when that value changes, so it
can express recursive structure without constructing unselected branches.

Note that `summary` counts `value.books` (all books) while the list renders
`visible_books`. Deriving both from one source keeps them consistent for free.

## The finished app

```roc
app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Book : { id : Str, title : Str, read : Bool }

Model : {
    books : List(Book),
    draft : Str,
    unread_only : Bool,
    next_id : U64,
}

initial : Model
initial = {
    books: [
        { id: "b1", title: "Structure and Interpretation", read: True },
        { id: "b2", title: "Thinking in Systems", read: False },
    ],
    draft: "",
    unread_only: False,
    next_id: 3,
}

add_book : Model -> Model
add_book = |model|
    if model.draft.is_empty() {
        model
    } else {
        {
            ..model,
            books: model.books.append({ id: "b${model.next_id.to_str()}", title: model.draft, read: False }),
            draft: "",
            next_id: model.next_id + 1,
        }
    }

toggle_read : Model, Str -> Model
toggle_read = |model, id| {
    ..model,
    books: model.books.map(
        |book|
            if book.id == id {
                { ..book, read: !book.read }
            } else {
                book
            },
    ),
}

visible_books : Model -> List(Book)
visible_books = |model|
    if model.unread_only {
        model.books.keep_if(|book| !book.read)
    } else {
        model.books
    }

unread_count : List(Book) -> U64
unread_count = |books| books.keep_if(|book| !book.read).len()

main : () -> Elem
main = ||
    Ui.state(
        initial,
        |model| {
            state : Signal.Signal(Model)
            state = model.signal()

            draft = state.map(|value| value.draft)
            books = state.map(visible_books)
            unread_only = state.map(|value| value.unread_only)
            summary = state.map(|value| "${unread_count(value.books).to_str()} unread")
            empty = books.map(|list| list.is_empty())

            book_row : Str, Signal.Signal(Book) -> Elem
            book_row = |id, book| {
                title = book.map(|value| value.title)
                read = book.map(|value| value.read)

                Html.div_c(
                    "flex items-center gap-3",
                    [
                        Html.checkbox_attrs(
                            "Read",
                            read,
                            [Html.test_id("book-${id}")],
                            model.on_bool(|value, _checked| toggle_read(value, id)),
                        ),
                        Html.text_s(title),
                    ],
                )
            }

            Html.section_c(
                "Reading List",
                "grid gap-4",
                [
                    Html.heading_c("Reading List", "text-2xl font-semibold"),
                    Html.form_label(
                        "Add book",
                        [Html.on_submit_prevent_default(model.on_unit(add_book))],
                        [
                            Html.text_input("Title", draft, model.on_str(|value, text| { ..value, draft: text })),
                            Html.button("Add book", model.on_unit(add_book)),
                        ],
                    ),
                    Html.checkbox(
                        "Unread only",
                        unread_only,
                        model.on_bool(|value, checked| { ..value, unread_only: checked }),
                    ),
                    Html.text_s(summary),
                    Ui.when(
                        empty,
                        || Html.paragraph("Nothing to show."),
                        || Ui.each_str(books, |book| book.id, book_row),
                    ),
                ],
            )
        },
    )
```

## Step 7 — Test it

Write `examples/reading-list/specs/reading-list.scm`:

```lisp
(test "reading list workflow"
  (steps
    (expect-visible (role heading :name "Reading List"))
    (expect-text (text "1 unread") "1 unread")
    (fill (label "Title") "Thinking in Bets")
    (click (role button :name "Add book"))
    (expect-text (text "2 unread") "2 unread")
    (expect-value (label "Title") "")
    (check (label "Unread only"))
    (expect-absent (text "Structure and Interpretation"))
    (expect-visible (text "Thinking in Systems"))
    (uncheck (label "Unread only"))
    (expect-visible (text "Structure and Interpretation"))))
```

Build and run:

```sh
roc build --target=arm64mac --output=/tmp/reading-list examples/reading-list/main.roc
python3 scripts/spec_driver.py /tmp/reading-list examples/reading-list/specs
```

Exit code `0`, no output — everything passed. The whole run takes milliseconds
and there is no browser involved.

Now assert something stronger. Add `examples/reading-list/specs/toggle.scm`:

```lisp
(test "toggle reuses its row"
  (steps
    (expect-checked (test-id "book-b2") false)
    (expect-text (text "1 unread") "1 unread")
    (mark-metrics)
    (check (test-id "book-b2"))
    (expect-checked (test-id "book-b2") true)
    (expect-text (text "0 unread") "0 unread")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)))
```

The last two lines assert that toggling a checkbox created and destroyed **zero
rows** — the host patched the existing row in place rather than rebuilding the
list. That is the promise of the signals model, and here it is enforced by the
test suite rather than assumed. If a future refactor accidentally makes the list
rebuild, this fails.

```sh
python3 scripts/spec_driver.py /tmp/reading-list examples/reading-list/specs
```

## See it in a browser

```sh
roc build --target=wasm32 --opt=size --output=/tmp/reading-list.wasm examples/reading-list/main.roc
```

Drop `/tmp/reading-list.wasm` on the [home page](@/_index.md), or register the
app in `www/data/examples.toml` and run
`python3 scripts/serve.py --example reading-list`.

## What to read next

You have used sources, derived signals, reducers, controlled inputs, keyed
lists, conditionals, and specs. The remaining pieces:

- [State, Events, and Forms](@/docs/state-and-events.md) — every input control,
  keyboard and custom events, validation patterns.
- [Lists, Conditionals, and Components](@/docs/dynamic-structure.md) —
  row-local state, `Ui.component`, and how identity really works.
- [Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) — the piece
  this tutorial skipped entirely: talking to a server.
- [Testing](@/docs/testing.md) — the full spec language, including async.
