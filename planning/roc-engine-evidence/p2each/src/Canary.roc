import Engine exposing [Elem, Root, In]
import TaskRow

## The 0b canary app on the unified engine (ported from p1b/api/Canary.roc).
## Differences: `Row` replaces `Site` as the row context name; the toggle
## handler flips `done` through `update_by` (1b's `update_bool_by` always
## passed True); a "Select" button per row exercises the keyed selector inside
## a dynamic row.
Canary := [].{
	Task : { id : Str, title : Str, done : Bool }

	Model : { tasks : List(Task), selected : Str }

	Ctx : In(Root, Model)

	initial : Model
	initial = {
		tasks: [{ id: "a", title: "Write the canary", done: Bool.False }, { id: "b", title: "Check it", done: Bool.True }],
		selected: "",
	}

	remove_task : Model, Str -> Model
	remove_task = |model, id| {
		{ tasks, selected } = model
		{ tasks: tasks.keep_if(|t| t.id != id), selected }
	}

	toggle_task : Model, Str -> Model
	toggle_task = |model, id| {
		{ tasks, selected } = model
		{ tasks: tasks.map(|t| if t.id == id { id: t.id, title: t.title, done: !t.done } else t), selected }
	}

	select_task : Model, Str -> Model
	select_task = |model, id| {
		{ tasks, selected: _ } = model
		{ tasks, selected: id }
	}

	add_task : Model -> Model
	add_task = |model| {
		{ tasks, selected } = model
		id = "t${tasks.len().to_str()}"
		{ tasks: tasks.append({ id, title: "Task ${id}", done: Bool.False }), selected }
	}

	config : TaskRow.Config
	config = { label: "Task", done_text: "done" }

	first_title : Model -> Str
	first_title = |m| m.tasks.first().map_ok(|t| t.title) ?? "(none)"

	first_done : Model -> Bool
	first_done = |m| m.tasks.first().map_ok(|t| t.done) ?? Bool.False

	main : {} -> Elem(Root)
	main = |_| Engine.state(
		Canary.initial,
		|model| {
			m = model.val()
			tasks = m.map(|value| value.tasks)
			selected = Engine.keyed(m.map(|value| value.selected), Bool.True, Bool.False)
			Engine.element(
				"div",
				[],
				[
					## The component at the state's own layer.
					TaskRow.view(
						{ title: m.map(Canary.first_title), done: m.map(Canary.first_done), selected: Engine.const(Bool.False), test_id: Engine.const("featured") },
						Canary.config,
						{ on_remove: model.update(|value| value), on_toggle: model.update(|value| value) },
					),
					Engine.element("button", [Engine.attr("id", "add"), Engine.on_click(model.update(Canary.add_task))], [Engine.text("Add")]),
					Engine.element(
						"ul",
						[],
						[
							Engine.each(
								tasks,
								|task| task.id,
								|row| {
									key = row.key()
									in_row = model.lift_row()
									Engine.element(
										"div",
										[],
										[
											Engine.element("button", [Engine.on_click(in_row.update_by(key, Canary.select_task))], [Engine.text("Select")]),
											TaskRow.view(
												{
													title: row.field(|task| task.title),
													done: row.field(|task| task.done),
													selected: row.select(selected),
													test_id: key.map(|k| "row-${k}"),
												},
												Canary.config,
												{
													on_remove: in_row.update_by(key, Canary.remove_task),
													on_toggle: in_row.update_by(key, Canary.toggle_task),
												},
											),
										],
									)
								},
							),
						],
					),
				],
			)
		},
	)
}
