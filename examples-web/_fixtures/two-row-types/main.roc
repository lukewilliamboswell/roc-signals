app [main] { roc: "nightly-2026-09-09-7dadc35", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui

## Size fixture: two independent keyed lists whose item types differ, so the
## artifact carries every per-item-type `Rows` and `Ui.each` specialization
## twice. Compare against `keyed-row-edits` to see the second type's cost.
Task : { id : Str, title : Str, done : Bool }

Tag : { slug : Str, weight : U64 }

Model : { tasks : Rows(Task), tags : Rows(Tag), next : U64 }

task_key : Task -> Str
task_key = |task| task.id

tag_key : Tag -> Str
tag_key = |tag| tag.slug

initial_model : Model
initial_model = {
	tasks: Rows.from_list([{ id: "t1", title: "Write fixture", done: False }], task_key) ?? Rows.empty(task_key),
	tags: Rows.from_list([{ slug: "size", weight: 1 }], tag_key) ?? Rows.empty(tag_key),
	next: 2,
}

add_task : Model -> Model
add_task = |model| {
	task = { id: "t${model.next.to_str()}", title: "Task ${model.next.to_str()}", done: False }
	{ ..model, tasks: Rows.apply(model.tasks, [Append([task])]) ?? model.tasks, next: model.next + 1 }
}

toggle_task : Model, Str -> Model
toggle_task = |model, key|
	match Rows.get_key(model.tasks, key) {
		Ok(task) => { ..model, tasks: Rows.apply(model.tasks, [SetKey({ key, item: { ..task, done: !task.done } })]) ?? model.tasks }
		Err(_) => model
	}

remove_task : Model, Str -> Model
remove_task = |model, key| { ..model, tasks: Rows.apply(model.tasks, [RemoveKey(key)]) ?? model.tasks }

add_tag : Model -> Model
add_tag = |model| {
	tag = { slug: "tag-${model.next.to_str()}", weight: model.next }
	{ ..model, tags: Rows.apply(model.tags, [InsertAt({ at: 0, items: [tag] })]) ?? model.tags, next: model.next + 1 }
}

bump_tag : Model, Str -> Model
bump_tag = |model, key|
	match Rows.get_key(model.tags, key) {
		Ok(tag) => { ..model, tags: Rows.apply(model.tags, [SetKey({ key, item: { ..tag, weight: tag.weight + 1 } })]) ?? model.tags }
		Err(_) => model
	}

clear_tags : Model -> Model
clear_tags = |model| { ..model, tags: Rows.apply(model.tags, [Clear]) ?? model.tags }

task_label : Task -> Str
task_label = |task| if task.done { "[x] ${task.title}" } else { "[ ] ${task.title}" }

tag_label : Tag -> Str
tag_label = |tag| "#${tag.slug} (${tag.weight.to_str()})"

render_task : Ui.State(Model), Ui.Row(Task) -> Elem
render_task = |model, row| {
	key = row.key()
	Html.div(
		[Html.test_id("task-${key}")],
		[
			Html.text_s(row.map(task_label)),
			Html.button("Toggle ${key}", model.on_unit(|value| toggle_task(value, key))),
			Html.button("Remove ${key}", model.on_unit(|value| remove_task(value, key))),
		],
	)
}

render_tag : Ui.State(Model), Ui.Row(Tag) -> Elem
render_tag = |model, row| {
	key = row.key()
	Html.div(
		[Html.test_id("tag-${key}")],
		[
			Html.text_s(row.map(tag_label)),
			Html.button("Bump ${key}", model.on_unit(|value| bump_tag(value, key))),
		],
	)
}

main : () -> Elem
main = || {
	Ui.state(
		initial_model,
		|model| {
			tasks = model.signal().map(|value| value.tasks)
			tags = model.signal().map(|value| value.tags)

			Html.div_c(
				"grid gap-6",
				[
					Html.heading("Two row types"),
					Html.button("Add task", model.on_unit(add_task)),
					Html.button("Add tag", model.on_unit(add_tag)),
					Html.button("Clear tags", model.on_unit(clear_tags)),
					Html.div([Html.test_id("tasks")], [Ui.each(tasks, |row| render_task(model, row))]),
					Html.div([Html.test_id("tags")], [Ui.each(tags, |row| render_tag(model, row))]),
				],
			)
		},
	)
}
