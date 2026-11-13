# region imports
import pf.Engine exposing [Elem, Signal, State, Table]
import pf.Html
# endregion imports

## The tutorial's to-do list: a table of to-dos and two cells in the app's
## store, one decision for adding, a view of the table, and a storage
## effect.
# region module
Todos := [TodoList].{
	# endregion module
	# region store
	Todo : { title : Str, status : [Open, Done] }

	## The app's store. Its to-dos are a table: rows by key, here a number
	## the app hands out. `next` is the key the next to-do takes, and
	## `draft` the title being typed.
	store = Engine.store(
		Todos.TodoList,
		{
			todos: Engine.table([]),
			next: Engine.cell(0.U64),
			draft: Engine.cell(""),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = Todos.store.cells()
	# endregion store

	# region add
	## What the form reads when it is submitted: the title typed, whether
	## the list has it already, and the key the next to-do takes.
	Adding : { title : Str, listed : [Listed, Unlisted], next : U64 }

	## The form's reading: three cells read together, and mapped to the
	## three small things the decision needs.
	adding : {} -> Signal(ctx, Adding)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	adding = |{}|
		{
			draft: Todos.cells.draft.signal(),
			table: Todos.cells.todos.signal(),
			next: Todos.cells.next.signal(),
		}.Signal.map(|{ draft, table, next }| { title: draft.trim(), listed: Todos.presence(table, draft.trim()), next })

	## Whether `table` has a to-do called `title`.
	presence : Table(U64, Todo), Str -> [Listed, Unlisted]
	presence = |table, title| table.fold(Unlisted, |found, _, todo| if (todo.title == title) Listed else found)

	## What submitting the form writes. A blank title, or one the list has
	## already, writes nothing. Any other writes the new row, the key after
	## it and an empty draft, together.
	added : Adding -> List(Engine.Write(_))
	added = |{ title, listed, next }|
		if title.is_empty() or listed == Listed {
			[]
		} else {
			[
				Todos.cells.todos.update(|table| table.insert(next, { title, status: Open })),
				Todos.cells.next.set(next + 1),
				Todos.cells.draft.set(""),
			]
		}
	# endregion add

	# region plan
	## Which to-dos the list shows.
	Showing : [All, Open, Done]

	## How a choice of `Showing` selects and orders rows: the rows it
	## keeps, in the order they were added, which is the order of their
	## keys.
	plan : Showing -> Engine.QueryPlan(U64, Todo, U64)
	plan = |showing| {
		keep: |_, todo| match showing {
			All => True
			Open => todo.status == Open
			Done => todo.status == Done
		},
		sort: |key, _| key,
		compare: by_key,
	}
	# endregion plan

	# region list
	## The list: three buttons that choose what it shows, and a view of the
	## table. The choice is the list's own state, since nothing else in the
	## app reads it.
	list : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	list = |{}|
		Engine.state(
			All,
			|showing| Html.div(
				"list",
				[
					Html.button("Show all", [], showing.update(|_| All)),
					Html.button("Show open", [], showing.update(|_| Open)),
					Html.button("Show done", [], showing.update(|_| Done)),
					Html.ul(
						[],
						[
							Engine.table_view(
								Todos.cells.todos,
								{ query: showing.signal(), plan: Todos.plan, window: Engine.const(Engine.every_row) },
								|key, todo| Todos.row(key, todo),
							),
						],
					),
				],
			),
		)
	# endregion list

	# region row
	## One row. `todo` is a `State` of this row of the table: the checkbox
	## reads and writes this to-do and no other. Removing a row changes the
	## table itself, so it is a decision over the table's cell.
	row : Signal(r, U64), State(r, Todo) -> Elem(r)
		where [r.store : () -> Engine.Reach(r, _)]
	row = |key, todo| {
		title = todo.signal().map(|held| held.title)
		Html.li(
			[],
			[
				Html.checkbox(
					title.map(|text| "Done: ${text}"),
					todo.signal().map(|held| held.status == Done),
					[],
					todo.set_value(|held, checked| { ..held, status: if (checked == "true") Done else Open }),
				),
				Engine.text_s(title),
				Html.icon_button(
					"x",
					title.map(|text| "Remove ${text}"),
					"remove",
					Engine.handle_by(key, |id, _| [Todos.cells.todos.update(|table| table.remove(id))]),
				),
			],
		)
	}
	# endregion row

	# region view
	## The page: the form, the list, a note while there is nothing to do,
	## the count of open to-dos, and the effect that saves the list.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		todos = Todos.cells.todos.signal()
		Html.div(
			"todos",
			[
				Html.form(
					"New todo",
					[Html.on_submit(Engine.handle_by(Todos.adding({}), |at, _| Todos.added(at)))],
					[
						Html.text_input(Engine.const("Title"), "text", Todos.cells.draft.signal(), [], Engine.handle(|typed| [Todos.cells.draft.set(typed)])),
						Html.submit_button("Add", []),
					],
				),
				Todos.list({}),
				Engine.when(todos.map(|table| table.len() == 0), || Html.p("Nothing to do.", "empty"), || Engine.text("")),
				Html.span_s(todos.map(Todos.remaining), [Engine.test_id("remaining")]),
				# region persist
				Engine.watch_changes(todos.map(Todos.encode), |text| [Engine.command(StorageSet("todos", text))], Engine.ignore({})),
				# endregion persist
			],
		)
	}
	# endregion view

	## How many to-dos are still open, as the page says it.
	remaining : Table(U64, Todo) -> Str
	remaining = |table|
		match table.fold(0.U64, |count, _, todo| if (todo.status == Open) count + 1 else count) {
			1 => "1 item left"
			count => "${count.to_str()} items left"
		}

	# region storage
	## The saved list: one to-do per line in the order they were added, `+`
	## for done and `-` for open.
	encode : Table(U64, Todo) -> Str
	encode = |table| {
		rows = table.fold([], |found, key, todo| found.append({ key, todo })).sort_with(|a, b| by_key(a.key, b.key))
		Str.join_with(rows.map(|{ todo, .. }| "${if (todo.status == Done) "+" else "-"}${todo.title}"), "\n")
	}

	## The to-dos a saved text holds, in its order. A line that starts with
	## neither sign is skipped.
	decode : Str -> List(Todo)
	decode = |text|
		text.split_on("\n").keep_oks(
			|line|
				if line.starts_with("+") {
					Ok({ title: line.drop_prefix("+"), status: Done })
				} else if line.starts_with("-") {
					Ok({ title: line.drop_prefix("-"), status: Open })
				} else {
					Err(Blank)
				},
		)

	## The store a visit starts with: the saved to-dos under the keys 0, 1,
	## 2 and so on, and the key after the last as the next.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| {
		saved = Todos.decode(Engine.boot_storage(boot, "todos") ?? "")
		rows = saved.map_with_index(|todo, index| { key: index, row: todo })
		Todos.store
			.with_initial(Todos.cells.todos, Table.from_list(rows))
			.with_initial(Todos.cells.next, saved.len())
	}

	program : Engine.Program
	program = Engine.program_store({ storage_keys: ["todos"], max_inflight: 32 }, Todos.start, |_boot| Todos.view({}))
	# endregion storage
}

## The order of two keys: the smaller first.
by_key : U64, U64 -> [Before, Same, After]
by_key = |a, b|
	if a < b {
		Before
	} else if a > b {
		After
	} else {
		Same
	}

# region expects
## A new title is added under the next key, and the next key and the draft
## move on with it.
expect {
	typed = Todos.store.after([Todos.cells.draft.set("Buy milk")])
	after = typed.after(Todos.added({ title: "Buy milk", listed: Unlisted, next: 0 }))

	actual =
		\\row 0: ${Str.inspect(after.read(Todos.cells.todos).get(0))}
		\\next: ${after.read(Todos.cells.next).to_str()}
		\\draft: "${after.read(Todos.cells.draft)}"
	expected =
		\\row 0: Ok({ status: Open, title: "Buy milk" })
		\\next: 1
		\\draft: ""
	actual == expected
}

## A blank title and a title already on the list write nothing.
expect {
	blank = Todos.added({ title: "", listed: Unlisted, next: 3 })
	again = Todos.added({ title: "Buy milk", listed: Listed, next: 3 })
	blank.is_empty() and again.is_empty()
}
# endregion expects

# region storage-expect
## The saved text reads back as the same to-dos, in the order they were added.
expect {
	todos = [{ title: "Water the plants", status: Open }, { title: "Buy milk", status: Done }]
	table = Table.from_list(todos.map_with_index(|todo, index| { key: index, row: todo }))
	Todos.encode(table) == "-Water the plants\n+Buy milk" and Todos.decode(Todos.encode(table)) == todos
}
# endregion storage-expect
