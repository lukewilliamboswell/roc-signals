import pf.Engine exposing [Elem, Handler, Signal, State, Table]
import pf.Html
import pf.Layout

## Table test app: a table of to-dos in the app's store, drawn as filtered,
## sorted windows of it, with specs in `specs/` that pin the work of every
## kind of change at 1,000 rows.
##
## - `todos` is a table cell: rows by a `U64` key. Every decision changes it
##   with the table's own operations, so each write records its rows.
## - `todos` and `next`, the key the next to-do takes, are one group, whose
##   generated reset starts both again: the table as a whole rewrite.
## - The main list is an `table_view` of it: the rows the listing keeps, in
##   the listing's order, a window of them drawn. The listing (which rows,
##   what order) and the window are cells, so buttons change them.
## - A second `table_view` shows the first five done rows by key, and a
##   third, mounted on request, the last five rows by key: three views of
##   one table.
## - A fourth, mounted on request, shows the few rows whose quantity is
##   below 10, every one of them drawn (`Engine.every_row`): a narrow view
##   of a large table.
## - A fifth, mounted on request, shows three of those few rows through a
##   window it keeps in a state of its own, and a sixth beside it the
##   first two of the three, through a `derive` of that window. Their
##   button moves the window and adds a row as one event: a cell and a
##   local state written together, which each view must meet together.
## - Two plain readers: the number of rows, and row 0's title.
## - `shadow` is a second table of the same size that nothing draws: a
##   write to it is the cost of a turn that touches a table and no view.
##
## The address chooses the size (`?n=1000&window=30&draws=main`, see
## `Setup`). To-do `i` starts with the quantity `i * 7919 % n` (every
## quantity once when `n` is not a multiple of 7919) and is done when `i`
## is odd, so the main list starts as the even keys in the order of their
## quantities.
TableApp := [Todos].{

	## One to-do. Its key is its row's key in the table, not a field.
	Todo : { title : Str, status : [Open, Done], qty : I64 }

	## What a list shows: which rows and in what order. Plain data, which a
	## view compares to know when to rebuild.
	Listing : { show : [All, Open, Done, Few], order : [ByQty, ByKey, ByKeyDown] }

	## The quantity below which a row is one of the few (`Few`): 10 of the
	## rows a table starts with, and every row "Add" adds.
	few_below : I64
	few_below = 10

	## Where a row stands in a listing's order: its order's number, then
	## its key, so that no two rows tie.
	Place : { primary : I64, key : U64 }

	## What the address chose. `draws` is `Everything`, or `Main` for the
	## main list alone (no second list, no readers), which is what a timing
	## of one view wants. `Changes` adds readers of the last writing turn's
	## changes and inverse for the lifecycle specs.
	Setup : { rows : U64, window : U64, draws : [Everything, Main, Changes] }

	## The setup an address names; 1,000 rows, a window of 30, everything
	## drawn, by default.
	setup_of : Str -> Setup
	setup_of = |url| {
		rows = U64.from_str(TableApp.asked(url, "n") ?? "1000") ?? 1000
		window = U64.from_str(TableApp.asked(url, "window") ?? "30") ?? 30
		draws = match TableApp.asked(url, "draws") ?? "everything" {
			"main" => Main
			"changes" => Changes
			_ => Everything
		}
		{ rows, window, draws }
	}

	## The value of `name` in the address's query.
	asked : Str, Str -> Try(Str, [NotInAddress])
	asked = |url, name| {
		before_hash = url.split_on("#").first() ?? ""
		query = before_hash.split_on("?").drop_first(1).first() ?? ""
		match query.split_on("&").find_first(|part| part.starts_with("${name}=")) {
			Ok(part) => Ok(part.drop_prefix("${name}="))
			Err(_) => Err(NotInAddress)
		}
	}

	## The to-dos a table of `count` rows starts with.
	sample : U64 -> List({ key : U64, row : Todo })
	sample = |count| {
		var $rows = List.with_capacity(count)
		var $key = 0.U64
		while $key < count {
			$rows = $rows.append({ key: $key, row: TableApp.todo_of($key, count) })
			$key = $key + 1
		}
		$rows
	}

	todo_of : U64, U64 -> Todo
	todo_of = |key, count| {
		title: "Task ${key.to_str()}",
		status: if (key % 2 == 1) Done else Open,
		qty: ((key * 7919) % count).to_i64_wrap(),
	}

	## How a listing selects and orders rows: the `plan` of every view.
	plan : Listing -> Engine.QueryPlan(U64, Todo, Place)
	plan = |{ show, order }| {
		keep: |_, todo| match show {
			All => True
			Open => todo.status == Open
			Done => todo.status == Done
			Few => todo.qty < TableApp.few_below
		},
		sort: |key, todo| match order {
			ByQty => { primary: todo.qty, key }
			ByKey => { primary: 0, key }
			ByKeyDown => { primary: 0 - key.to_i64_wrap(), key }
		},
		compare: TableApp.compare_place,
	}

	compare_place : Place, Place -> [Before, Same, After]
	compare_place = |a, b|
		if (a.primary < b.primary)
			Before
		else if (a.primary > b.primary)
			After
		else if (a.key < b.key)
			Before
		else if (a.key > b.key)
			After
		else
			Same

	raised : Todo, I64 -> Todo
	raised = |todo, by| { ..todo, qty: todo.qty + by }

	toggled : Todo -> Todo
	toggled = |todo| {
		..todo,
		status: match todo.status {
			Open => Done
			Done => Open
		},
	}

	## Raise the quantity of the first `count` keys by one, as `count`
	## keyed writes in one event. A fold over the keys rather than a `while`
	## loop over a `var` holding the table, which copies the table on every
	## iteration in optimised builds (roc-lang/roc#12971).
	edited : Table(U64, Todo), U64 -> Table(U64, Todo)
	edited = |table, count| {
		var $keys = List.with_capacity(count)
		var $key = 0.U64
		while $key < count {
			$keys = $keys.append($key)
			$key = $key + 1
		}
		$keys.fold(table, |acc, key| acc.update(key, |todo| TableApp.raised(todo, 1)))
	}

	## Mark the title of every row the `Few` listing keeps, as one keyed
	## write for each: the rows are found first, then written by a fold
	## over their keys (roc-lang/roc#12971).
	retitled : Table(U64, Todo) -> Table(U64, Todo)
	retitled = |table| {
		keys = table.fold([], |found, key, todo| if (todo.qty < TableApp.few_below) found.append(key) else found)
		keys.fold(table, |acc, key| acc.update(key, |todo| { ..todo, title: "${todo.title}!" }))
	}

	description = {
		items: {
			todos: Engine.table([]),
			next: Engine.cell(0.U64),
		}.Engine.Cells.with_reset(|cells, reset| { todos: cells.todos, next: cells.next, reset }),
		shadow: Engine.table([]),
		listing: Engine.cell({ show: Open, order: ByQty }),
		window: Engine.cell({ start: 0.U64, count: 30.U64 }),
		late: Engine.cell(Hidden),
		few: Engine.cell(Hidden),
		paged: Engine.cell(Hidden),
		scrolled: Engine.cell(Hidden),
		scroll_window: Engine.cell({ start: 0.U64, count: 5.U64 }),
		scroll_position: Engine.cell({ top: 0.U32, left: 0.U32, turns: 0.U64 }),
		scroll_loaded: Engine.cell(100.U64),
		scroll_request: Engine.cell(Engine.outbox({})),
		scroll_focus: Engine.cell(Engine.outbox({})),
		observed_rows: Engine.cell([]),
	}.Engine.Cells

	store = Engine.store(TableApp.Todos, TableApp.description)

	cells = TableApp.store.cells()

	## The store as a setup starts it: both tables at the setup's size.
	start : Setup -> Engine.Store(_, _)
	start = |setup| TableApp.store
		.with_initial(TableApp.cells.items.todos, Table.from_list(TableApp.sample(setup.rows)))
		.with_initial(TableApp.cells.shadow, Table.from_list(TableApp.sample(setup.rows)))
		.with_initial(TableApp.cells.items.next, setup.rows)
		.with_initial(TableApp.cells.window, { start: 0, count: setup.window })

	## Snapshots built outside the mounted store are ordinary values. Loading
	## any of them is a whole rewrite, even if its cleared history happens to
	## have the same write count as the live table.
	snapshot : Setup, [AfterInitial, Chain, OtherStore] -> Table(U64, Todo)
	snapshot = |setup, kind| {
		todos = TableApp.cells.items.todos
		match kind {
			AfterInitial => TableApp.start(setup)
				.after([todos.update(|table| table.remove(0))])
				.with_initial(TableApp.cells.items.next, setup.rows)
				.read(todos)
			Chain => TableApp.start(setup)
				.after([todos.update(|table| table.remove(0))])
				.after([todos.update(|table| table.put(setup.rows, { title: "Snapshot row", status: Open, qty: -1 }))])
				.read(todos)
			OtherStore => Engine.store(TableApp.Todos, TableApp.description)
				.with_initial(todos, Table.from_list(TableApp.sample(setup.rows).drop_if(|entry| entry.key == 0)))
				.read(todos)
		}
	}

	## What "Add" writes: a to-do under the key `key`, and the key after it
	## as the next one.
	added : U64 -> List(Engine.Write(_))
	added = |key| [
		TableApp.cells.items.todos.update(|table| table.insert(key, { title: "New ${key.to_str()}", status: Open, qty: 0 - key.to_i64_wrap() })),
		TableApp.cells.items.next.set(key + 1),
	]

	## What "Reset" writes: the table a setup starts with, as a new table
	## (`Table.from_list`), and the key after its last, so that the next
	## to-do added takes a key the table does not hold.
	restored : Setup -> List(Engine.Write(_))
	restored = |setup| [
		TableApp.cells.items.todos.set(Table.from_list(TableApp.sample(setup.rows))),
		TableApp.cells.items.next.set(setup.rows),
	]

	## What "Add above" writes: the same to-do, and the window moved down
	## by one. The new row has the lowest quantity, so in a list by quantity
	## it stands above the window, and the window holds the rows it held.
	added_above : U64 -> List(Engine.Write(_))
	added_above = |key| TableApp.added(key).append(TableApp.cells.window.update(|w| { ..w, start: w.start + 1 }))

	## A button named `name`, with no text of its own, so that a list's
	## text is its rows' keys and numbers alone.
	action : Signal(ctx, Str), Handler(ctx) -> Elem(ctx)
	action = |name, handler| Engine.element("button", [Html.aria_label_s(name), Engine.attr("type", "button"), Engine.on_click(handler)], [])

	## One row of the main list: its key, a done checkbox, its title, its
	## quantity with three ways to raise it, a remove button, and a count
	## of marks the row keeps in a state of its own. Its text is
	## `key:quantity:marks`.
	row : Signal(Engine.Row(ctx, U64), U64), State(Engine.Row(ctx, U64), Todo) -> Elem(Engine.Row(ctx, U64))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	row = |key, todo| {
		named = |what| key.map(|k| "${what} ${k.to_str()}")
		raise = |by| todo.update(|t| TableApp.raised(t, by))
		Html.li(
			[],
			[
				Html.span_s(key.map(|k| "${k.to_str()}:"), []),
				Html.checkbox(named("Done"), todo.signal().map(|t| t.status == Done), [], todo.set_value(|t, checked| { ..t, status: if (checked == "true") Done else Open })),
				Html.text_input(named("Title"), "text", todo.signal().map(|t| t.title), [], todo.set_value(|t, title| { ..t, title })),
				Html.span_s(todo.signal().map(|t| t.qty.to_str()), [Html.aria_label_s(named("Qty"))]),
				TableApp.action(named("Bump"), raise(1)),
				TableApp.action(named("Later"), raise(25)),
				TableApp.action(named("Last"), raise(1_000_000)),
				TableApp.action(named("Remove"), Engine.handle_by(key, |k, _| [TableApp.cells.items.todos.update(|table| table.remove(k))])),
				Engine.state(
					0.U64,
					|marks| Engine.element(
						"span",
						[],
						[
							Engine.text(":"),
							Html.span_s(marks.signal().map(|count| count.to_str()), [Html.aria_label_s(named("Marks").lift())]),
							TableApp.action(named("Mark").lift(), marks.update(|count| count + 1)),
							Engine.text(" "),
						],
					),
				),
			],
		)
	}

	## One row of the smaller lists: its key and its title.
	line : Signal(r, U64), State(r, Todo) -> Elem(r)
	line = |key, todo| Html.li([], [Html.span_s(key.map2(todo.signal(), |k, t| "${k.to_str()}=${t.title} "), [])])

	## A list of `todos` named `name`: the window `window` of `listing`.
	list : Str, Signal(ctx, Listing), Signal(ctx, Engine.Window), (Signal(Engine.Row(ctx, U64), U64), State(Engine.Row(ctx, U64), Todo) -> Elem(Engine.Row(ctx, U64))) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	list = |name, listing, window, template| Html.ul(
		[Engine.test_id(name)],
		[Engine.table_view(TableApp.cells.items.todos, { query: listing, plan: TableApp.plan, window }, template)],
	)

	## One scroll writes its window and its diagnostic reading together.
	scrolled_to : Layout.Scroll -> List(Engine.Write(_))
	scrolled_to = |position| [
		TableApp.cells.scroll_window.set({ start: position.top.to_u64() // 20, count: 5 }),
		TableApp.cells.scroll_position.update(|before| { top: position.top, left: position.left, turns: before.turns + 1 }),
	]

	## Showing the scroller starts its drawn window at its native start edge.
	show_scrolled : {} -> List(Engine.Write(_))
	show_scrolled = |_args| [
		TableApp.cells.scrolled.set(Shown),
		TableApp.cells.scroll_window.set({ start: 0, count: 5 }),
		TableApp.cells.scroll_position.set({ top: 0, left: 0, turns: 0 }),
	]

	## The button moves the window and posts its matching native scroll in
	## one event; the browser's report then enters as an ordinary turn.
	jump_scrolled : {} -> List(Engine.Write(_))
	jump_scrolled = |_args| [
		TableApp.cells.scroll_window.set({ start: 6, count: 5 }),
		TableApp.cells.scroll_request.update(|box| box.post(120.U32)),
	]

	## Fixed-height virtualization: the spacer follows loaded row count,
	## never the drawn window, and anchoring cannot move the scrollbar.
	scrolled_list : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	scrolled_list = |_args| Html.section(
		"Scrolled list",
		"",
		[
			Engine.element("style", [], [Engine.text(".table-scrolled-panel { position:fixed; right:0; top:0; width:320px; background:white; border:1px solid black; z-index:1 } .table-scrolled-rows { margin:0; padding:0; list-style:none }")]),
			Html.p_s(TableApp.cells.scroll_position.signal().map(|position| "${position.top.to_str()}:${position.left.to_str()}:${position.turns.to_str()}"), [Engine.test_id("scrolled-status")]),
			Html.button("Jump scrolled list", [], Engine.does(TableApp.jump_scrolled({}))),
			Html.button("Hide scrolled list", [], Engine.does([TableApp.cells.scrolled.set(Hidden)])),
			Html.button("Focus distant scrolled control", [], Engine.does([TableApp.cells.scroll_focus.update(|box| box.post("scrolled-distant"))])),
			Engine.element(
				"div",
				[
					Html.aria_label("Scrolled todos"),
					Engine.ref("scrolled-todos"),
					Engine.attr("style", "height:100px;width:280px;overflow:auto;overflow-anchor:none;position:relative"),
					Html.on_scroll(Engine.handle(TableApp.scrolled_to)),
				],
				[
					Engine.element(
						"div",
						[Engine.attr_s("style", TableApp.cells.scroll_loaded.signal().map(|count| "height:${(count * 20).to_str()}px;position:relative"))],
						[
							Engine.element(
								"ul",
								[Engine.class("table-scrolled-rows"), Engine.test_id("scrolled"), Engine.attr_s("style", TableApp.cells.scroll_window.signal().map(|window| "position:absolute;top:${(window.start * 20).to_str()}px;left:0;width:100%"))],
								[
									Engine.table_view(
										TableApp.cells.items.todos,
										{
											query: TableApp.cells.scroll_loaded.signal(),
											plan: |loaded| { keep: |key, _| key < loaded, sort: |key, _| key, compare: |left, right| if (left < right) Before else if (left > right) After else Same },
											window: TableApp.cells.scroll_window.signal(),
										},
										|key, todo| Html.li([Engine.attr("style", "height:20px;line-height:20px;box-sizing:border-box")], [Html.span_s(key.map2(todo.signal(), |number, todo_row| "${number.to_str()}=${todo_row.title} "), [])]),
									),
								],
							),
							Engine.element("button", [Html.aria_label("Distant scrolled control"), Engine.attr("type", "button"), Engine.ref("scrolled-distant"), Engine.attr("style", "position:absolute;top:400px;left:0")], [Engine.text("Distant")]),
							Engine.element("div", [Html.aria_label("Load more scrolled"), Engine.attr("style", "position:absolute;bottom:0;height:1px;width:1px"), Html.on_seen({ ahead: True }, Engine.handle(|seen| if (seen.intersecting) [TableApp.cells.scroll_loaded.update(|loaded| loaded + 100)] else []))], []),
						],
					),
				],
			),
			Engine.on_post(TableApp.cells.scroll_request.signal(), |top| [Engine.command(ScrollTo("scrolled-todos", { top: Px(top), left: Keep, behavior: Instant }))], Engine.ignore({})),
			Engine.on_post(TableApp.cells.scroll_focus.signal(), |name| [Engine.command(Focus(name))], Engine.ignore({})),
		],
	)

	## Nested sites under rows must release observations before either a row
	## REMOVE or its site's CLEAR. Each row observes both its template root
	## and an element inside a state scope.
	observed_list : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	observed_list = |_args| Engine.element(
		"div",
		[Engine.test_id("observed-rows")],
		[
			Engine.each(
				TableApp.cells.observed_rows.signal(),
				|key| key.to_str(),
				|accessor| Engine.element(
					"section",
					[Html.aria_label_s(accessor.key().map(|key| "Observed row ${key}")), Html.on_seen({}, Engine.does([])), Html.on_size(Engine.does([]))],
					[Engine.state(0.U32, |size| Engine.element("div", [Html.aria_label_s(accessor.key().lift().map(|key| "Observed size ${key}")), Html.on_size(size.set_value(|_before, box| box.height))], [Html.span_s(size.signal().map(|height| height.to_str()), [])]))],
				),
			),
		],
	)

	toolbar : Setup -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	toolbar = |setup| {
		todos = TableApp.cells.items.todos
		listing = TableApp.cells.listing
		window = TableApp.cells.window
		page = setup.window
		edit = |count| Engine.handle(|_| [todos.update(|table| TableApp.edited(table, count))])
		show = |which| Engine.handle(|_| [listing.update(|l| { ..l, show: which })])
		order = |by| Engine.handle(|_| [listing.update(|l| { ..l, order: by })])
		scroll = |to| Engine.handle(|_| [window.update(|w| { ..w, start: to(w.start) })])
		Html.div(
			"toolbar",
			[
				Html.button("Add", [], Engine.handle_by(TableApp.cells.items.next.signal(), |key, _| TableApp.added(key))),
				Html.button("Add above", [], Engine.handle_by(TableApp.cells.items.next.signal(), |key, _| TableApp.added_above(key))),
				Html.button("Edit 20", [], edit(20)),
				Html.button("Edit 100", [], edit(100)),
				Html.button("Edit 1000", [], edit(1000)),
				Html.button("Toggle all", [], Engine.handle(|_| [todos.update(|table| table.update_all(|_, todo| TableApp.toggled(todo)))])),
				Html.button("Reset", [], Engine.handle(|_| TableApp.restored(setup))),
				Html.button("Load Store snapshot", [], Engine.handle(|_| [todos.set(TableApp.snapshot(setup, AfterInitial))])),
				Html.button("Load Store chain", [], Engine.handle(|_| [todos.set(TableApp.snapshot(setup, Chain))])),
				Html.button("Load second Store", [], Engine.handle(|_| [todos.set(TableApp.snapshot(setup, OtherStore))])),
				Html.button("Touch next", [], Engine.does([TableApp.cells.items.next.update(|next| next + 1)])),
				Html.button("Write twice", [], Engine.does([todos.update(|table| table.update(0, |todo| TableApp.raised(todo, 1))), todos.update(|table| table.update(2, |todo| TableApp.raised(todo, 1)))])),
				Html.button("Write with also", [], Engine.does([todos.update(|table| table.update(0, |todo| TableApp.raised(todo, 1)))]).also(Engine.does([todos.update(|table| table.update(2, |todo| TableApp.raised(todo, 1)))]))),
				Html.button("Keep table", [], Engine.does([todos.update(|table| table)])),
				Html.button(
					"Undo previous",
					[],
					Engine.handle_by(
						todos.signal(),
						|table, _| match table.inverse() {
							Ok(inverse) => [todos.update(|held| held.apply(inverse))]
							Err(Rewritten) => []
						},
					),
				),
				Html.button("Reset with also", [], Engine.does([TableApp.cells.items.reset]).also(Engine.does([todos.update(|table| table.insert(3, { title: "After reset", status: Open, qty: -1 }))]))),
				Html.button("Start again", [], Engine.handle(|_| [TableApp.cells.items.reset])),
				Html.button("Show open", [], show(Open)),
				Html.button("Show all", [], show(All)),
				Html.button("Show done", [], show(Done)),
				Html.button("By qty", [], order(ByQty)),
				Html.button("By key", [], order(ByKey)),
				Html.button("Down 1", [], scroll(|at| at + 1)),
				Html.button("Up 1", [], scroll(|at| if (at > 0) at - 1 else 0)),
				Html.button("Down page", [], scroll(|at| at + page)),
				Html.button("Up page", [], scroll(|at| if (at > page) at - page else 0)),
				Html.button("Show late list", [], Engine.handle(|_| [TableApp.cells.late.set(Shown)])),
				Html.button("Hide late list", [], Engine.handle(|_| [TableApp.cells.late.set(Hidden)])),
				Html.button("Touch shadow", [], Engine.handle(|_| [TableApp.cells.shadow.update(|table| table.update(0, |todo| TableApp.raised(todo, 1)))])),
				Html.button("Show few list", [], Engine.does([TableApp.cells.few.set(Shown)])),
				Html.button("Retitle few", [], Engine.does([todos.update(TableApp.retitled)])),
				Html.button("Show paged list", [], Engine.does([TableApp.cells.paged.set(Shown)])),
				Html.button("Show scrolled list", [], Engine.does(TableApp.show_scrolled({}))),
				Html.button("Show observed rows", [], Engine.does([TableApp.cells.observed_rows.set([1.U64, 2, 3])])),
				Html.button("Remove observed row", [], Engine.does([TableApp.cells.observed_rows.update(|rows| rows.drop_first(1))])),
				Html.button("Clear observed rows", [], Engine.does([TableApp.cells.observed_rows.set([])])),
			],
		)
	}

	## Three of the few rows, from the second: a list whose window is a
	## state of its own, and beside it the first two of those rows, in a
	## list whose window is a `derive` of that state. "Add and page down"
	## moves the window down by one, a local write, and adds a to-do, a
	## decision, as one event. The new row has the lowest quantity and
	## stands above the window, so each window holds the rows it held.
	paged : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	paged = |{}| Engine.state(
		{ start: 1.U64, count: 3.U64 },
		|window| Html.div(
			"paged",
			[
				Html.button(
					"Add and page down",
					[],
					window.update(|w| { ..w, start: w.start + 1 }).also(Engine.handle_by(TableApp.cells.items.next.signal(), |key, _| TableApp.added(key))),
				),
				TableApp.list("paged", Engine.const({ show: Few, order: ByQty }), window.signal(), TableApp.line),
				Engine.derive(
					window.signal().map(|w| { start: w.start, count: 2 }),
					|narrow| TableApp.list("narrow", Engine.const({ show: Few, order: ByQty }), narrow, TableApp.line),
				),
			],
		),
	)

	## What the app draws beside its main list: the two readers and the
	## smaller lists.
	extras : {} -> List(Elem(ctx))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	extras = |{}| {
		todos = TableApp.cells.items.todos
		[
			Html.p_s(todos.signal().map(|table| "Rows: ${table.len().to_str()}"), [Engine.test_id("count")]),
			Html.p_s(
				todos.signal().map(
					|table| match table.get(0) {
						Ok(todo) => "Row 0: ${todo.title}"
						Err(Missing) => "Row 0: gone"
					},
				),
				[Engine.test_id("row0")],
			),
			TableApp.list("done", Engine.const({ show: Done, order: ByKey }), Engine.const({ start: 0, count: 5 }), TableApp.line),
			Engine.when(
				TableApp.cells.late.signal().map(
					|late| match late {
						Shown => True
						Hidden => False
					},
				),
				|| TableApp.list("late", Engine.const({ show: All, order: ByKeyDown }), Engine.const({ start: 0, count: 5 }), TableApp.line),
				|| Engine.text(""),
			),
			Engine.when(
				TableApp.cells.few.signal().map(
					|few| match few {
						Shown => True
						Hidden => False
					},
				),
				|| TableApp.list("few", Engine.const({ show: Few, order: ByQty }), Engine.const(Engine.every_row), TableApp.line),
				|| Engine.text(""),
			),
			Engine.when(
				TableApp.cells.paged.signal().map(
					|drawn| match drawn {
						Shown => True
						Hidden => False
					},
				),
				|| TableApp.paged({}),
				|| Engine.text(""),
			),
			Engine.when(TableApp.cells.scrolled.signal().map(|state| state == Shown), || Engine.element("div", [Engine.class("table-scrolled-panel")], [TableApp.scrolled_list({})]), || Engine.text("")),
			TableApp.observed_list({}),
		]
	}

	view : Setup -> Elem(Engine.StoreRoot(_))
	view = |setup| Html.div(
		"app",
		[
			TableApp.toolbar(setup),
			TableApp.list("main", TableApp.cells.listing.signal(), TableApp.cells.window.signal(), TableApp.row),
		].concat(
			match setup.draws {
				Everything => TableApp.extras({})
				Changes => TableApp.extras({}).concat([
					Html.p_s(
						TableApp.cells.items.todos.signal().map(
							|table| match table.changes() {
								Keyed(changes) => "Changed: ${changes.len().to_str()}"
								Rewritten => "Rewritten"
							},
						),
						[Engine.test_id("changes")],
					),
					Html.p_s(
						TableApp.cells.items.todos.signal().map(
							|table| match table.inverse() {
								Ok(inverse) => "Inverse: ${inverse.len().to_str()}"
								Err(Rewritten) => "No inverse"
							},
						),
						[Engine.test_id("inverse")],
					),
					Html.p_s(TableApp.cells.items.next.signal().map(|next| "Next: ${next.to_str()}"), [Engine.test_id("next")]),
				])
				Main => []
			},
		),
	)

	program : Engine.Program
	program = Engine.program_store(
		{ storage_keys: [], max_inflight: 8 },
		|boot| TableApp.start(TableApp.setup_of(boot.url)),
		|boot| TableApp.view(TableApp.setup_of(boot.url)),
	)
}

## Adding a to-do writes its row and the next key as one decision.
expect {
	after = TableApp.start({ rows: 3, window: 30, draws: Everything }).after(TableApp.added(3))
	titles = [0, 3].map(|key| after.read(TableApp.cells.items.todos).get(key).map_ok(|todo| todo.title))
	(titles, after.read(TableApp.cells.items.next)) == ([Ok("Task 0"), Ok("New 3")], 4)
}

## After the group's reset, "Reset" puts back the rows and the key that
## follows them, so "Add" then adds a row under a new key.
expect {
	setup = { rows: 3, window: 30, draws: Everything }
	after = TableApp.start(setup).after([TableApp.cells.items.reset]).after(TableApp.restored(setup))
	added = after.after(TableApp.added(after.read(TableApp.cells.items.next)))
	(after.read(TableApp.cells.items.next), added.read(TableApp.cells.items.todos).len()) == (3, 4)
}

## "Add above" is the same row and next key, with the window one row down.
expect {
	started = TableApp.start({ rows: 3, window: 2, draws: Everything })
	after = started.after(TableApp.added_above(3))
	(after.read(TableApp.cells.items.todos).contains(3), after.read(TableApp.cells.items.next), after.read(TableApp.cells.window)) == (Bool.True, 4, { start: 1, count: 2 })
}

## "Retitle few" writes the few rows and no other: the table's changes
## name exactly the rows whose quantity is below 10.
expect {
	started = TableApp.start({ rows: 1000, window: 30, draws: Everything })
	todos = started.after([TableApp.cells.items.todos.update(TableApp.retitled)]).read(TableApp.cells.items.todos)
	written = match todos.inverse() {
		Ok(writes) => writes.len()
		Err(Rewritten) => 0
	}
	(written, todos.get(0).map_ok(|todo| todo.title), todos.get(1).map_ok(|todo| todo.title)) == (10, Ok("Task 0!"), Ok("Task 1"))
}

## The group's reset starts the table again as a whole rewrite, at the rows
## it was described with, and a row written after it in the same list is
## kept.
expect {
	items = TableApp.cells.items
	started = TableApp.start({ rows: 3, window: 30, draws: Everything })
	again = started.after([items.reset])
	refined = started.after([items.reset, items.todos.update(|table| table.insert(7, { title: "Seven", status: Open, qty: 0 }))])
	rewritten = |store| match store.read(items.todos).changes() {
		Rewritten => "rewritten"
		Keyed(_) => "keyed"
	}
	actual =
		\\rows: ${started.read(items.todos).len().to_str()}, ${again.read(items.todos).len().to_str()}, ${refined.read(items.todos).len().to_str()}
		\\next: ${started.read(items.next).to_str()}, ${again.read(items.next).to_str()}
		\\changes: ${rewritten(again)}, ${rewritten(refined)}
	expected =
		\\rows: 3, 0, 1
		\\next: 3, 0
		\\changes: rewritten, rewritten
	actual == expected
}

## Snapshot helpers preserve the pure Store path: with_initial clears its
## changes, while chained after calls retain only the latest writing turn.
expect {
	setup = { rows: 3, window: 30, draws: Everything }
	cleared = TableApp.snapshot(setup, AfterInitial)
	chained = TableApp.snapshot(setup, Chain)
	actual = {
		cleared_rows: cleared.len(),
		cleared_changes: match cleared.changes() {
			Keyed(changes) => changes.len()
			Rewritten => 99
		},
		chain_rows: chained.len(),
		chain_keys: match chained.changes() {
			Keyed(changes) => changes.keys().sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)
			Rewritten => []
		},
		chain_title: chained.get(3)?.title,
	}
	actual == { cleared_rows: 2, cleared_changes: 0, chain_rows: 3, chain_keys: [3], chain_title: "Snapshot row" }
}
