app [main] { pf: platform "../../../../../../../../home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a9954894a6aa838c9/platform-web/main.roc", roc: "nightly-2026-11-01-48d3369" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui
import TaskRow

Task : { id : Str, title : Str, done : Bool }

Model : { rows : Rows(Task), banner : Str, any_done : Bool }

start : {} -> Model
start = |{}| {
	rows: Rows.from_list([{ id: "a", title: "Alpha", done: False }, { id: "b", title: "Beta", done: True }], |t| t.id) ?? crash "unique",
	banner: "shared",
	any_done: True,
}

remove : Model, Str -> Model
remove = |m, key| { ..m, rows: Rows.apply(m.rows, [RemoveKey(key)]) ?? crash "valid" }

main : () -> Elem
main = ||
	Ui.state(
		start({}),
		|model| {
			rows = model.read(|m| m.rows)
			banner = model.read(|m| m.banner)
			any_done = model.read(|m| m.any_done)
			inputs = { title: banner, done: any_done }
			config = { label: "Task" }
			Html.div(
				[],
				[
					Html.text("ready"),
					Ui.each(rows, |row| TaskRow.view(row.key(), { title: row.map(|t| t.title), done: row.map(|t| t.done) }, config, |key| model.update(|m| remove(m, key)))),
				],
			)
		},
	)
