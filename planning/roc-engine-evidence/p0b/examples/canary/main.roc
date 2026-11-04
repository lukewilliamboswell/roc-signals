app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui
import pf.Val
import TaskRow

Task : { id : Str, title : Str, done : Bool }

Model : { tasks : Rows(Task), selected : Str }

initial_tasks : List(Task)
initial_tasks = [
	{ id: "a", title: "Write the canary", done: False },
	{ id: "b", title: "Check it", done: True },
]

initial : Model
initial = {
	tasks: Rows.replace_all(Rows.empty(|task| task.id), initial_tasks) ?? crash "duplicate task ids",
	selected: "",
}

remove_task : Model, Str -> Model
remove_task = |model, id| { ..model, tasks: Rows.apply(model.tasks, [RemoveKey(id)]) ?? model.tasks }

toggle_task : Model, Str, Bool -> Model
toggle_task = |model, id, done|
	match Rows.get_key(model.tasks, id) {
		Ok(task) => { ..model, tasks: Rows.apply(model.tasks, [SetKey({ key: id, item: { ..task, done } })]) ?? model.tasks }
		Err(_) => model
	}

config : TaskRow.Config
config = { label: "Task", done_text: "done" }

main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		initial,
		|model| {
			model_signal = model.signal()
			tasks = model_signal.map(|value| value.tasks)
			selected = model_signal.map(|value| value.selected).keyed(True, False)
			first_title = model_signal.map(|value| Rows.get(value.tasks, 0).map_ok(|task| task.title) ?? "(none)")
			Html.div(
				[],
				[
					## The same component at the root, fed by site-level signals.
					TaskRow.view(
						{
							title: first_title.to_val(),
							done: model_signal.map(|value| Rows.get(value.tasks, 0).map_ok(|task| task.done) ?? False).to_val(),
							selected: Val.const(False),
							test_id: Val.const("featured"),
						},
						config,
						{ on_remove: model.update(|value| value), on_toggle: model.update(|value| value) },
					),
					Html.element(
						"ul",
						[],
						[
							Ui.each(
								tasks,
								|row| {
									key = row.key()
									TaskRow.view(
										{
											title: row.field(|task| task.title),
											done: row.field(|task| task.done),
											selected: row.select(selected),
											test_id: key.map(|k| "row-${k}"),
										},
										config,
										{
											on_remove: model.update_by(key, remove_task),
											on_toggle: model.update_bool_by(key, toggle_task),
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

## The root description builds; each row template is described once, with holes.
expect {
	actual = Elem.platform_describe(main())
	actual == "<div:0>{local <li:2>Task: {val}<input:4></input>{when <span:1>done</span> | }<button:1>Details</button>{when <p:0>Title: {val}</p> | }<button:1>Remove</button></li>}<ul:0>{each {local <li:2>Task: {val}<input:4></input>{when <span:1>done</span> | }<button:1>Details</button>{when <p:0>Title: {val}</p> | }<button:1>Remove</button></li>}}</ul></div>"
}
