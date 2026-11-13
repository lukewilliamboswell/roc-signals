import Core
import Table

## The authoring API of the roc-signals web platform: the reactive engine as an
## app sees it.
##
## An app describes its UI as an [Elem] tree over typed signals ([Signal])
## and its state; `program` turns that description into the [Program] the
## host drives. The engine mounts the tree once, then runs one turn
## per DOM event or effect result: handlers write state, and only the text,
## attributes, rows and sites that read what changed are re-evaluated,
## emitting DOM commands for values that actually changed.
##
## A helper ending `_s` takes a signal where its unsuffixed form takes a
## constant, for example `text_s` beside `text`.
##
## State lives in one of three places:
##
## - the app's [Store], held at the root: named cells ([Cell]) that any
##   context reads and writes with no `lift`, written by decisions (`handle`,
##   `react`) that return their writes ([Write]);
## - a table (`table`), a cell of the store holding rows by key, drawn
##   through a filtered, sorted, windowed view (`table_view`);
## - local state (`state`), which lives and dies with the piece of
##   the view that declares it ([State]).
##
## A component is a function, usually of a type module, over what it is
## handed: the cells it reads and writes, or a [State].
##
## Every dynamic site (`state`, `derive`, `resource`, `when`, `switch`,
## `remount_on`, `each`, `table_view`, effect sites) is one closure that owns
## its typed storage, so updates happen in place. `design.md`
## ("Representation: Sites That Own Their Storage") describes the model;
## Appendix B specifies the command stream and the host protocol.
##
## Every type here is opaque: an app builds values with the functions below
## and never sees their representation. The engine itself is the platform's
## internal `Core` module.
Engine := [].{

	## The context at the top of an application without a store: the context of
	## the [Elem] that `program`'s view returns. Nested contexts ([In], [Row])
	## are built on top of it.
	Root : Core.Root({})

	## The context at the top of an app with a store (`program_store`): the
	## root holds the store, whose storage type is `st`. It is the context of
	## the [Elem] that `program_store`'s view returns, written
	## `Engine.StoreRoot(_)`. Other code rarely names it: a function that
	## uses the store is generic over its context, with
	## `where [ctx.store : () -> Reach(ctx, st)]`.
	StoreRoot(st) : Core.Root(st)

	## How a context `ctx` reaches the app's store, whose type is `st`.
	## Every context of an app built with `program_store` has one, answered by
	## its `store` method ([StoreRoot], [In] and [Row] each have it), and it
	## is the one thing a function that reads or writes cells asks of its
	## context:
	##
	## ```
	## badge : {} -> Elem(ctx)
	##     where [ctx.store : () -> Engine.Reach(ctx, _)]
	## ```
	##
	## The store's type can be left to the compiler with `_`, as here, or
	## named once in the module that builds the store.
	Reach(ctx, st) : Core.StoreReach(ctx, st)

	## The storage type of the store that `tag` names, whose cells'
	## types nest as `st` (see `store`). It is what `st` stands for in a
	## [Cell], a [Write] and a [Reach] of that store.
	Stored(tag, st) : Core.Stored(tag, st)

	## One cell of the app's store, whose type is `st`, holding an `a`.
	## Get the cells from the [Store] (`cells`); each
	## cell's place in the store comes from its place in the description.
	##
	## A cell is read in any context, at any depth, with no `lift`: `signal` needs
	## only that the context reaches a store of type `st`, which every context of
	## an app built with `program_store` does. It is written by a decision:
	## `set` and `update` make the writes a `handle` or a `react` returns. A
	## write to a cell refreshes the readers of that cell and no one else's.
	Cell(st, a) :: { c : Core.Cell(st, a) }.{

		## The cell's current value.
		signal : Cell(st, a) -> Signal(ctx, a)
			where [ctx.store : () -> Reach(ctx, st)]
		signal = |{ c }| { v: c.signal() }

		## The cell as a [State] of the context this is called in, for a
		## component that takes a `State(ctx, a)` and should not care whether
		## its state is the app's or its own. A write through that state is
		## a write of the cell.
		state : Cell(st, a) -> State(ctx, a)
			where [ctx.store : () -> Reach(ctx, st)]
		state = |{ c }| { s: c.state() }

		## A [Write] that replaces the cell with `value`, for the list a
		## decision returns (`handle`, `react`). Use it for a value that does
		## not come from the cell itself; to update what the cell holds, use
		## `update`.
		set : Cell(st, a), a -> Write(st)
		set = |{ c }, value| c.set(value)

		## A [Write] that replaces the cell with `f` of it, for the list a
		## decision returns. `f` receives the value uniquely owned, so a
		## large value (a list, a table) is changed in place: `set` of a
		## value built from a reading of the cell would copy it, and so
		## would an `f` that holds such a reading.
		update : Cell(st, a), (a -> a) -> Write(st)
		update = |{ c }, f| c.update(f)
	}

	## One write to the store, as a value: which cells, and how. Make one
	## with `Cell.set`, `Cell.update` or a group's reset
	## (`Cells.with_reset`), and return a list of them from the function
	## given to `handle` or `react`. The list is the whole transition: the
	## engine applies it in order and wakes the readers of exactly the cells
	## it names. Each write's value comes from the one reading the decision
	## was given, so the order of writes to different cells never matters.
	##
	## An `update` after another write of its cell sees that write's result,
	## and a write after the reset of its group refines the reset ("start
	## again, but with this"). Any other `set` or reset of a cell the same
	## list already wrote would discard that write: it is a contract error
	## that names the handler's or the reaction's site, the cell's position
	## in the store and the two writes.
	Write(st) : Core.Write(st)

	## `handle(decide)` is a handler that writes the cells `decide` names,
	## given the event's payload (an input's value, `"true"`/`"false"` for a
	## checkbox, `""` for a click): one pure function decides a transition
	## that spans cells.
	##
	## ```
	## Engine.on_click(Engine.handle(|_| [cells.count.update(|n| n + 1), cells.last.set("bumped")]))
	## ```
	##
	## Only the cells in the list are written, so a decision that returns
	## `[]` wakes no one. It works at any depth with no `lift`, as cells do.
	## To write local state in the same event, compose it with that state's
	## handler (`Handler.also`).
	handle : (p -> List(Write(st))) -> HandlerOf(ctx, p)
		where [ctx.store : () -> Reach(ctx, st)]
	handle = |decide| { h: Core.store_handler(decide) }

	## As `handle`, where `decide` also receives `v`, read once when
	## the event fires and before any of this decision's own writes, so
	## every write is computed from the same reading:
	##
	## ```
	## Engine.handle_by(here, |at, _| if (at.session.is_signed_in()) [cells.loc.set("/home")] else [])
	## ```
	##
	## To read several values, combine them into one with the record
	## builder ([Signal]). Composed after another handler
	## (`first.also(Engine.handle_by(v, ..))`), the reading is taken after
	## `first` has written: `draft.update(|_| "").also(Engine.handle_by(draft.signal(), ..))`
	## reads the emptied draft. Put the decision first to read what the
	## event found.
	handle_by : Signal(ctx, b), (b, p -> List(Write(st))) -> HandlerOf(ctx, p)
		where [ctx.store : () -> Reach(ctx, st)]
	handle_by = |b, decide| { h: Core.store_handler_by(b.v, decide) }

	## `does(writes)` is a handler that makes `writes`, whatever the
	## event's payload: the handler of a button whose transition needs
	## nothing from the event.
	##
	## ```
	## Html.button("Reset", [], Engine.does([cells.form.reset, cells.note.set("Started again")]))
	## ```
	##
	## The list is built where the handler is made, once, so it cannot
	## depend on the payload or on a reading: a transition that does is a
	## `handle` or a `handle_by`.
	does : List(Write(st)) -> HandlerOf(ctx, p)
		where [ctx.store : () -> Reach(ctx, st)]
	does = |writes| { h: Core.store_handler(|_| writes) }

	## `react(decide)` is an effect site's [Reaction] that writes the cells
	## `decide` names, given the value the request was issued for and its
	## result: an answer's whole transition, as `handle` is an event's.
	react : (r, Result -> List(Write(st))) -> Reaction(ctx, r)
		where [ctx.store : () -> Reach(ctx, st)]
	react = |decide| Core.store_reaction(decide)

	## As `react`, where `decide` also receives `v`, read once when
	## the result arrives and before any of this decision's own writes.
	## Composed after another reaction (`Reaction.also`), the reading is
	## taken after that reaction has written.
	react_by : Signal(ctx, b), (b, r, Result -> List(Write(st))) -> Reaction(ctx, r)
		where [ctx.store : () -> Reach(ctx, st)]
	react_by = |b, decide| Core.store_reaction_by(b.v, decide)

	## A description of cells: build one with `cell` and Roc's record
	## builder, which calls `map2`, and nest one description in another:
	##
	## ```
	## schema = { session: Engine.cell(Anonymous), page: Article.cells({}) }.Cells
	## ```
	##
	## Each cell's place in the store comes from its position in the
	## description, so a feature module exports the description of its own
	## cells and the app nests it as it is. `whole` is the storage of the
	## store the cells end up in and `st` theirs within it; an annotation
	## can leave `st` to the compiler:
	## `cells : {} -> Engine.Cells(whole, _, Handles(whole))`.
	Cells(whole, st, h) :: { d : Core.Cells(whole, st, h) }.{

		## Two descriptions side by side: the record builder's combinator.
		map2 : Cells(whole, a, ha), Cells(whole, b, hb), (ha, hb -> hc) -> Cells(whole, (a, b), hc)
		map2 = |l, r, f| { d: l.d.map2(r.d, f) }

		## The same cells, handing out `f` of them: a feature can
		## give its owner its cells in whatever shape suits it.
		map : Cells(whole, st, h), (h -> k) -> Cells(whole, st, k)
		map = |{ d }, f| { d: d.map(f) }

		## The same cells, handing out `f` of them and of a
		## [Write] that starts every one of them again at the value it was
		## described with:
		##
		## ```
		## { draft: Engine.cell(""), sent: Engine.cell(0) }.Engine.Cells.with_reset(|cells, reset| { cells, reset })
		## ```
		##
		## The write belongs to the description, so a cell added to it later
		## is started again by the same write and no list of cells to reset
		## is kept anywhere. A cell starts again at the value its description
		## gave it, not at one `Store.with_initial` put there; a table starts
		## again at the rows it was described with, as a whole rewrite, so
		## its views rebuild.
		with_reset : Cells(whole, st, h), (h, Write(whole) -> k) -> Cells(whole, st, k)
		with_reset = |{ d }, f| { d: d.with_reset(f) }
	}

	## The description of one cell that starts at `init`, a field of the
	## record a store's cells are described with:
	##
	## ```
	## { count: Engine.cell(0), name: Engine.cell("") }.Engine.Cells
	## ```
	##
	## The record builder combines two fields or more. A description of
	## one cell is that cell, put in a record by `map`:
	##
	## ```
	## Engine.cell("").map(|source| { source: source })
	## ```
	cell : a -> Cells(whole, a, Cell(whole, a))
	cell = |init| { d: Core.cell(init).map(wrap_cell) }

	## The description of one cell holding a table of `rows` by key
	## (`Table`), for rows that are edited by key and drawn as a list:
	##
	## ```
	## { todos: Engine.table(Todo.sample), query: Engine.cell(Todo.all) }.Engine.Cells
	## ```
	##
	## Its cell is an ordinary [Cell]. A decision changes the table with
	## the table's own operations, so every write records the rows it
	## changed, and it stands in the decision's list beside its other
	## writes:
	##
	## ```
	## Engine.handle_by(key, |id, _| [todos.update(|table| table.update(id, Todo.toggle)), edits.update(|n| n + 1)])
	## ```
	##
	## `table_view` draws a filtered, sorted window of the table from that
	## changes, at the cost of the rows written, never of the table. A write
	## that leaves another table in the cell than the one it held (a `put`
	## of a new one from `Table.from_list`, a copy kept from earlier) is a
	## whole rewrite: every view of the cell rebuilds.
	##
	## Read one row or the count with the cell's `signal`
	## (`todos.signal().map(|table| table.len())`). Such a reader is
	## re-evaluated on every write of the table, and pruned if its result
	## is equal; only a row of a `table_view` wakes for its own row alone.
	table : List({ key : k, row : v }) -> Cells(whole, Table(k, v), Cell(whole, Table(k, v)))
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	table = |rows| { d: Core.table(rows).map(wrap_cell) }

	## Which rows of a table a view shows and in what order: `keep`
	## says whether a row is in the view, `sort` gives the value it is
	## ordered by, and `compare` orders two sort values. The order must be
	## total: two rows that compare `Same` are a contract error, when the
	## view mounts, after a write, and also between the keyed writes of one
	## event, which the view takes one key at a time. Two rows that swap
	## their places in one event tie while the first is written, though
	## they never tie before or after it. So a sort value ends with the
	## key, whatever the sorted field: `{ place: row.place, key }`, compared
	## by `place` and then by `key`.
	QueryPlan(k, v, s) : Core.QueryPlan(k, v, s)

	## The part of a view that is drawn: `count` rows from position
	## `start` of the view's order. A window that reaches past the last row
	## draws the rows there are.
	Window : Core.Window

	## The window that draws every row a view keeps, however many it comes
	## to hold: `window: Engine.const(Engine.every_row)`. It is for a list
	## that is short by nature (the cards of a column, the fields of a
	## form). A row that enters, leaves or moves costs the rows drawn, so a
	## long list wants a window of its own.
	every_row : Window
	every_row = { start: 0, count: U64.highest }

	## What a `table_view` shows of its table. `query` is plain data
	## the site can compare (the filter and order the user chose) and
	## `plan` turns it into the [QueryPlan] that selects and orders rows;
	## `window` is the part of that order to draw.
	TableViewProps(ctx, q, k, v, s) : { query : Signal(ctx, q), plan : (q -> QueryPlan(k, v, s)), window : Signal(ctx, Window) }

	## `table_view(table, props, template)` renders one row for each
	## row of `table` in the window of a filtered, sorted view of it:
	##
	## ```
	## Engine.table_view(
	##     todos,
	##     { query: query.signal(), plan: Todo.plan, window: window.signal() },
	##     |key, todo| Todo.row(key, todo),
	## )
	## ```
	##
	## The site keeps the view (the ordered keys of every row that passes
	## the filter) up to date from the table's changes: a turn
	## that wrote some rows costs those rows, a search and a move in the
	## ordered keys each, whatever the size of the table. No list of rows
	## is built, kept or compared. A row that left the window is removed,
	## one that entered is created, one that moved is moved with its nodes
	## and any state nested in it, and one whose row was written
	## re-evaluates its own holes.
	##
	## `template` runs once per site and must return a single element. It
	## is given the row's key, fixed for the drawn row's lifetime, and a
	## [State] of the row in its context: `row.signal()` reads
	## the row of that key from the table, and `row.update(f)` and its
	## relatives write that row of that table (`Table.update`), so a row's
	## handlers cannot name another table by mistake and a component drawn
	## over a `State` draws a row unchanged. Other writes are decisions
	## over the table's cell
	## (`Engine.handle_by(key, |id, _| [todos.update(|table| table.remove(id))])`).
	## Values from the enclosing context enter with `lift_row`.
	##
	## The site finds a row by the table's key itself, through the key's
	## `is_eq` and `to_hash`. A row is drawn while it is in the window:
	## state nested in it is kept when the row moves and dropped when it
	## leaves the window. An event changes the rows drawn once, whatever
	## it wrote of the table, the query and the window: a row drawn before
	## the event and after it is the same row throughout, and the rows
	## that enter are created from the first to the last, as at mount.
	##
	## A change of `query` to an unequal value, or a whole rewrite of the
	## table, rebuilds the view in the size of the table; a change of
	## `window` costs the two windows. A row removed from the table must
	## not be read again by the handler that removed it: that is a
	## contract error.
	table_view : Cell(st, Table(k, v)), TableViewProps(ctx, q, k, v, s), (Signal(Row(ctx, k), k), State(Row(ctx, k), v) -> Elem(Row(ctx, k))) -> Elem(ctx)
		where [ctx.store : () -> Reach(ctx, st), k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher, q.is_eq : q, q -> Bool]
	table_view = |{ c }, { query, plan, window }, template| Core.table_view(c, { query: query.v, plan, window: window.v }, |key, row| template({ v: key }, { s: row }))

	## An app's store: the cells it holds, their starting values, and the
	## cells it gives to readers. Build it once with `store`, as a top-level value a
	## module that composes the app can import, and hand it to
	## `program_store`.
	Store(st, h) :: { s : Core.Store(st, h) }.{

		## The record of cells its description produced.
		cells : Store(st, h) -> h
		cells = |{ s }| s.cells()

		## The same store with `cell` starting at `value` instead, for a
		## start that depends on the boot data. For a table cell, `value` is
		## the table `Table.from_list` gives. It is a start, not a write: the
		## table has no changes afterwards, so a test that applies a
		## transition with `after` reads that transition's rows in it.
		with_initial : Store(st, h), Cell(st, a), a -> Store(st, h)
		with_initial = |{ s }, { c }, value| { s: s.with_initial(c, value) }

		## The same store after `writes`, applied as the engine applies a
		## decision's (a replaced write is the same contract error), for a
		## pure `expect` on a transition:
		##
		## ```
		## expect store.after(signed_out(at)).read(cells.session) == Anonymous
		## ```
		##
		## The writes are applied and no turn ends, so a table keeps its
		## changes describing them: `store.after(writes).read(table).inverse()` tells
		## which rows a transition wrote. Across chained `after`s the changes
		## holds the rows all of them wrote.
		after : Store(st, h), List(Write(st)) -> Store(st, h)
		after = |{ s }, writes| { s: s.after(writes) }

		## What `cell` holds in this store: its starting value, or
		## with `after`, what a transition left in it.
		read : Store(st, h), Cell(st, a) -> a
		read = |{ s }, { c }| s.read(c)
	}

	## The store the cells `d` describe, named by `tag`: a value of
	## a type declared for this store, usually the one tag of the module
	## that builds it:
	##
	## ```
	## AppStore := [Conduit].{
	##     store = Engine.store(AppStore.Conduit, { session: Engine.cell(Anonymous), .. }.Engine.Cells)
	## }
	## ```
	##
	## The name is part of the type of every cell the store gives out,
	## so a cell of another store is a type error wherever this one is
	## reached, even when the two stores' cells have the same types.
	store : tag, Cells(Stored(tag, st), st, h) -> Store(Stored(tag, st), h)
	store = |tag, { d }| { s: Core.store_of(tag, d) }

	## The context inside a `state`, `derive` or resource body: it can read a
	## value of type `s` beside what `outer` can read. Signals and handlers
	## from `outer` enter with `lift`.
	In(outer, s) : Core.In(outer, s)

	## The context inside one row of an `each` or a `table_view` template,
	## nested in `outer`: the row's key and item (for a view's row, the
	## table's key). Values and handlers from `outer` enter with `lift_row`.
	Row(outer, item) : Core.Row(outer, item)

	## A read-only signal of type `a`, readable in context `ctx`.
	##
	## A signal declares what it reads when it is built; dependencies are never
	## discovered by running a reader. Only readers of what a turn wrote are
	## re-evaluated. Make a signal with `const`, `State.signal`, `Cell.signal`,
	## a [RowRef] accessor or `derive`, then transform it with `map` and `map2`.
	## A signal is a recipe, not a cache: mapping functions run each time a
	## reader is re-evaluated, so they must be pure and should be cheap
	## (`derive` memoises an expensive or shared result).
	##
	## `map2` has the shape Roc's record builder calls, so several signals
	## combine into one signal of a record, which reads what all of them
	## read: `{ filter: cells.filter.signal(), sort: cells.sort.signal() }.Engine.Signal`.
	## It is how a decision takes a reading of several cells (`handle_by`,
	## `react_by`) and how a table view's query is made of two.
	Signal(ctx, a) :: { v : Core.Signal(ctx, a) }.{

		## Transform a signal with a pure function. The result has the same reads
		## as the input; the function runs wherever the result is read, each time a
		## dependency changes.
		map : Signal(ctx, a), (a -> b) -> Signal(ctx, b)
		map = |{ v }, f| { v: v.map(f) }

		## Combine two values with a pure function. The result reads the union of
		## both inputs' dependencies. It is also what the record builder calls
		## (`{ a: va, b: vb }.Engine.Signal`).
		map2 : Signal(ctx, a), Signal(ctx, b), (a, b -> c) -> Signal(ctx, c)
		map2 = |l, r, f| { v: l.v.map2(r.v, f) }

		## Use a value from the enclosing context inside a `state` or `derive` body
		## nested in it. The signal keeps the same dependencies.
		lift : Signal(ctx, a) -> Signal(In(ctx, s), a)
		lift = |{ v }| { v: v.lift() }

		## Use a value from the enclosing context inside an `each` row template
		## nested in it. The signal keeps the same dependencies.
		lift_row : Signal(ctx, a) -> Signal(Row(ctx, item), a)
		lift_row = |{ v }| { v: v.lift_row() }
	}

	## An event handler usable in context `ctx`: what an event writes, given
	## a payload of type `p`. An attach function chooses the payload kind, so
	## text and received files use the same reducers, decisions and composition. Make one with the [State] methods for local state, or
	## with `handle` for the store's cells, and attach it with `on`,
	## `on_click` or an `Html` control. A handler runs once per event, in the
	## turn that delivers it.
	HandlerOf(ctx, p) :: { h : Core.HandlerOf(ctx, p) }.{

		## Use a handler from the enclosing context inside a `state` or `derive` body
		## nested in it.
		lift : HandlerOf(ctx, p) -> HandlerOf(In(ctx, s), p)
		lift = |{ h }| { h: h.lift() }

		## Use a handler from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : HandlerOf(ctx, p) -> HandlerOf(Row(ctx, item), p)
		lift_row = |{ h }| { h: h.lift_row() }

		## `first.also(second)` is one handler that runs `first` and then
		## `second` for the same event, as one atomic transition. `second`
		## sees what `first` wrote, so two writes of one state compose, and
		## what they wrote is observed together once the event settles: no
		## text, branch or effect site ever sees one new value beside the
		## other's old one. An element takes one handler per event (a second one is a
		## contract error), so this is how a click writes local state and
		## also runs a decision, or a handler its owner passed down:
		##
		## ```
		## Engine.on_click(open.update(|_| False).also(picked.lift()))
		## ```
		##
		## It costs one closure call more per event.
		also : HandlerOf(ctx, p), HandlerOf(ctx, p) -> HandlerOf(ctx, p)
		also = |first, second| { h: first.h.also(second.h) }
	}

	## Text events use the generic handler family with a text payload.
	Handler(ctx) : HandlerOf(ctx, Str)

	## File events use that same family with received handles and refusals.
	FilesHandler(ctx) : HandlerOf(ctx, Received)

	## A file the user gave the app, or a range of one (`File.slice`): a handle
	## with its `name`, `size` and `mime` type, never its bytes on the page. Send
	## it to a worker task in the task's input, and read its bytes in the job
	## with `read!` or `contents!`, which bring across exactly what the job asks
	## for. For a small file, `read_bytes({})` and `read_utf8({})` ask for its
	## bytes on the page instead. A file stays available while any value holds
	## it, and is released when nothing does.
	File : Core.File

	## The files one event delivered, and how many more it carried than the
	## instance could hold (they were not delivered).
	Received : Core.Received

	## How much a read of a file into the page accepts: `max_bytes`, 8 MiB
	## unless the app says otherwise (`file.read_bytes({ max_bytes: n })`),
	## under the page's `maxFileBytes` ceiling.
	ReadProps : Core.ReadProps

	## How `File.upload` sends a file: `url` (required), `method` (`"POST"`
	## by default), `headers` (none by default) and `timeout` (`Unlimited`
	## by default, or `Ms(ms)`).
	UploadProps : Core.UploadProps

	## A piece of state as context `ctx` sees it, holding an `s`.
	## `state` makes a local one, `Cell.state` gives a cell as one, and a
	## table view gives each drawn row its row as one.
	##
	## Read it with `signal`; write it only through handlers (`update`, `set_value`,
	## ...) and reactions (`on_result`). A write marks the state changed and its
	## readers refresh; equality pruning happens where the value is read (text,
	## attributes, rows, `derive`), not at the state, so a reducer that returns an
	## equal value still costs a refresh pass but emits no DOM commands. Reducers
	## receive the value uniquely owned, so list and record updates happen in place.
	State(ctx, s) :: { s : Core.State(ctx, s) }.{

		## The state's current value.
		signal : State(ctx, s) -> Signal(ctx, s)
		signal = |{ s }| { v: s.signal() }

		## A handler that replaces the state with `f` of it, ignoring the event's
		## payload.
		update : State(ctx, s), (s -> s) -> HandlerOf(ctx, p)
		update = |{ s }, f| { h: s.update(f) }

		## A handler whose reducer also receives `v`, read in the handler's context
		## when the event fires (typically the row key or a row field), so a row's
		## handler needs no captured row.
		update_by : State(ctx, s), Signal(ctx, b), (s, b -> s) -> HandlerOf(ctx, p)
		update_by = |{ s }, b, f| { h: s.update_by(b.v, f) }

		## An effect site's [Reaction] that writes this state: the reducer receives
		## the value the request was issued for and its [Result]. If the state has been
		## disposed by the time a reparented result arrives, the write is skipped and
		## counted (`skipped`).
		on_result : State(ctx, s), (s, a, Result -> s) -> Reaction(ctx, a)
		on_result = |{ s }, f| s.on_result(f)

		## A handler whose reducer receives its typed payload: text, received
		## file handles, or another kind chosen by its attach function.
		set_value : State(ctx, s), (s, p -> s) -> HandlerOf(ctx, p)
		set_value = |{ s }, f| { h: s.set_value(f) }

		## A handler whose reducer receives both `v`, read when the event fires, and
		## the event's payload.
		set_value_by : State(ctx, s), Signal(ctx, b), (s, b, p -> s) -> HandlerOf(ctx, p)
		set_value_by = |{ s }, b, f| { h: s.set_value_by(b.v, f) }

		## Use state from the enclosing context inside a `state` or `derive`
		## body nested in it.
		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ s }| { s: s.lift() }

		## Use state from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : State(ctx, s) -> State(Row(ctx, item), s)
		lift_row = |{ s }| { s: s.lift_row() }

	}

	## A keyed selection for `RowRef.select`: the selected key and the values a
	## selected and an unselected row see. Make one with `keyed`.
	Keyed(ctx, v) : Core.Keyed(ctx, v)

	## `keyed(selected, yes, no)`: rows whose key equals `selected` see `yes`, all
	## others `no`. Read through `RowRef.select`, a change of `selected`
	## re-evaluates exactly the previously and the newly selected rows instead of
	## every row.
	keyed : Signal(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sel, yes, no| Core.keyed(sel.v, yes, no)

	## The current row of an `each` template. The template runs once per `each`
	## site, not once per row, so it reads the row through these accessors rather
	## than receiving a row value.
	RowRef(outer, item) :: { r : Core.RowRef(outer, item) }.{

		## The row's key. It is fixed for the row's lifetime, so it never triggers a refresh.
		key : RowRef(outer, item) -> Signal(Row(outer, item), Str)
		key = |{ r }| { v: r.key() }

		## A projection of the row's item. It is re-evaluated only for rows whose new
		## item differs from the old one.
		field : RowRef(outer, item), (item -> a) -> Signal(Row(outer, item), a)
		field = |{ r }, f| { v: r.field(f) }

		## The row's whole item, for a handler or a reaction that takes it
		## as its reading (`Engine.handle_by(row.item(), ..)`). Like `field`,
		## it is re-evaluated only for rows whose new item differs from the
		## old one; a hole that shows one part of the item reads that part
		## with `field`.
		item : RowRef(outer, item) -> Signal(Row(outer, item), item)
		item = |{ r }| { v: r.item() }

		## `yes` or `no` from a [Keyed] selection, depending on whether this row's key
		## is the selected one.
		select : RowRef(outer, item), Keyed(outer, v) -> Signal(Row(outer, item), v)
		select = |{ r }, kd| { v: r.select(kd) }
	}

	## An attribute, event listener or focus reference on an element, in context
	## `ctx`. Make one with `attr`, `attr_s`, `attr_presence`, `class`,
	## `class_s`, `test_id`,
	## `test_id_s`, `on`, `on_click`, `ref` or `ref_s`.
	Attr(ctx) : Core.Attr(ctx)

	## A piece of UI in context `ctx`: an element, a text node or a dynamic site
	## (`state`, `derive`, `resource`, `when`, `switch`, `remount_on`, `each`,
	## `table_view` or an effect site).
	## An `Elem` is a description; the engine mounts it once and afterwards updates
	## only what reads a state or cell the turn wrote.
	Elem(ctx) : Core.Elem(ctx)

	## `state(init, body)` holds local state, starting at `init`, for the elements
	## `body` builds. There is one instance per mount of the site (so one per row
	## inside an `each` row) and it lives as long as the enclosing scope: it is
	## dropped when its branch or row is disposed, and starts again at
	## `init` if remounted. Values from the enclosing context enter `body` with
	## `lift`. Contexts nest without limit: past 64 nested states or derived
	## signals on one path a
	## write can cost a few extra evaluations, which equality pruning discards.
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Core.state(init, |s| body({ s: s }))

	## `each(rows, key, template)` renders one row per item of `rows`, identified by
	## `key(item)`. Rows are matched by key across updates: a surviving row is kept
	## (and moved if needed) rather than rebuilt, a row whose item is unchanged does
	## no work, and a changed item re-evaluates only that row's holes that read it.
	##
	## `template` runs once per site against a [RowRef] and must return a single
	## element. A duplicate key is a contract error. A row may name an element
	## with `ref_s`, usually from its key; reference names must be unique among
	## live elements, and the empty name names nothing.
	each : Signal(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Core.each(rows.v, key, |r| template({ r: r }))

	## `when(cond, yes, no)` builds only the branch `cond` selects, and rebuilds it
	## when `cond` changes, disposing the old branch with everything it owns.
	## Because the unselected branch is never built, recursive UI can be expressed
	## directly.
	when : Signal(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Core.when(cond.v, yes, no)

	## `switch(sel, cases, body)` builds `body(k)` for the current value `k` of
	## `sel`, and rebuilds it when `sel` changes to a different case. `cases` lists
	## every value `sel` can take, so the site listens to everything any branch
	## could read; a value outside `cases` is a contract error.
	switch : Signal(ctx, k), List(k), (k -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	switch = |sel, cases, body| Core.switch(sel.v, cases, body)

	## `remount_on(key, body)` builds `body()` and, whenever `key`
	## changes to a value unequal to the one the body was built for,
	## disposes it and builds it again from scratch, as `switch` does when
	## its case changes: its nodes are removed, state inside starts again,
	## timers and subscriptions inside are cancelled, and requests in flight
	## inside are kept and delivered here, where their writes to the
	## disposed state are skipped. Use it for state that belongs to one key,
	## such as a draft for the open message:
	##
	## ```
	## Engine.remount_on(open.signal(), || detail(open.signal()))
	## ```
	##
	## The body takes no argument: it reads the key, if it needs it, like
	## any other value. An equal key costs one evaluation of the key; an
	## unequal one, disposing and mounting the body. The site keeps the key
	## to compare, so a key should be small, such as an id.
	remount_on : Signal(ctx, k), (() -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	remount_on = |key, body| Core.remount_on(key.v, body)

	## `derive(input, body)` evaluates `input` once per change of what it
	## reads and gives `body` the result as a new signal. Readers inside `body` that
	## read only the derived value do no work while it is equal to the previous
	## result, so use `derive` for a value that is expensive or read in many
	## places. Values from the enclosing context enter `body` with `lift`.
	derive : Signal(ctx, a), (Signal(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Core.derive(input.v, |v| body({ v: v }))

	## A request from an effect site.
	##
	## Commands are emitted and forgotten: `Push` and `Replace` (history), `Title`,
	## `StorageSet` and `StorageRemove` (local storage), and `Focus`, `Blur` and
	## `SelectText` on a reference named with `ref` (resolved at the end of the
	## turn; a reference that is not mounted then is counted stale). With
	## `PortCommand` and `Save` they are the tags of [Command].
	##
	## Awaited requests deliver results to the site's [Reaction]: `Http`,
	## `StorageGet` and `Timer` deliver one; `Interval`, `Popstate`,
	## `OnlineChanges` and `VisibilityChanges` are subscriptions that deliver any
	## number until their site is disposed. `Self` asks for a follow-up turn whose
	## result is `Now`, so a site can write state in response to its value changing.
	## `Http`'s `timeout_ms` of 0 means no timeout; it is capped at 10 minutes.
	##
	## `Work` runs a job of the worker task registered under `task` (see
	## `Program.with_workers`) on `input`, off the page's thread, where it may
	## read the `files` its input holds through effects and answer with files
	## of its own; it delivers one `Work` answer or `WorkLost(fault)`.
	## `timeout_ms` 0 means no timeout; it is capped at 10 minutes and
	## delivers `Timeout` when it expires. `on_dispose` says whether disposing
	## its site stops the job (`Stop`, like a timer) or keeps it, delivering
	## its answer to the nearest surviving ancestor (`Keep`); `on_cancel`
	## whether a cancelled running job ends its worker (`Stop`) or completes
	## with its answer dropped (`Finish`). A preparation's task is `Prepared`,
	## its input led by the preparation's. Issuing work for a task that is not
	## registered is a contract error. Apps use the typed API, `Worker`,
	## which builds it.
	##
	## `ReadBytes` and `ReadUtf8` read a file into the page (`File.read_bytes`,
	## `File.read_utf8`) and deliver one `FileBytes`, `FileText` or
	## `FileFailed`. `Sha256` digests a file and `ObjectUrl` makes a URL that
	## shows it (`File.sha256`, `File.object_url`), delivering `Digest`,
	## `FileUrl` or `FileFailed`. Like a timer these belong to their site.
	## `Upload` is an HTTP request whose body is a file (`File.upload`): it is
	## answered and kept as `Http` is.
	Request : [
		## `timeout_ms` 0 = no timeout; capped at `max_timeout_ms`.
		Http({ method : Str, url : Str, headers : List((Str, Str)), body : Str, timeout_ms : U32 }),
		StorageGet(Str),
		Timer(U32),
		Work({ task : Str, input : List(U8), files : List(File), timeout_ms : U32, on_dispose : [Stop, Keep], on_cancel : [Stop, Finish], prepared : [Unprepared, Prepared({ name : Str, input_len : U64, input_files : U64 })] }),
		Interval(U32),
		Popstate,

		## Subscriptions to the browser's connectivity (`online`/`offline`)
		## and page visibility (`visibilitychange`). Each change delivers
		## `Online(Bool)` or `Visible(Bool)`; the value at mount is in `Boot`.
		OnlineChanges,
		VisibilityChanges,
		Self,
		Push(Str),
		Replace(Str),
		Title(Str),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		StorageSet(Str, Str),
		StorageRemove(Str),
		ReadBytes({ file : File, max_bytes : U64 }),
		ReadUtf8({ file : File, max_bytes : U64 }),
		Upload({ method : Str, url : Str, headers : List((Str, Str)), body : File, timeout_ms : U32 }),
		Sha256(File),
		ObjectUrl(File),

		## Ports: a message to the page's JavaScript for a declared port (see
		## `PortRegistration`; apps use the typed API, `Port`). `PortCommand` is
		## emitted and forgotten; `PortCall` awaits one `PortAnswer` or
		## `PortFailed` and, like `Http`, survives its site's disposal
		## (`timeout_ms` 0 = none, capped at 10 minutes); `PortSubscribe`
		## delivers any number of messages until its site is disposed or the
		## JavaScript ends it.
		PortCommand({ port : Str, message : PortMessage }),
		PortCall({ port : Str, message : PortMessage, timeout_ms : U32 }),
		PortSubscribe({ port : Str, message : PortMessage }),

		## A command that saves a file's range as a download (`File.save`).
		Save({ file : File, name : Str }),

		## An HTTP request whose response body becomes a file
		## (`File.fetch`), answered `Fetched`; kept like `Http`.
		Fetch({ method : Str, url : Str, headers : List((Str, Str)), timeout_ms : U32 }),
	]

	## A request that is emitted and forgotten: the commands of [Request],
	## and nothing that awaits a result. It is what the plan of an
	## `on_cleanup` returns, where a request that awaits a result would
	## outlive the scope that asked for it: this type has no such tag, so a
	## cleanup that asks for one does not compile.
	##
	## Each tag carries what the tag of the same name in [Request] carries,
	## and a value written as a tag (`Title("Inbox")`), or built by
	## `File.save` or a port command's `send`, fits a list of either type.
	Command : [
		Push(Str),
		Replace(Str),
		Title(Str),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		StorageSet(Str, Str),
		StorageRemove(Str),
		PortCommand({ port : Str, message : PortMessage }),
		Save({ file : File, name : Str }),
	]

	## The result of an awaited request: an HTTP response (`Http`, with any status),
	## a network failure (`Network`) or `Timeout`, a storage `Value` or `Missing`, a
	## timer or interval tick (`Fired`), the URL after `Popstate` (`Location`), a
	## connectivity or visibility change (`Online`, `Visible`), a `Self` follow-up
	## (`Now`), `Refused` when the in-flight bound turned the request away, or a
	## worker job's answer with the files it holds, handles the page now owns
	## (`Work`; `Worker` decodes it) or the reason it produced none
	## (`WorkLost`), a file's bytes or text read into the page (`FileBytes`,
	## `FileText`), a file's SHA-256 digest (`Digest`) or a URL that shows it
	## (`FileUrl`), or why an operation on a file produced nothing
	## (`FileFailed`), or a port's answer or message (`PortAnswer`) or why
	## there is none (`PortFailed`), or a response whose body is a file
	## (`Fetched`).
	Result : [Http({ status : U16, headers : List((Str, Str)), body : Str }), Network(Str), Timeout, Value(Str), Missing, Fired, Location(Str), Online(Bool), Visible(Bool), Now, Refused, Work({ output : List(U8), files : List(File) }), WorkLost(WorkFault), FileFailed(FileError), FileBytes(List(U8)), FileText(Str), Digest(List(U8)), FileUrl(Str), PortAnswer(PortMessage), PortFailed(PortFailure), Fetched({ status : U16, headers : List((Str, Str)), body : File })]

	## A port message as it crosses: JSON text, the byte blocks its
	## `{"$bytes":N}` markers name and the files its `{"$file":N}` markers
	## name. `Port` writes and reads it for an app's own types.
	PortMessage : Core.PortMessage

	## Why a port request has no answer: the page's JavaScript threw or
	## rejected, or answered with something that is not JSON data (`Threw`,
	## with the message), its answer was larger than the runtime takes
	## (`TooLarge`), or it ended a subscription (`Closed`). `Threw` and `Closed` end a subscription;
	## `TooLarge` reports one message and the subscription goes on.
	PortFailure : Core.PortFailure

	## How a subscription's undelivered messages wait: `Latest` keeps only
	## the newest; `Every(n)` keeps up to `n` (1 to 1024) in order and refuses
	## the JavaScript's `emit` beyond them.
	PortDelivery : Core.PortDelivery

	## A port the program registers with `Program.with_ports`: its name and
	## shape. Each typed port makes its own (`registration`).
	PortRegistration : Core.PortDecl

	## Why an operation on a file produced nothing. One closed type for every
	## operation on a file, each of which says which arms it can produce:
	##
	## - `Unreadable`: the user's file changed or went away since it was given;
	## - `TooLarge`: it is more than the operation accepts: a page read past
	##   its `max_bytes` or the page's `maxFileBytes` mount option, a digest of
	##   a range past `maxFileBytes`, a URL for a 17th range of one file, or,
	##   in a task's job, an `append!` that would take what the job has
	##   appended past the `maxOutputBytes` mount option;
	## - `InvalidUtf8`: text was asked for and the bytes are not UTF-8;
	## - `Unavailable`: the browser cannot perform the operation (a digest
	##   without WebCrypto, which a page served over plain HTTP from another
	##   host than localhost does not have);
	## - `Refused`: the in-flight bound turned the request away, as the typed
	##   readers (`file_bytes`, `file_text`, `file_digest`, `file_url`) report
	##   it (a raw result is `Refused` itself).
	##
	## A task's job reads files with effects that answer it too, and a task
	## that passes it on answers `Worker.Error`'s `Failed`.
	FileError : [Unreadable, TooLarge, InvalidUtf8, Unavailable, Refused]

	## A `File.read_bytes` result as the file's bytes or a typed [FileError]:
	## `TooLarge`, `Unreadable` or `Refused`. Any other result is a contract
	## error.
	file_bytes : Result -> Try(List(U8), FileError)
	file_bytes = |res| Core.file_bytes(res)

	## A `File.read_utf8` result as the file's text or a typed [FileError]:
	## `InvalidUtf8`, `TooLarge`, `Unreadable` or `Refused`. Any other result
	## is a contract error.
	file_text : Result -> Try(Str, FileError)
	file_text = |res| Core.file_text(res)

	## A `File.sha256` result as the digest's 32 bytes or a typed [FileError]:
	## `TooLarge`, `Unavailable`, `Unreadable` or `Refused`. Any other result
	## is a contract error.
	file_digest : Result -> Try(List(U8), FileError)
	file_digest = |res| Core.file_digest(res)

	## A `File.object_url` result as the URL or a typed [FileError]: `TooLarge`
	## (a 17th range of one file) or `Refused`. Any other result is a contract
	## error.
	file_url : Result -> Try(Str, FileError)
	file_url = |res| Core.file_url(res)

	## Why a `Work` request produced no answer: the worker's instance faulted
	## running the job (`Contract`, `ResourceLimit`, `OutOfMemory`, `AppCrash`
	## and `ExpectFailed`, the fault classes of an instance; `ResourceLimit`
	## also when the page has no room for the files of an answer), the
	## browser has no workers or a job running on the page's thread reached a
	## worker-only effect (`Unavailable`), or the worker itself failed
	## (`Executor`). The diagnostic goes to the page's console, never into the
	## result.
	WorkFault : [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## Why an HTTP request did not produce a successful response, as `http_text`
	## reports it: the browser could not reach the server (`Network`, with the
	## browser's message), the request's `timeout_ms` expired (`Timeout`), the
	## server answered outside 2xx (`Status`), or the in-flight bound refused the
	## request (`Refused`).
	HttpError : [Network(Str), Timeout, Status(U16), Refused]

	## An HTTP result as the body of a 2xx response or a typed [HttpError]. Apps
	## that classify statuses themselves match on `Http` directly. Any result that
	## is not from an HTTP request is a contract error.
	http_text : Result -> Try(Str, HttpError)
	http_text = |res| Core.http_text(res)

	## Why a `File.fetch` produced no file: `Network`, `Timeout`, a status
	## outside 2xx (`Status`), a body over the `maxFileBytes` mount option
	## (`TooLarge`), or the in-flight bound (`Refused`).
	FetchError : Core.FetchError

	## A `File.fetch` result as the body of a 2xx response, a file the page
	## holds, or a typed [FetchError]. To read the status or the headers,
	## match on `Fetched` instead. Any other result is a contract error.
	fetched : Result -> Try(File, FetchError)
	fetched = |res| Core.fetched(res)

	## A file a task's job is writing: make one with `Files.build!`, append
	## to it with `append!` and `append_file!`, and `finish!` it into a
	## [File]. It lives only in the job that opened it.
	Builder : Core.Builder

	## What an effect site does with a result: what it writes, given the value
	## the request was issued for and the [Result]. Make one with `State.on_result`
	## for local state or with `react` for the store's cells, or use `ignore`.
	## `first.also(second)` runs both on one result, in order, as one atomic
	## transition, the second seeing the first's writes, like `Handler.also`.
	Reaction(ctx, a) : Core.Reaction(ctx, a)

	## A reaction that discards every result, for sites that only issue commands.
	ignore : {} -> Reaction(ctx, a)
	ignore = |_| Core.ignore({})

	## `on_cleanup(name, v, plan)` runs `plan` on `v`, read in the scope's last
	## environment, when the scope this site is mounted in is disposed, and issues
	## the commands in the disposing turn. A plan returns [Command]s (history,
	## title, storage writes, focus, port commands, saves): a request that awaits
	## a result would outlive its owner, and the type has none, so the compiler
	## rejects it. Each run is counted by `name`. The site renders nothing and
	## reads nothing while it is live.
	on_cleanup : Str, Signal(ctx, a), (a -> List(Command)) -> Elem(ctx)
	on_cleanup = |name, v, plan| Core.on_cleanup(name, v.v, plan)

	## A cleanup site that issues nothing and only counts its runs under `name`.
	cleanup : Str -> Elem(ctx)
	cleanup = |name| Core.cleanup(name)

	## `watch(v, plan, reaction)` issues `plan(v)` when the site mounts and again
	## whenever `v` changes to an unequal value; results go to `reaction`. Awaited
	## requests belong to the site: when it is disposed, its subscriptions,
	## timers, operations on files and worker jobs are cancelled, and admitted
	## `Http`, `Upload`, `Fetch` and `StorageGet` requests, port calls and the
	## jobs of tasks that say `on_dispose: Keep` are delivered to the nearest
	## surviving ancestor instead. At most 32 requests are
	## in flight by default (see `program_boot`); beyond that a request is answered
	## with `Refused`.
	watch : Signal(ctx, a), (a -> List(Request)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch = |v, plan, reaction| Core.watch(v.v, plan, reaction)

	## Like `watch`, but issues only when `v` changes after mount, never for its
	## initial value.
	watch_changes : Signal(ctx, a), (a -> List(Request)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch_changes = |v, plan, reaction| Core.watch_changes(v.v, plan, reaction)

	## `watch_latest(v, plan, reaction)` issues like `watch` (at mount, and whenever `v`
	## changes to an unequal value) but keeps only the requests of the current
	## value: the latest value wins. Before it issues for a new value, every
	## awaited request it still owns from earlier ones is cancelled, whatever its
	## kind (an `Http` request is aborted, a subscription stops, a timer is
	## cleared), and follow-ups or refusals still queued for it are dropped, all
	## counted (`cancelled`, `stale`). A late answer for a superseded value never
	## reaches `reaction`, so a search box or a selected item needs no request
	## serial in its state. A `plan` that returns `[]` makes a change a pure
	## cancel.
	##
	## Supersession is this site's explicit policy; `watch` and `watch_changes` never
	## cancel what they issued. Disposal follows `watch`: subscriptions and timers
	## stop, and admitted `Http` and `StorageGet` requests of the current value
	## are delivered to the nearest surviving ancestor. A change costs one read of
	## `v` plus work linear in the requests the site owns.
	watch_latest : Signal(ctx, a), (a -> List(Request)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch_latest = |v, plan, reaction| Core.watch_latest(v.v, plan, reaction)

	## `resource(input, cfg, body)` gives `body` a signal whose value follows
	## results of the requests issued for `input`. `Worker.resource` and
	## `Port.resource` follow one answer; use this form for another value,
	## such as a count of answers or a list built from several.
	##
	## At mount the value starts at `cfg.pending(cfg.init, a)` for the input's
	## value `a`, and `cfg.plan(a)` is issued. When `input` changes to an unequal
	## value, the site supersedes requests as `watch_latest` does, sets its value
	## to `cfg.pending(s, a)` and issues `cfg.plan(a)`, in one pass before `body`
	## reads the signal. The turn that changed the input therefore shows the
	## start of the new request, such as a loading state keeping the old answer.
	## Each result for a request the site owns sets the value to
	## `cfg.resolve(s, a, res)`, with the value `a` it was issued for.
	##
	## Readers of only this signal do no work when `pending` or `resolve`
	## returns a value equal to the previous one. To compare, the site holds
	## that previous value while they run, so they receive it shared: keep it
	## small, or build a fresh value rather than update a large one in place.
	## The value lives as long as the site's scope. Disposal drops it, stops
	## the site's scoped requests, and reparents admitted requests to the
	## nearest surviving ancestor, where writes to the retired state are
	## skipped and counted. Signals from outside enter `body` with `lift`.
	resource : Signal(ctx, a), { init : s, pending : (s, a -> s), plan : (a -> List(Request)), resolve : (s, a, Result -> s) }, (Signal(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
	resource = |input, cfg, body| Core.resource(input.v, cfg, |v| body({ v: v }))

	## What a resource that follows one answer holds (`Worker.resource`,
	## `Port.resource`): whether a request for the current input is in flight,
	## and the latest answer.
	##
	## - `request` is `Pending` from the turn the input changes until its
	##   answer arrives, and `Idle` otherwise.
	## - `answer` is `Unanswered` before the first answer, `Answered(output)`
	##   once there is one, or `Failed(error)` when a request produced none.
	##   A new input keeps the previous answer, so a view can go on showing it
	##   while the next one is wanted.
	##
	## `remote.answered()` reads the latest answer as a `Try`: `?? default`
	## shows a fallback, `.map_ok(f)` picks from it, and a handler matches
	## `Ok(output)`. It keeps the answer while a newer request is pending,
	## and is `Err(NoAnswer)` before the first answer and after a failure.
	Remote(output, error) : Core.Remote(output, error)

	## One job of a gathered question: `Working`, `Answered(output)` or
	## `Failed(error)`.
	JobState(output, error) : Core.JobState(output, error)

	## What a `gather` resource holds: `jobs`, the current question's jobs in
	## input order, each shown as it settles, and `all`, the whole list as a
	## [Remote]: `Pending` while any job works, `Answered(outputs)` in input
	## order once every job has answered, `Failed(error)` (the first in
	## input order) once none works and one failed, and the previous
	## question's answer meanwhile.
	Gathered(output, error) : Core.Gathered(output, error)

	## `gather(asker, inputs, body)` asks one request per input, all at
	## once, and gives `body` a signal gathering the answers (see
	## [Gathered]): a worker task's jobs over shards of one question, or a
	## port call per item. `asker` is anything with `request` and `result`
	## (`Worker.gather` is this for tasks). An empty list is answered at
	## once with `[]`.
	##
	## A new, unequal list stops every request of the old one and asks
	## again, as `resource` does; an equal list asks nothing. Each request
	## takes a slot of the in-flight bound, and one refused there is its
	## job's `Failed`, so split a question into no more parts than the bound
	## allows (32 by default). Disposal follows `resource`.
	gather : asker, Signal(ctx, List(input)), (Signal(In(ctx, Gathered(output, error)), Gathered(output, error)) -> Elem(In(ctx, Gathered(output, error)))) -> Elem(ctx)
		where [asker.request : asker, input -> Request, asker.result : asker, Result -> Try(output, error), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool, error.is_eq : error, error -> Bool]
	gather = |asker, inputs, body| Core.resource_at(inputs.v, Core.gather(asker), |v| body({ v: v }))

	## An outbox in the app's state: the latest thing a handler posted for
	## an `on_post` site to send. A handler posts with `box.post(item)`,
	## and a test reads the latest post with `box.last()` (`Unposted` or
	## `Posted(item)`). Two outboxes are equal only when they hold the same
	## post, so posting an item equal to the last one still sends it.
	##
	## Post at most once per turn to one outbox: a change that sends
	## several things posts a list (`Outbox(List(Note))`). A second post
	## in the same turn is a contract error, since the first would never
	## be sent.
	Outbox(a) : Core.Outbox(a)

	## An outbox with nothing posted, for an app's initial state.
	outbox : {} -> Outbox(a)
	outbox = |_| Core.outbox({})

	## `on_post(box, plan, reaction)` sends what a handler posts: in the turn a
	## handler posts `item` to the outbox `box`, it issues `plan(item)`,
	## and each result reaches `reaction` with the item it was posted with,
	## so several posts can be in flight and each answer knows its own.
	## Nothing is issued at mount, and nothing is ever cancelled for a
	## later post: like `watch_changes`, every request is kept, and disposal
	## follows `watch` (an HTTP request or a port call is delivered to the
	## nearest surviving ancestor).
	##
	## Use it for a request the user's action asks for: a save, an add, a
	## write to a store. The reducer that changes the state posts in the
	## same step, so an `expect` sees both.
	on_post : Signal(ctx, Outbox(a)), (a -> List(Request)), Reaction(ctx, a) -> Elem(ctx)
	on_post = |box, plan, reaction| Core.on_post(box.v, plan, reaction)

	## What the host knows before the first render: the URL, the declared storage
	## keys' values (missing keys are absent), whether the browser is online and
	## the page visible, and whether local storage is available at all. When it is
	## not, the storage list is empty and `StorageSet`/`StorageRemove` do not
	## persist, so an app that relies on reloads surviving can say so. All
	## fields have defaults: a URL of `/`, empty available storage, online
	## and visible. Pure tests may name only the facts they need.
	Boot : Core.Boot

	## The boot value of a declared storage key, or `Missing` if it has none.
	boot_storage : Boot, Str -> Try(Str, [Missing])
	boot_storage = |boot, key| Core.boot_storage(boot, key)

	## A signal that never changes. It reads no state or cell, so it triggers no refresh.
	const : a -> Signal(ctx, a)
	const = |value| { v: Core.const(value) }

	## `element(tag, attrs, children)`: an HTML element. `Html` offers typed
	## helpers for common elements and controls.
	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Core.element(tag, attrs, kids)

	## A static text node.
	text : Str -> Elem(ctx)
	text = |s| Core.text(s)

	## A text node whose content follows a value; the DOM is written only when
	## the text changes.
	text_s : Signal(ctx, Str) -> Elem(ctx)
	text_s = |{ v }| Core.text_s(v)

	## Set a static attribute to literal text, keeping an empty nonboolean
	## attribute present. Use a property builder for names a control claims.
	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Core.attr(name, value)

	## Follow a signal with an attribute, writing only when it changes. An
	## empty string keeps a nonboolean attribute present. Names claimed by
	## an element property are rejected on that property's elements; use
	## `prop_s` for live control state.
	attr_s : Str, Signal(ctx, Str) -> Attr(ctx)
	attr_s = |name, { v }| Core.attr_s(name, v)

	## Follow explicit presence, keeping `Present("")` as an empty nonboolean
	## attribute and removing the attribute for `Absent`. As with `attr_s`,
	## names claimed by a property must use that property's builder instead.
	attr_presence : Str, Signal(ctx, [Absent, Present(Str)]) -> Attr(ctx)
	attr_presence = |name, { v }| Core.attr_presence(name, v)

	## A static `class` attribute.
	class : Str -> Attr(ctx)
	class = |c| Core.class(c)

	## A `class` attribute that follows a value.
	class_s : Signal(ctx, Str) -> Attr(ctx)
	class_s = |{ v }| Core.class_s(v)

	## A static `data-testid` attribute, for spec locators.
	test_id : Str -> Attr(ctx)
	test_id = |id| Core.test_id(id)

	## A `data-testid` attribute that follows a value.
	test_id_s : Signal(ctx, Str) -> Attr(ctx)
	test_id_s = |{ v }| Core.test_id_s(v)

	## Listen for an event's text payload by its bare event name. Custom names
	## may contain a colon. Retired policy/file suffixes are a contract error
	## at mount; use `on_with` for policies and `on_files` for file handles.
	on : Str, Handler(ctx) -> Attr(ctx)
	on = |ev, { h }| Core.on(ev, h)

	## Browser policies fixed at declaration: prevention and stopping a
	## bubbling event before it reaches listeners outside the mount.
	Policy : Core.Policy

	## Listen for text with policies whose fields the compiler checks.
	## `prevent` prevents the default; `stop` keeps a bubbling event from
	## listeners outside this mount. On a non-bubbling event `stop` does nothing,
	## so the target's own browser listeners still run.
	on_with : Str, Policy, Handler(ctx) -> Attr(ctx)
	on_with = |event, policy, { h }| Core.on_with(event, policy, h)

	## A typed row of the platform's closed element-property vocabulary.
	Prop(a) :: { p : Core.Prop(a) }.{

		## Live text on an input, textarea, select or option, mirrored as its
		## value attribute. Text controls keep a focused or composing draft until
		## blur. Applying this row to a file input is a contract error.
		value : Prop(Str)
		value = { p: Core.Prop.value }

		## An input's checked state, set from a boolean and mirrored as its
		## checked attribute. Other elements cannot declare this property.
		checked : Prop(Bool)
		checked = { p: Core.Prop.checked }
	}

	## Set an element property from a row that fixes its value type. A property
	## on an unsupported element, a duplicate declaration, or an ordinary
	## attribute with a name the row claims is a contract error at mount.
	prop : Prop(a), a -> Attr(ctx)
	prop = |{ p }, value| Core.prop(p, value)

	## Follow a signal with a property, writing only when its value changes.
	prop_s : Prop(a), Signal(ctx, a) -> Attr(ctx)
	prop_s = |{ p }, { v }| Core.prop_s(p, v)

	## Name this element as a focus reference for `Focus`, `Blur` and `SelectText`
	## requests, so the app never handles engine node ids. Names are unique
	## among live elements and released with the element. An empty name names
	## nothing. Use `ref_s` when the name depends on a signal or row key.
	ref : Str -> Attr(ctx)
	ref = |name| Core.ref(name)

	## Name this element from a signal, including a row key. An empty name
	## registers nothing; two live elements with one name are a contract error
	## checked at the end of the turn. Changing a name emits no DOM command.
	ref_s : Signal(ctx, Str) -> Attr(ctx)
	ref_s = |{ v }| Core.ref_s(v)

	## A `click` listener; its payload is empty.
	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |{ h }| Core.on_click(h)

	## Receive handles from `Change` on a file input, `Drop` on a drop target,
	## or `Paste`. `Drop` prevents the browser's default for drop and dragover
	## on that target. An occurrence with no files runs no handler. Build the
	## handler with the same generic decisions and reducers as a text handler;
	## see `Html.file_input`.
	on_files : [Change, Drop, Paste], FilesHandler(ctx) -> Attr(ctx)
	on_files = |ev, { h }| Core.on_files(ev, h)

	## What the host drives: an app built with `program` or `program_boot`, bound
	## as the app's `main`. The platform mounts it with the boot data and runs one
	## turn per DOM event or effect result. `with_workers` adds the worker
	## tasks its `Work` requests may name:
	## `Engine.program(view).with_workers([count.registration()])` for a
	## `Worker.task`, and `with_ports` the ports the page's JavaScript supplies.
	Program : Core.Program

	## A worker task or preparation for `Program.with_workers`. Make one with
	## a typed task's or preparation's `registration` (see `Worker`).
	Registration : Core.Registration

	## The [Program] for an app that needs no boot data: mount `view()` with the
	## default in-flight bound of 32.
	program : (() -> Elem(Root)) -> Program
	program = |view| Core.program(view)

	## Declare values the app reads at boot. Every field has a default, so
	## callers name only what differs. Request catalogues instead use
	## `with_ports` and `with_workers` on the resulting program.
	ProgramProps : Core.ProgramProps

	## The [Program] for an app that reads boot data: the host reads
	## `storage_keys` from local storage before mount, and `view` receives them in
	## the [Boot] with the URL and connectivity. `max_inflight` bounds the awaited
	## requests in flight at once.
	program_boot : ProgramProps, (Boot -> Elem(Root)) -> Program
	program_boot = |cfg, view| Core.program_boot(cfg, view)

	## The [Program] for an app with a [Store]: as `program_boot`, with the
	## store `start` gives for the boot data held at the root, where every
	## context of `view` reaches its cells. `start` is usually the app's store
	## with the cells that depend on the boot data set (`Store.with_initial`).
	program_store : ProgramProps, (Boot -> Store(st, h)), (Boot -> Elem(StoreRoot(st))) -> Program
	program_store = |cfg, start, view| Core.program_store(cfg, |boot| start(boot).s.initial(), view)
}

## The cell the engine made, wrapped for the public API.
wrap_cell : Core.Cell(st, a) -> Engine.Cell(st, a)
wrap_cell = |c| { c: c }
