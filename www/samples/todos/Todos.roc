# region imports
import pf.Engine exposing [Elem, In, Root, Row, RowRef, State]
import pf.Html
# endregion imports

## The tutorial's todo list: one state, a keyed list, a conditional and a
## storage effect.
Todos := [].{
	# region model
	Todo : { title : Str, done : Bool }

	Model : { items : List(Todo), draft : Str }

	## The context inside the model's state, and inside one row of the list.
	Ctx : In(Root, Model)
	Item : Row(Ctx, Todo)
	# endregion model

	# region reducers
	## Add the draft as a new todo. A blank draft or a title already on the
	## list changes nothing: titles are the rows' keys, and keys are unique.
	add : Model -> Model
	add = |model| {
		title = model.draft.trim()
		if title.is_empty() or model.items.any(|t| t.title == title) {
			model
		} else {
			{ items: model.items.append({ title, done: False }), draft: "" }
		}
	}

	toggle : Model, Str -> Model
	toggle = |model, title| { ..model, items: model.items.map(|t| if (t.title == title) { ..t, done: !t.done } else t) }

	remove : Model, Str -> Model
	remove = |model, title| { ..model, items: model.items.drop_if(|t| t.title == title) }

	remaining : List(Todo) -> Str
	remaining = |items|
		match items.count_if(|t| !t.done) {
			1 => "1 item left"
			n => "${n.to_str()} items left"
		}
	# endregion reducers

	# region storage
	## The saved list: one todo per line, `+` for done and `-` for open.
	encode : List(Todo) -> Str
	encode = |items| Str.join_with(items.map(|t| "${if (t.done) "+" else "-"}${t.title}"), "\n")

	decode : Str -> List(Todo)
	decode = |text|
		text.split_on("\n").keep_oks(
			|line|
				if line.starts_with("+") {
					Ok({ title: line.drop_prefix("+"), done: True })
				} else if line.starts_with("-") {
					Ok({ title: line.drop_prefix("-"), done: False })
				} else {
					Err(Blank)
				},
		)

	program : Engine.Program(Engine.App)
	program = Engine.program_boot(
		{ storage_keys: ["todos"], max_inflight: 32 },
		|boot| {
			saved = Engine.boot_storage(boot, "todos") ?? ""
			Engine.state({ items: Todos.decode(saved), draft: "" }, Todos.view)
		},
	)
	# endregion storage

	# region view
	view : State(Ctx, Model) -> Elem(Ctx)
	view = |model| {
		items = model.val().map(|m| m.items)
		Html.div(
			"todos",
			[
				Html.form(
					"New todo",
					[Html.on_submit(model.update(Todos.add))],
					[
						Html.text_input(Engine.const("Title"), "text", model.val().map(|m| m.draft), [], model.set_value(|m, v| { ..m, draft: v })),
						Html.submit_button("Add", []),
					],
				),
				Html.ul([], [Engine.each(items, |t| t.title, |row| Todos.row(model, row))]),
				Engine.when(items.map(|l| l.is_empty()), || Html.p("Nothing to do.", "empty"), || Engine.text("")),
				Html.span_v(items.map(Todos.remaining), [Engine.test_id("remaining")]),
				# region persist
				Engine.on_change(items, |l| [StorageSet("todos", Todos.encode(l))], Engine.ignore({})),
				# endregion persist
			],
		)
	}
	# endregion view

	# region row
	## One row. The template runs once for the whole list; `row` reads the
	## current row's key and item when a hole is evaluated or a handler fires.
	row : State(Ctx, Model), RowRef(Ctx, Todo) -> Elem(Item)
	row = |model0, row|
		{
			model = model0.lift_row()
			title = row.key()
			Html.li(
				[],
				[
					Html.checkbox(title.map(|t| "Done: ${t}"), row.field(|t| t.done), [], model.update_by(title, Todos.toggle)),
					Engine.text_v(title),
					Html.icon_button("x", title.map(|t| "Remove ${t}"), "remove", model.update_by(title, Todos.remove)),
				],
			)
		}
	# endregion row
}
