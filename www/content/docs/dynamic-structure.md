+++
title = "Lists, Conditionals, and Components"
description = "Dynamic structure with Ui.when and Ui.each, keyed rows, row-local state, and where identity comes from."
weight = 6
template = "page.html"
+++

# Lists, Conditionals, and Components

Signals handle values that change. This page is about **structure** that
changes — regions appearing and disappearing, lists growing and reordering,
reusable pieces keeping their own state.

All three mechanisms here create **scopes**. A scope owns the nodes, retained
closures, DOM, timers, and in-flight requests created inside it. When a scope is
disposed, all of that goes with it. That is the whole cleanup story.

## Conditionals

`Ui.when` takes a `Signal(Bool)` and two zero-argument thunks:

```roc
Ui.when(
    is_open,
    || Html.paragraph("Open"),
    || Html.paragraph("Closed"),
)
```

Each arm is its own scope. When the condition flips, the losing arm is disposed
and the winning arm mounted. Only that subtree is patched — nothing above or
beside it is touched.

### Prefer signal-backed attributes over structure

Reach for `Ui.when` only when the *existence* of something changes. If only a
value changes, use a signal-backed sink instead:

```roc
# Wasteful — rebuilds a subtree to change a word and a colour.
Ui.when(
    is_error,
    || Html.paragraph_c("Failed", "text-red-700"),
    || Html.paragraph_c("Ready", "text-zinc-600"),
)

# Better — one text patch and one class patch.
Html.paragraph_s_c(message, "text-sm")
```

Wrap the smallest region whose existence genuinely changes.

### Multi-way branching

There is no `Ui.match`. Multi-way routing is a chain of nested `Ui.when`:

```roc
Ui.when(
    is_kind("home"),
    || home_page,
    || Ui.when(
        is_kind("login"),
        || login_page,
        || not_found_page,
    ),
)
```

Conduit routes nine pages this way. It builds the chain as named bindings from
the innermost outwards, which reads better than deep nesting:

```roc
profile_or_rest = Ui.when(is_kind("profile"), || profile_page, || not_found)
article_or_rest = Ui.when(is_kind("article"), || article_page, || profile_or_rest)
login_or_rest = Ui.when(is_kind("login"), || login_page, || article_or_rest)
```

Being honest: this is the clumsiest part of the API today. It works, it is
efficient — only the matching arm is ever mounted — but it is more ceremony than
a `match` on a route type would be.

## Keyed lists

`Ui.each` renders a keyed `Rows` collection:

```roc
books = Rows.from_list(book_list, |book| book.id)?
Ui.each(Signal.const(books), book_row)
```

`Ui.each` has two arguments:

1. a `Signal(Rows(item))`,
2. `Ui.Row(item) -> Elem`, the row renderer.

The `Rows` value owns the `item -> Str` key projection supplied to
`Rows.from_list` or `Rows.empty`. It evaluates and validates that projection
when a generation is constructed, so rendering does not recompute keys.

The row renderer receives an opaque row. `row.key()` returns its stable key,
`row.signal()` exposes the live item signal, and `row.map(...)` derives directly
from that source. Rows are live: when one item changes, only that row's signals
recompute.

```roc
book_row : Ui.Row(Book) -> Elem
book_row = |row| {
	title = row.map(|value| value.title)
    Html.div_c("flex gap-3", [Html.text_s(title)])
}
```

### Keys

The key is the row's identity. Get it from the data — a database id, slug, or
client-generated id.

**Never key by position.** With index keys, moving an item makes every row after
it appear to have changed, so the host rebuilds them and any row-local state
lands on the wrong row.

Keys must also be unique within one list. Duplicates are a hard error at mount
(`Rows.Error.DuplicateKey("...")`) when constructing or editing `Rows`, rather
than a subtle rendering bug.

### Rows expose identity and a live source

A row renderer receives `Ui.Row(item)`, not an item snapshot. `row.key()` is
the exact stable UTF-8 identity, `row.signal()` is the live item source, and
`row.map(project)` builds an ordinary equality-pruned graph projection. The
row source is generation-checked and remains stable while its keyed scope is
live, including across reorder and replacement collection generations.

Two consequences worth knowing before you hit them:

**Accessible names repeat.** Every row's checkbox labelled `"Read"` means
`label:"Read"` matches many elements and tests fail with *locator matched 2
elements*. Derive a unique test id from the key:

```roc
Html.checkbox_attrs("Read", read, [Html.test_id("book-${id}")], msg)
```

**Do not encode presentation data into identity.** Derive links, labels, and
other changing values from `row.signal()` or `row.map(...)`. The key should
contain only durable identity; changing it retires the old row scope and creates
a new one by design.

## Row-local state

Put `Ui.state` **inside** the row renderer and it belongs to that row, keyed by
the row key:

```roc
line_row : Str, Signal.Signal(Line) -> Elem
line_row = |sku, line|
    Ui.state(
        1.U64,
        |qty| {
            quantity : Signal.Signal(U64)
            quantity = qty.signal()

            label = { line: line, qty: quantity }.Signal.map(
                |v| "${v.line.name} x${v.qty.to_str()}",
            )

            Html.div_c(
                "flex gap-2",
                [
                    Html.text_s(label),
                    Html.button_attrs("Add one", [Html.test_id("add-${sku}")], qty.on_unit(|n| n + 1)),
                ],
            )
        },
    )
```

Because identity is the key, this state **follows the row** through reordering
and filtering. That is testable, not just claimed:

```lisp
(click (test-id "add-a1"))
(click (test-id "add-a1"))
(expect-text (text "Keyboard x3") "Keyboard x3")

(mark-metrics)
(click (role button :name "Reverse"))
(expect-text (text "Keyboard x3") "Keyboard x3")
(expect-metric-delta rows_created 0)
(expect-metric-delta rows_removed 0)
```

After reversing the list the quantity is still 3, and the host created and
destroyed zero rows — it moved the existing DOM nodes.

State declared **outside** `Ui.each` belongs to the surrounding scope and is
shared by every row. Both are useful; choose deliberately. When a row needs to
change the *list's* state — deleting an item, toggling a field on the shared
model — define the row renderer inside the outer `Ui.state` body so it closes
over the outer handle, as the [tutorial](@/docs/tutorial.md#step-5-per-row-events)
does.

## Components

A component is just a function returning an `Elem`. If it needs its own state,
wrap it in `Ui.component` to give it a private identity scope:

```roc
counter : Str -> Elem
counter = |label|
    Ui.component(
        || Ui.state(
            0.U64,
            |count| {
                text = count.signal().map(|n| "${label}: ${n.to_str()}")

                Html.div_c(
                    "flex gap-2",
                    [
                        Html.button("Increment ${label}", count.on_unit(|n| n + 1)),
                        Html.text_s(text),
                    ],
                )
            },
        ),
    )
```

Now `counter("Left")` and `counter("Right")` are independent. Without
`Ui.component`, both would consume ordinals from the *caller's* scope, so
inserting one ahead of the other would shift identities underneath them.

**Rule of thumb:** any reusable helper that declares `Ui.state`, `Ui.when`, or
`Ui.each` internally should be wrapped in `Ui.component`. Purely
presentational helpers do not need it.

Conduit wraps every page module this way, so navigating between routes gives
each page a clean scope.

### Passing data across a component boundary

Prefer **one signal of one props record** over many separate signal parameters:

```roc
# Good — one edge across the boundary, fields derived at the leaves.
article_card : Signal.Signal(CardProps) -> Elem

# Noisy — the caller pre-explodes everything.
article_card : Signal.Signal(Str), Signal.Signal(Str), Signal.Signal(Bool) -> Elem
```

Derive the leaves inside the component with `.map`. Signal parameters are
already concrete types, so they never need the
[receiver annotation](@/docs/state-and-events.md#annotate-the-signal-you-map-from).

## Where identity comes from

Roc is pure. There is no `this`, no object identity, no allocation address to
key on. So how does the host know that the `Ui.state` it is looking at is the
same one as last time?

**Construction-order position within the enclosing scope.** When the host walks
your descriptor tree it numbers each identity-bearing node — `Ui.state`,
`Ui.when`, `Ui.each`, `Ui.component` — in the order it encounters them.
Scopes are created by the root, each `when` arm, each keyed row, and each
component.

This is why the ordering rule matters:

> **Do not vary how many identity-bearing nodes you construct based on a runtime
> value.** Doing so shifts the ordinals of everything after it.

In practice you rarely trip on this, because varying structure is exactly what
`Ui.when` and `Ui.each` are for — and both give the varying part its own
scope. The risk shows up when refactoring: moving a `Ui.state` across a scope
boundary changes its identity, and it will silently reset. In a large app,
consistent page-module conventions are the mitigation.

## Performance notes

Most good performance falls out of picking the right primitive:

- **Value changed, structure did not?** Use a signal-backed sink: `text_s`,
  `class_attr_s`, `attr_s`, `bool_attr_s`, a bound input value.
- **Existence changed?** Use `Ui.when` around the smallest possible region.
- **Collection changed?** Use `Ui.each` with keys from item identity.
- **State belongs to a row?** Declare it inside the row renderer.
- **Value can be computed?** Derive it; do not store it.
- **Custom type used as a signal value?** Give it a meaningful `is_eq`; that is
  the cutoff that keeps unrelated work from waking.

Avoid funnelling everything through one giant state record feeding one giant
view-model. Independent panels deriving from independent sources stay quiet when
unrelated things change.

And you can assert all of this: `(expect-metric-delta rows_created 0)` and
friends turn a performance intention into a test. See
[Testing](@/docs/testing.md#work-budgets).

## Next

[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) — talking to
servers, timers, history, and storage.
