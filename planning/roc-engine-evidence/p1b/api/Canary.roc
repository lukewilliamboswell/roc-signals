import DUi exposing [Elem, Root, In]
import TaskRow

## The 0b canary app on representation D's API.
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
	remove_task = |model, id| { tasks: model.tasks.keep_if(|t| t.id != id), selected: model.selected }

	toggle_task : Model, Str, Bool -> Model
	toggle_task = |model, id, done| { tasks: model.tasks.map(|t| if t.id == id { id: t.id, title: t.title, done } else t), selected: model.selected }

	config : TaskRow.Config
	config = { label: "Task", done_text: "done" }

	first_title : Model -> Str
	first_title = |m| m.tasks.first().map_ok(|t| t.title) ?? "(none)"

	first_done : Model -> Bool
	first_done = |m| m.tasks.first().map_ok(|t| t.done) ?? Bool.False

	main : {} -> Elem(Root)
	main = |_| DUi.state(
		Canary.initial,
		|model| {
			m = model.val()
			tasks = m.map(|value| value.tasks)
			selected = DUi.keyed(m.map(|value| value.selected), Bool.True, Bool.False)
			DUi.element(
				"div",
				[],
				[
					## The component at the state's own layer.
					TaskRow.view(
						{ title: m.map(Canary.first_title), done: m.map(Canary.first_done), selected: DUi.const(Bool.False), test_id: DUi.const("featured") },
						Canary.config,
						{ on_remove: model.update(|value| value), on_toggle: model.update(|value| value) },
					),
					DUi.element(
						"ul",
						[],
						[
							DUi.each(
								tasks,
								|task| task.id,
								|row| {
									key = row.key()
									in_row = model.lift_row()
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
											on_toggle: in_row.update_bool_by(key, Canary.toggle_task),
										},
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

expect {
	actual = DUi.describe(Canary.main({}))
	actual == "{state <div:0>{state <li:2>Task: {val}<input:4></input>{when <span:1>done</span> | }<button:1>Details</button>{when <p:0>Title: {val}</p> | }<button:1>Remove</button></li>}<ul:0>{each {state <li:2>Task: {val}<input:4></input>{when <span:1>done</span> | }<button:1>Details</button>{when <p:0>Title: {val}</p> | }<button:1>Remove</button></li>}}</ul></div>}"
}
