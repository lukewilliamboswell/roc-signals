+++
title = "Shared State"
description = "The store and its cells: state the whole app shares, read at any depth and written by decisions you test as functions."
weight = 6
template = "page.html"
+++

# Shared State

Some state belongs to more than one part of an app: who is signed in, where
the reader is, what a page has loaded, what is in a cart. In a large app the
code that writes such state and the code that reads it are often far apart.
If the state belonged to one piece of the view, every level between the two
would have to carry it. So shared state lives in one place, the *store*,
which every part of the view reaches directly.

The snippets on this page come from one small shop, `www/samples/shop/`:
products to add to a cart, and an order sent to a server.

## Describe the store

A store is a set of *cells*. A cell is one piece of state, read and
written through a `Cell` value. An app describes its store once:

{{ sample(file="shop/Shop.roc", region="store") }}

- Each field of the record is `Engine.cell(init)`, a cell with its starting
  value, or another description. The `.Engine.Cells` after the record is
  Roc's record builder: it combines the fields into one description.
- A field can be a group of cells that another module describes.
  `Cart.cells({})` is the cart's own description, nested as it is
  ([Starting again](#starting-again) shows it).
- `Engine.store(tag, cells)` builds the store. The tag is a value of a type
  declared for this store, usually the one tag of the module that builds it:
  here `Shop.CornerShop`. It is part of the type of every cell, so a cell
  of another store is a compile error wherever this one is used.
- `store.cells()` is the record of cells, in the shape of the
  description. The rest of the app reads and writes through `Shop.cells`.
- `Engine.program_store(config, start, view)` is the program of an app with
  a store: `start` gives the store and `view` the page, each from the boot
  data.
- The record builder combines two fields or more. A store with one cell
  describes it as the cell itself, named in a record by `map`:
  `Engine.cell("").map(|draft| { draft: draft })`.

You never write the code that finds a cell inside the store. Each cell's getter
and modifier are generated from its place in the description, so two cells
cannot overlap, and a write through one can never leave a reader of another
showing an old value.

## Read a cell anywhere

`cell.signal()` is the cell's value, a `Signal` to `map` and show like any other.
It works in any context, at any depth, with nothing passed down and no `lift`.
Here a row of the product list reads the cart:

{{ sample(file="shop/Shop.roc", region="depth") }}

The `where` clause is the one thing a function that uses the store asks of
its context: that the context reaches a store. Every context of an app
started with `program_store` does. The store's own type is generated and
long, so annotations write `_` for it, here and in `Engine.Write(_)` and
`Engine.StoreRoot(_)`. A type alias cannot contain `_`, so an alias that
mentions a store takes the store's type as a parameter, as `Props(st)` does in
[Components](@/docs/components.md).

The app's `main.roc` also names the concrete storage type as `Store`, using
public types such as `Engine.Stored` and `Engine.Table`. The compiler prints
that type when the declaration is missing or out of date. The instance holds
this storage beside its sites and moves it through each turn; it is not
captured by the root site's closure.

A write to a cell wakes the readers of that cell and no one else's. Adding
tea re-evaluates what reads the cart and the notice. The line that counts
orders reads neither, so it is not looked at.

## Writes are values

Nothing in a view changes a cell directly. A write is a value that says
which cell, and how:

| Write | Meaning | Use it when |
|---|---|---|
| `cell.set(value)` | Replace what the cell holds with `value` | The new value does not depend on the old one |
| `cell.update(f)` | Replace what the cell holds with `f` of it | It does. `f` is given the value uniquely owned, so a list or a table is updated in place |

A `set` of a value built from a reading of the same cell is allowed, but for
a large value it copies: the reading is still held while the new value is
built. Use `update` for anything large.

`state.update(f)` is a handler, while `cell.update(f)` is a write. A decision
or `Engine.does([..])` turns a list of cell writes into a handler. Both apply
a function to the current state; their return types say who applies it.

## Decisions

A *decision* is one pure function from what it is given to a list of writes.
The list is the whole transition:

{{ sample(file="shop/Shop.roc", region="decisions") }}

`Engine.handle` and `Engine.handle_by` make a handler of a decision:

| Handler | The decision receives |
|---|---|
| `Engine.handle(decide)` | the event's payload |
| `Engine.handle_by(v, decide)` | the value `v` holds when the event fires, and the payload |
| `Engine.does(writes)` | nothing: the handler is the list of writes itself, for a transition that needs neither the payload nor a reading |

These handlers are generic over the event's payload. The same `handle`
and `handle_by` receive a `Received` for a file choice, drop or paste when
attached as a files handler ([Files](@/docs/files.md)); a handler of one
payload cannot attach to an event kind of another.

In the product row above, the "Add" button reads the row's product when it
is pressed. The page's "Check out" button reads the cart:

{{ sample(file="shop/Shop.roc", region="check-out") }}

The reading comes from one signal. To read several things, combine their
signals first: `map2` for two, and for more a record of signals with Roc's
record builder,
`{ cart: cells.cart.signal(), note: cells.note.signal() }.Engine.Signal`, as the
[Tutorial](@/docs/tutorial.md#adding-a-to-do-one-decision) does. `Signal.map2`
has the shape the builder calls, so the result is one signal of the record,
which reads what all of its fields read. Read what the decision needs and
no more: a count or a flag worked out from a table, not the table.

Why one function for the whole transition? A transition usually touches
several cells that must agree: the cart and the notice about it, the count of
orders and an empty basket. One function sees one reading and returns every
write, so there is no order between them to get wrong, and no moment at which
one cell has changed and another has not.

What the engine does with the list:

- It applies every write before anything on the page is refreshed.
- It wakes the readers of exactly the cells the list names. A decision that
  returns `[]`, as `checked_out` does for an empty cart, writes nothing and
  costs nothing.
- `handle_by` takes its reading once, when the event fires and before any
  of the decision's own writes is applied. Every write is computed from
  that one reading, so the order of writes to different cells cannot
  matter. Composed after another handler with `also`, it reads what that
  handler left ([Local and shared in one event](#local-and-shared-in-one-event)).
- Two writes to one cell are applied in order: an `update` after another
  write of its cell sees that write's result. A `set` over a cell the same
  list already wrote is a contract error, because it could only throw the
  earlier write away.

A decision does nothing but return its writes. A request to the outside
world is asked for by state that an effect site watches: `checked_out` posts
the order to an outbox cell, and [an effect site](#results-decide-too) sends
it.

## Test a decision as a function

A decision is an ordinary function, so a top-level `expect` tests it with no
engine and no browser. `store.after(writes)` applies a list to the store as a
turn applies it, the same-cell rule included, and `read(cell)` reads a cell
of the result:

{{ sample(file="shop/Shop.roc", region="expects") }}

`roc test` in the app's directory runs them. These are the tests that see a
transition that wrote the wrong cell or left one out. The type checker
cannot: two cells of one type are the same to it.

Each `after` is one turn. Before a table's first write in that list, its
preceding writing turn's changes are cleared. Further updates keep the first
earlier row per key. A table the list does not write retains its last writing
turn's changes through unrelated turns. Read
`store.after(writes).read(table).inverse()` to see which rows that transition
wrote; the next `after` writing that table starts its next recording turn.

A decision may read the preceding inverse before returning writes. Inside its
first table modifier the inverse already describes the new turn. Keep an
inverse in its own cell if history must survive the next table write. A reset
followed by refinements is one list and one turn; `with_initial` remains a
start, with empty changes.

### State a rule over a store

State the rule as a pure function of a plain reading. Project only the cells
the rule needs. A table has no order of its own: sort its rows by an explicit
order before comparing readings. Read an outbox through `last()`, which names
what was posted, rather than its internal serial.

Compare readings with `==`. `Str.inspect` is for debugging, never equality or
identity: opaque values can print alike while holding different data.

Check the rule in a top-level `expect` on the path that matters: one transition
or a few chained `after`s, checking after each relevant turn. To bound what a
transition wrote, read its table's inverse after that `after`. Conduit's typed
sign-in test checks which page's form changed; Kanban's tests check a move and
a completed drop through their keyed inverse counts.

An answer is a decision too. Supply the typed result its ask delivers, and
state which request it answers and when it arrives. A keeping site can have
several requests in flight; each result carries its own issued-for value even
after newer posts. A test that keeps only the latest post omits those paths.

An example's roc-fuzz target tests its platform-free domain rules. It imports
nothing of the platform or another package of this repository. Decisions that
return `Engine.Write` are checked by these pure `expect`s and the app's paired
specs; they do not require the engine package in an example target.

## Results decide too

A result from outside (an HTTP response, a timer firing, a job's answer) is
decided the same way. `Engine.react(decide)` is an effect site's reaction
that writes cells: the decision receives the value the request was issued
for and the result. `Engine.react_by(v, decide)` also gives it the value `v`
holds when the result arrives.

{{ sample(file="shop/Shop.roc", region="answer") }}

`Shop.cells.basket.reset` is one write that starts the cart's cells again;
[Starting again](#starting-again) explains it.
[Effects and the Browser](@/docs/effects-and-browser.md) covers the sites
that issue requests, and outboxes.

## Local and shared in one event

When one click must write local state and also run a decision,
`first.also(second)` makes one handler of the two. Both run for the same
event, in order, and the page is refreshed once, after both:

{{ sample(file="shop/Cart.roc", region="also") }}

`second` sees what `first` wrote, and that includes a reading:
`draft.update(|_| "").also(Engine.handle_by(draft.signal(), ...))` hands the
decision the emptied draft, with no error. When a decision reads local state
that the same click clears, put the decision first. `Reaction.also` does the
same for one result. Handler composition also works for the files of one
event; both handlers must take the same payload type.

`also` runs two handlers one after the other; it does not give them one
reading. If one transition must decide a piece of local state and a cell
from the same reading, that state is not local: make it a cell, and write it
in the decision.

## Starting again

A cell lives as long as the app. Nothing disposes it, so state that should
start fresh (a basket once its order is placed, a page's form once the reader
leaves the page) is started again on purpose, by a write. A description of
cells can hand out that write with its cells:

{{ sample(file="shop/Cart.roc", region="cells") }}

`with_reset` gives its function the cells and one `Engine.Write` that puts
every cell of the description back to the value it was described with. In
`ordered` above, `Shop.cells.basket.reset` empties the cart and clears the note
in one write.

- The reset is generated with the cells, so a cell added to the group
  later is covered with no other change.
- It restores the value the cell was described with, not one that
  `with_initial` started the store with.
- A write of one of the group's cells after the reset, in the same list,
  refines it: "start again, but with this".
- The engine never applies it for you. The transition that should start the
  group again includes it, and an `expect` on that transition is what notices
  when it was left out:

{{ sample(file="shop/Shop.roc", region="reset-expect") }}

## Starting values from the boot data

`store.with_initial(cell, value)` is the store with one cell started at
another value, for a start that depends on what the browser knows before the
first render: the URL, or a value saved in local storage. The
[Tutorial](@/docs/tutorial.md#saving-to-local-storage) restores its list this
way.

## A cell where a `State` is expected

`cell.state()` is the cell as a `State` of the context it is called in. A
function written over a `State` then draws a cell without knowing it is one:

{{ sample(file="shop/Cart.roc", region="note-box") }}

A reducer through that `State` is a write of the cell, and wakes the cell's
readers. [Components](@/docs/components.md) builds on this.

## What to keep in mind

- **One cell per concern.** A write wakes the readers of the cell written, so
  two things that change independently are two cells. One cell holding a
  large record wakes every reader of the record for every field.
- **Rows the user edits are a table.** A cell holding a plain list wakes
  every reader of the list when one item changes.
  [Tables and Table Views](@/docs/tables-and-views.md) is the next page.
- **Private state stays out of the store.** Whether a menu is open is no
  one else's business, and in the store it would need a reset of its own.
- **The types do not tell two cells of one type apart.** A function handed
  the wrong one compiles. A pure test of the transition, or a spec, tells
  them apart.
