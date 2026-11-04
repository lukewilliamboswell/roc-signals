+++
title = "Lists, Conditionals, and Components"
description = "Dynamic structure with Ui.when and Ui.each, keyed rows, row-local state, and where identity comes from."
weight = 6
template = "page.html"
+++

# Lists, Conditionals, and Components

Use dynamic structure when elements need to appear, disappear, or move. This
page covers conditional regions, keyed lists, and reusable components with local
state. The snippets assume the usual `Ui`, `Html`, `Signal`, and `Elem` imports;
list examples also use `import pf.Rows`.

Each mechanism establishes a scope that owns its mounted state, signals, DOM,
and active effects. Removing the scope releases those resources and cancels its
active work. State owned by an ancestor can outlive the removed region.

## Conditionals

`Ui.when` takes a `Signal(Bool)` and two functions that take no arguments:

```roc
Ui.when(
    is_open,
    || Html.paragraph("Open"),
    || Html.paragraph("Closed"),
)
```

Each arm is its own scope. When the condition flips, the losing arm is disposed
and the winning arm mounted. The structural replacement is limited to that
branch; other bindings can still update if they also depend on the changed state.

### Prefer signal-backed attributes over structure

If the same elements should remain mounted, bind their changing values directly:

```roc
message = is_error.map(|failed| if failed { "Failed" } else { "Ready" })
classes = is_error.map(|failed| if failed { "text-red-700" } else { "text-zinc-600" })
Html.div([Html.class_attr_s(classes)], [Html.text_s(message)])
```

This changes the text and class without replacing the element. Use `Ui.when`
when the contents need a different lifetime, such as a form that should reset
when closed. Hiding an element with a class or `hidden` attribute keeps its
state and effects active.

### Multi-way branching

Use `Ui.switch` to select structure by a typed case:

```roc
Ui.switch(
    page_kind,
    |kind| match kind {
        Home => home_page()
        Login => login_page()
        NotFound => not_found_page()
    },
)
```

Only the live case's builder runs. An unequal case disposes the previous branch
and mounts a new one. Select a page kind when changing route parameters should
preserve the page's local state, and pass the parameters as signals to that page.
Selecting the entire route instead resets the branch whenever any route field
changes according to its equality comparison.

## Keyed lists

`Ui.each` renders a keyed `Rows` collection:

```roc
book_list_view : List(Book) -> Try(Elem, Rows.Error)
book_list_view = |book_list| {
    books = Rows.from_list(book_list, |book| book.id)?
    Ok(Ui.each(Signal.const(books), book_row))
}
```

`Ui.each` has two arguments:

1. a `Signal(Rows(item))`,
2. `Ui.Row(item) -> Elem`, the row renderer.

The `Rows` value owns the `item -> Str` key projection supplied to
`Rows.from_list` or `Rows.empty`. It evaluates and validates that projection
when a generation is constructed, so rendering does not recompute keys.

Handle the `Try` where the collection enters your UI. The example above assumes
a `Book` record with `id : Str` and `title : Str`. A changing list uses a
`Signal.Signal(Rows.Rows(Book))` in place of `Signal.const(books)`.

The row renderer receives a live row rather than an item snapshot. When an
item changes without changing its key, its row signal updates and the existing
row scope remains mounted.

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

Choose keys that stay with the item when its position changes. If you derive
keys from list positions, state stays attached to those positions and can appear
on a different item after insertion or sorting.

Keys must be unique within one collection. Constructing or editing `Rows` with
duplicate keys returns `Rows.Error.DuplicateKey(key)`. Handle that error where
you build the collection; rendering does not merge the duplicate rows.

### Rows expose identity and a live source

A row renderer receives `Ui.Row(item)`, not an item snapshot. `row.key()` is
the exact stable UTF-8 identity, `row.signal()` is the live item source, and
`row.map(project)` builds an ordinary equality-pruned graph projection. The
row source is generation-checked and remains stable while its keyed scope is
live, including across reorder and replacement collection generations.

Repeated controls also need a way to be distinguished. If every row has a
checkbox named `"Read"`, a label locator matches several controls. Give the
control a meaningful accessible name and use a stable key for a test id:

```roc
Html.checkbox_attrs("Read", read, [Html.test_id("book-${row.key()}")], msg)
```

Derive links, labels, and other changing values from `row.signal()` or `row.map(...)`. The key should
contain only durable identity; changing it retires the old row scope and creates
a new one by design.

## Row-local state

Declare `Ui.state` inside the row renderer when each row needs its own value.
Here `Line` is a record with a `name : Str` field; each row starts with quantity 1:

```roc
line_row : Ui.Row(Line) -> Elem
line_row = |row| {
    sku = row.key()
    line = row.signal()
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
                    Html.paragraph_s_attrs(label, [Html.test_id("quantity-${sku}")]),
                    Html.button_attrs("Add one", [Html.test_id("add-${sku}")], qty.update(|n| n + 1)),
                ],
            )
        },
    )
}
```

This state follows a surviving key through reordering and removal of other rows.
Filtering this row out disposes its state and effects; inserting its key again
creates a new lifetime. State that must survive filtering belongs in an owner
outside the rendered rows. Reordering preserves state, which a spec can assert:

```lisp
(click (test-id "add-a1"))
(click (test-id "add-a1"))
(expect-text (test-id "quantity-a1") "Keyboard x3")

(mark-metrics)
(click (role button :name "Reverse"))
(expect-text (test-id "quantity-a1") "Keyboard x3")
(expect-metric-delta rows_created 0)
(expect-metric-delta rows_removed 0)
```

After reversing the list the quantity is still 3, and the host created and
destroyed zero rows — it moved the existing DOM nodes.

State declared outside `Ui.each` belongs to the surrounding scope and can be
shared by rows that reference it. When a row needs to change the list's state — deleting an item, toggling a field on the shared
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
                        Html.button("Increment ${label}", count.update(|n| n + 1)),
                        Html.text_s(text),
                    ],
                )
            },
        ),
    )
```

`counter("Left")` and `counter("Right")` have separate scopes. Construction
order inside either component is local to it, so adding internal state does not
shift the caller's other state declarations. The component itself still has a
construction site in its caller; the wrapper does not give it a stable list key.

Wrap reusable helpers that declare `Ui.state`, `Ui.when`, `Ui.switch`, or
`Ui.each` in `Ui.component` to keep their internal sites in a local scope.
Purely presentational helpers do not need the wrapper.

A component wrapper establishes ownership. It does not, by itself, rebuild the
component when an input changes. Use `Ui.when` or `Ui.switch` around a component
when a change should end its lifetime and mount a fresh instance.

### Passing data across a component boundary

Choose inputs according to what changes together. For independent values, a
named record of signals preserves separate dependencies:

```roc
article_card : { title : Signal.Signal(Str), author : Signal.Signal(Str), saved : Signal.Signal(Bool) } -> Elem
```

Use `Signal.Signal(CardProps)` when the props form one coherent value. Mapping
its fields inside the component still subscribes each projection to the whole
record; moving the projections does not make the inputs independent.

Components can also take static values, event handlers, and `List(Elem)`
children. State declared inside a child description belongs to the scope where
that child is mounted. References to a caller-owned signal keep the caller's
ownership; passing a signal does not move its state into the component.

## Where identity comes from

The runtime assigns structural identities by deterministic traversal of the
returned description within each scope. A construction site is a declaration
in that description, not a source line, DOM position, or component name.
Conditional branches, switch cases, keyed rows, and components separate their
internal declaration order from their siblings.

Use `Ui.when`, `Ui.switch`, or `Ui.each` for changing structure. Varying the
number of state declarations in an ordinary constructed child list can shift
later sites. Moving state across a scope boundary also changes who owns it.

A key preserves identity only while it survives at the same list site. Removing
and later reinserting it starts a new lifetime. Moving it between two different
`Ui.each` sites also creates a new lifetime at the destination. Keep state in an
ancestor, indexed by the domain key, if it must survive filtering, pagination,
or movement between lists.

## Performance notes

Choose the primitive that describes the intended change:

- Bind changing text and attributes with `text_s`, `class_attr_s`, `attr_s`,
  or `bool_attr_s` when the elements should remain mounted.
- Use `Ui.when` or `Ui.switch` around the region whose lifetime should change.
- Use `Ui.each` with stable item keys for a changing collection.
- Declare row-local state inside the row renderer, and persistent state outside it.
- Derive computed values and use equality that preserves every observable change.

Keep independently changing panels on separate sources so unrelated updates
do not recalculate their projections.

`Rows.apply` can carry a small edit set to `Ui.each`. The engine uses that delta
when the edit starts from the generation currently rendered at the site. A
replacement snapshot, or an edit from a different generation, requires comparing
the collection. Surviving keys still preserve their row scopes in either case.
The cost of constructing, filtering, or sorting your collection also counts;
preserving rows does not make those application calculations constant-time.

Measure the behavior your application depends on with native specs. For example,
`(expect-metric-delta rows_created 0)` checks that an interaction creates no rows. See
[Testing](@/docs/testing.md#work-budgets).

## Next

[Effects, HTTP, and the Browser](@/docs/effects-and-browser.md) — talking to
servers, timers, history, and storage.
