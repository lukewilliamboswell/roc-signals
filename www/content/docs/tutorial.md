+++
title = "Tutorial"
description = "Build a reading list app one concept at a time — state, derived values, forms, keyed lists, and a passing test suite."
weight = 4
template = "page.html"
+++

# Tutorial: A Reading List

We are going to build a small app that adds books to a list, marks them as read,
filters to unread, and keeps a live count. You will work with state, derived
values, form events, and keyed rows, then write native specs for the completed
app. Data stays in memory and resets when the app remounts.

You should have finished [Getting Started](@/docs/getting-started.md) so that
`zig build build-test-hosts` has been run and `roc check` works. [Thinking in
Signals](@/docs/thinking-in-signals.md) explains the reactive model if you want
more background.

Create a directory for the app and its specs:

```sh
mkdir -p examples-web/reading-list/specs
```

Save each complete example in `examples-web/reading-list/main.roc`. Later steps show
additions to that file; the finished app below includes them all. After each
step, run:

```sh
roc check examples-web/reading-list/main.roc
```

## Step 1 — Static structure

Start with no reactivity at all.

```roc
app [main] { pf: platform "../../platform-web/main.roc" }

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
so use names that explain each control's purpose. The CSS classes here are
Tailwind utilities used by the example site; on your own page, load a matching
stylesheet or replace them with your own classes.

## Step 2 — Your first signal

Add a text input whose value echoes back as you type.

```roc
app [main] { pf: platform "../../platform-web/main.roc" }

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
- **`title.map(...)`** creates a derived node. The lambda runs at mount
  and again when `title` changes.
- **`draft.on_str(|_current, value| value)`** builds a reducer. On each `input`
  event the host calls it with the current state and the field's text; whatever
  it returns becomes the new state. Here we discard the old value and keep the
  typed text.

Note `Html.paragraph_s(echo)` — the `_s` suffix. `Html.paragraph` takes a fixed
`Str`; `paragraph_s` takes a `Signal(Str)` and tracks it. Use the signal-backed
helper when the displayed text should change.

## Step 3 — Model the data

Real state is more than a string. Define the domain types and render a list.

```roc
app [main] { pf: platform "../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui

Book : { id : Str, title : Str, read : Bool }

Model : { books : Rows(Book), draft : Str, next_id : U64 }

initial_books : Rows(Book)
initial_books =
    Rows.from_list(
        [
            { id: "b1", title: "Structure and Interpretation", read: True },
            { id: "b2", title: "Thinking in Systems", read: False },
        ],
        |book| book.id,
    ) ?? crash "initial book keys must be unique"

initial : Model
initial = {
    books: initial_books,
    draft: "",
    next_id: 3,
}

book_row : Ui.Row(Book) -> Elem
book_row = |row| {
    title = row.map(|value| value.title)
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
                    Ui.each(books, book_row),
                ],
            )
        },
    )
```

**`Ui.each(books, row)`** renders keyed rows. It takes a
`Signal(Rows(item))` and a row renderer receiving an opaque `Ui.Row(item)`.
`Rows.from_list(items, key_of)` owns the stable key projection and rejects
duplicates before the collection can reach the renderer.

The key must come from the item's identity — a database id, slug, or generated
id — **never the list index**. Rows are matched across updates by key, so a
stable key lets surviving rows reuse their DOM nodes and local state during
reordering or changes to other rows. Filtering a row out disposes its scope;
showing that key again creates a new row. Keep data that must survive filtering
in the parent model, as this app does with each book's `read` field.

Notice `book_row` derives through `row.map(...)`, not a snapshot `Book`. Rows are
live: when one book changes, only that row source dirties and its dependent
signals update. Use `row.key()` for the stable key or `row.signal()` when a
combinator requires the complete item signal.

### Annotate a signal used for different projections

```roc
state : Signal.Signal(Model)
state = model.signal()
```

With the current compiler, calling `.map` twice on an unannotated `state`
with different result types can fail with a message about `map` having an
incompatible type. Annotating the source signal resolves that inference issue.
Full explanation in
[State, Events, and Forms](@/docs/state-and-events.md#annotate-the-signal-you-map-from).

## Step 4 — Adding books

Reducers are pure `Model -> Model` functions. Write them as ordinary top-level
functions so you can test them independently of the UI.

```roc
add_book : Model -> Model
add_book = |model|
    if model.draft.is_empty() {
        model
    } else {
        {
            ..model,
            books: Rows.apply(
                model.books,
                [Rows.Edit.Append([{ id: "b${model.next_id.to_str()}", title: model.draft, read: False }])],
            ) ?? crash "the generated book id must be unique",
            draft: "",
            next_id: model.next_id + 1,
        }
    }
```

Wire it to a form. Add the `draft` binding next to `books` inside the `Ui.state`
body, and put the `Html.form_label(...)` into `section_c`'s children list, above
the `Ui.each`:

```roc
# inside the Ui.state body, with the other derived bindings
draft = state.map(|value| value.draft)

# in the section_c children list
Html.form_label(
    "Add book",
    [Html.on_submit_prevent_default(model.on_unit(add_book))],
    [
        Html.text_input("Title", draft, model.on_str(|value, text| { ..value, draft: text })),
        Html.button_attrs("Add book", [Html.attr("type", "button")], model.on_unit(add_book)),
    ],
)
```

`on_submit_prevent_default` handles Enter-in-the-field without navigating away;
the button handles clicks. Both run the same reducer, so there is one code path
for "add a book". The explicit `type="button"` prevents the click from also
performing the button's default form submission.

`model.on_unit` builds a reducer that ignores the event payload —
`Model -> Model`. `model.on_str` receives the field's text as a second argument.

The input is **controlled**: its displayed value comes from the `draft` signal,
and typing dispatches a reducer that updates the state the signal reads from.
When `add_book` clears `draft`, the input receives the new value. In the
browser, a differing value is deferred while a text input is focused or
composing and applied after blur; see [State, Events, and
Forms](@/docs/state-and-events.md).

## Step 5 — Per-row events

Each row gets a checkbox that sets whether that book has been read. The reducer
needs the row's id:

```roc
set_read : Model, Str, Bool -> Model
set_read = |model, id, checked| {
    book = Rows.get_key(model.books, id) ?? crash "the row key must still exist"
    updated = { ..book, read: checked }
    { ..model, books: Rows.apply(model.books, [Rows.Edit.SetKey({ key: id, item: updated })]) ?? crash "the row key must still exist" }
}
```

Because the row needs to update the *list's* state, **move** `book_row` from the
top level (where Step 3 put it) into the `Ui.state` body, so it closes over the
`model` handle. Delete the top-level copy — leaving both is a duplicate
definition:

```roc
book_row : Ui.Row(Book) -> Elem
book_row = |row| {
    id = row.key()
    title = row.map(|value| value.title)
    read = row.map(|value| value.read)

    Html.div_c(
        "flex items-center gap-3",
        [
            Html.checkbox_attrs(
                "Read",
                read,
                [Html.test_id("book-${id}"), Html.aria_describedby("title-${id}")],
                model.on_bool(|value, checked| set_read(value, id, checked)),
            ),
            Html.paragraph_s_attrs(title, [Html.attr("id", "title-${id}")]),
        ],
    )
}
```

`model.on_bool` receives the checkbox's new checked state. Store that value in
the model so the reducer describes the requested state directly.

**Why `Html.test_id("book-${id}")`?** Every row's checkbox has the same
accessible name, `"Read"`, so `label:"Read"` would match several elements and a
test would fail with *locator matched 2 elements*. Give each row a unique test
id derived from its key. `aria_describedby` links the checkbox to its book
title so assistive technology can distinguish the repeated controls. The test id serves only the test runner.

## Step 6 — Filtering and empty states

First the model needs somewhere to keep the filter. Add `unread_only` to `Model`
and to `initial`:

```roc
Model : {
    books : Rows(Book),
    draft : Str,
    unread_only : Bool,
    next_id : U64,
}

initial : Model
initial = {
    books: initial_books,
    draft: "",
    unread_only: False,
    next_id: 3,
}
```

Then two more top-level helpers:

```roc
visible_books : Model -> Rows(Book)
visible_books = |model|
    if model.unread_only {
        visible = Rows.to_list(model.books).keep_if(|book| !book.read)
        Rows.replace_all(model.books, visible) ?? crash "filtered books retain unique keys"
    } else {
        model.books
    }

unread_count : Rows(Book) -> U64
unread_count = |books| Rows.to_list(books).keep_if(|book| !book.read).len()
```

The filter and count scan the collection. This is a simple implementation for a
small reading list, not a constant-time update strategy. Because they derive
from the whole model, they also run when the draft text changes. For larger
collections, separate independently changing state and measure the work; see
[Lists, Conditionals, and Components](@/docs/dynamic-structure.md).

In the `Ui.state` body, `books` now derives through the filter, and three new
signals join it:

```roc
books = state.map(visible_books)
unread_only = state.map(|value| value.unread_only)
summary = state.map(|value| "${unread_count(value.books).to_str()} unread")
empty = books.map(|rows| rows.len() == 0)
```

Then in `section_c`'s children, add the checkbox and summary, and replace the
bare `Ui.each(...)` with a conditional:

```roc
Html.checkbox(
    "Unread only",
    unread_only,
    model.on_bool(|value, checked| { ..value, unread_only: checked }),
),
Html.paragraph_s_attrs(summary, [Html.test_id("summary")]),
Ui.when(
    empty,
    || Html.paragraph("Nothing to show."),
    || Ui.each(books, book_row),
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
`visible_books`. Deriving both from one source lets the engine compute both from
the same updated model.

## The finished app

```roc
app [main] { pf: platform "../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui

Book : { id : Str, title : Str, read : Bool }

Model : {
    books : Rows(Book),
    draft : Str,
    unread_only : Bool,
    next_id : U64,
}

initial_books : Rows(Book)
initial_books =
    Rows.from_list(
        [
            { id: "b1", title: "Structure and Interpretation", read: True },
            { id: "b2", title: "Thinking in Systems", read: False },
        ],
        |book| book.id,
    ) ?? crash "initial book keys must be unique"

initial : Model
initial = {
    books: initial_books,
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
            books: Rows.apply(
                model.books,
                [Rows.Edit.Append([{ id: "b${model.next_id.to_str()}", title: model.draft, read: False }])],
            ) ?? crash "the generated book id must be unique",
            draft: "",
            next_id: model.next_id + 1,
        }
    }

set_read : Model, Str, Bool -> Model
set_read = |model, id, checked| {
    book = Rows.get_key(model.books, id) ?? crash "the row key must still exist"
    updated = { ..book, read: checked }
    { ..model, books: Rows.apply(model.books, [Rows.Edit.SetKey({ key: id, item: updated })]) ?? crash "the row key must still exist" }
}

visible_books : Model -> Rows(Book)
visible_books = |model|
    if model.unread_only {
        visible = Rows.to_list(model.books).keep_if(|book| !book.read)
        Rows.replace_all(model.books, visible) ?? crash "filtered books retain unique keys"
    } else {
        model.books
    }

unread_count : Rows(Book) -> U64
unread_count = |books| Rows.to_list(books).keep_if(|book| !book.read).len()

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
            empty = books.map(|rows| rows.len() == 0)

            book_row : Ui.Row(Book) -> Elem
            book_row = |row| {
                id = row.key()
                title = row.map(|value| value.title)
                read = row.map(|value| value.read)

                Html.div_c(
                    "flex items-center gap-3",
                    [
                        Html.checkbox_attrs(
                            "Read",
                            read,
                            [Html.test_id("book-${id}"), Html.aria_describedby("title-${id}")],
                            model.on_bool(|value, checked| set_read(value, id, checked)),
                        ),
                        Html.paragraph_s_attrs(title, [Html.attr("id", "title-${id}")]),
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
                            Html.button_attrs("Add book", [Html.attr("type", "button")], model.on_unit(add_book)),
                        ],
                    ),
                    Html.checkbox(
                        "Unread only",
                        unread_only,
                        model.on_bool(|value, checked| { ..value, unread_only: checked }),
                    ),
                    Html.paragraph_s_attrs(summary, [Html.test_id("summary")]),
                    Ui.when(
                        empty,
                        || Html.paragraph("Nothing to show."),
                        || Ui.each(books, book_row),
                    ),
                ],
            )
        },
    )
```

## Step 7 — Test it

Write `examples-web/reading-list/specs/reading-list.scm`:

```lisp
(test "reading list workflow"
  (steps
    (expect-visible (role heading :name "Reading List"))
    (expect-text (test-id "summary") "1 unread")
    (fill (label "Title") "Thinking in Bets")
    (click (role button :name "Add book"))
    (expect-text (test-id "summary") "2 unread")
    (expect-value (label "Title") "")
    (check (label "Unread only"))
    (expect-absent (text "Structure and Interpretation"))
    (expect-visible (text "Thinking in Systems"))
    (uncheck (label "Unread only"))
    (expect-visible (text "Structure and Interpretation"))))
```

Build and run using your machine's target (`x64musl` below is Linux x64;
use `arm64musl`, `arm64mac`, or `x64mac` as appropriate):

```sh
roc build --target=x64musl --output=/tmp/reading-list examples-web/reading-list/main.roc
python3 scripts/spec_driver.py /tmp/reading-list examples-web/reading-list/specs
```

The driver prints per-spec results and a summary; exit code `0` means the
assertions passed. Each spec file runs in a fresh app process.

Now assert something stronger. Add `examples-web/reading-list/specs/toggle.scm`:

```lisp
(test "toggle reuses its row"
  (steps
    (expect-checked (test-id "book-b2") false)
    (expect-text (test-id "summary") "1 unread")
    (mark-metrics)
    (check (test-id "book-b2"))
    (expect-checked (test-id "book-b2") true)
    (expect-text (test-id "summary") "0 unread")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)))
```

The last two lines assert that toggling a checkbox created and destroyed **zero
rows** — the host patched the existing row in place rather than rebuilding the
list. This checks row lifetime for this interaction. It does not establish that
filtering or counting is constant-time, or that browser focus is preserved. If
a refactor recreates rows on this path, the test fails.

```sh
python3 scripts/spec_driver.py /tmp/reading-list examples-web/reading-list/specs
```

## See it in a browser

```sh
roc build --target=wasm32 --opt=size --output=/tmp/reading-list.wasm examples-web/reading-list/main.roc
```

Use the matching browser runtime as described in
[Getting Started](@/docs/getting-started.md#mount-it-in-your-own-page), or register the
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
