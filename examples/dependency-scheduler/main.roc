app [main] { pf: platform "../../platform/main.roc" }

# Dependency Scheduler.
#
# Tasks have durations and prerequisites. Moving or resizing one task cascades
# start dates through everything downstream, the critical path is highlighted,
# per-task slack is shown, and a cyclic dependency is detected and reported
# instead of hanging.
#
# The platform's signal edges are static - they are declared once by
# `Signal.map` / `map2` / `combine` / `Ui.each_str` - so the task dependency
# graph is deliberately NOT mapped onto the signal graph. `Plan.compute` solves
# the whole schedule in one pure pass; the view is a small static signal graph
# over that single derived value, and keyed rows with per-row equality cutoffs
# are what keep a one-task move from touching every row.
#
# State is decomposed into three independent `Ui.state` handles:
#
#   tasks         : List(Plan.Task)  the only stored model
#   focus         : Str              which task the detail readout describes
#   only_critical : Bool             whether the list is filtered
#   by_slack      : Bool             whether the list is ordered by slack
#
# Everything else - start dates, finish dates, latest starts, slack, the
# critical path, the cycle report, the visible row set - is derived.

import Plan
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

row_class = "grid gap-1 rounded border border-zinc-200 p-3"

deps_class = "flex flex-wrap gap-3"

controls_class = "flex flex-wrap gap-2"

note_class = "text-sm text-zinc-700"

strong_class = "text-sm font-medium text-zinc-950"

heading_class = "text-lg font-semibold text-zinc-950"

button_class = "button-secondary"

task_options : List(Elem)
task_options = Plan.initial_tasks.map(|t| Html.option(t.id, t.name))

name_of : Str -> Str
name_of = |id|
	match Plan.initial_tasks.find_first(|t| t.id == id) {
		Ok(found) => found.name
		Err(_) => id
	}

# ---------------------------------------------------------------------------
# Display text. No domain logic and no classes live here.
# ---------------------------------------------------------------------------

days : U64 -> Str
days = |n| if n == 1 {
	"1 day"
} else {
	"${n.to_str()} days"
}

row_line : Plan.Row -> Str
row_line = |row| {
	shape = if row.duration == 0 {
		"milestone"
	} else {
		days(row.duration)
	}
	if !row.scheduled {
		"${row.name}: unscheduled while the plan is cyclic, ${shape}, after ${row.deps_text}"
	} else {
		standing = if row.critical {
			"critical"
		} else {
			"slack ${days(row.slack)}"
		}
		"${row.name}: day ${row.start.to_str()} to ${row.finish.to_str()}, ${shape}, after ${row.deps_text}, ${standing}"
	}
}

row_tone : Plan.Row -> Str
row_tone = |row|
	if !row.scheduled {
		"unscheduled"
	} else if row.critical {
		"critical"
	} else {
		"slack"
	}

summary_line : Plan.Schedule -> Str
summary_line = |schedule|
	if schedule.cycle.is_empty() {
		"Project finishes on day ${schedule.project_end.to_str()} across ${schedule.rows.len().to_str()} tasks"
	} else {
		"Project end unknown while the dependency graph is cyclic"
	}

path_line : Plan.Schedule -> Str
path_line = |schedule|
	if schedule.path.is_empty() {
		"Critical path: none"
	} else {
		"Critical path: ${Str.join_with(schedule.path, " -> ")}"
	}

cycle_line : Plan.Schedule -> Str
cycle_line = |schedule|
	if schedule.cycle.is_empty() {
		"No dependency cycle"
	} else {
		"Cycle detected among ${schedule.cycle.len().to_str()} tasks: ${Str.join_with(schedule.cycle.map(name_of), ", ")}"
	}

detail_line : Plan.Schedule, Str -> Str
detail_line = |schedule, focus|
	match schedule.rows.find_first(|r| r.id == focus) {
		Ok(row) =>
			if row.scheduled {
				"Focus ${row.name}: earliest start day ${row.start.to_str()}, latest start day ${row.latest_start.to_str()}, slack ${days(row.slack)}, moved ${days(row.lag)}"
			} else {
				"Focus ${row.name}: unscheduled, moved ${days(row.lag)}"
			}
		Err(_) => "Focus ${name_of(focus)}: not in the plan"
	}

RowFilter : { rows : List(Plan.Row), only_critical : Bool, by_slack : Bool }

filter_line : RowFilter -> Str
filter_line = |view| {
	scope = if view.only_critical {
		"critical-path tasks only"
	} else {
		"all tasks"
	}
	order = if view.by_slack {
		"most slack first"
	} else {
		"plan order"
	}
	"Showing ${scope}, ${visible_of(view).len().to_str()} rows, ${order}"
}

visible_of : RowFilter -> List(Plan.Row)
visible_of = |view| {
	kept = if view.only_critical {
		view.rows.keep_if(|r| r.critical)
	} else {
		view.rows
	}
	if view.by_slack {
		Plan.by_slack(kept)
	} else {
		kept
	}
}

nth : List(Str), U64 -> Str
nth = |lines, index|
	match lines.get(index) {
		Ok(line) => line
		Err(_) => ""
	}

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

## One prerequisite checkbox. The reducer closes over the two task ids, so it
## needs nothing but the task list state it writes to.
dep_checkbox : Ui.State(List(Plan.Task)), Str, Signal.Signal(Plan.Row), Plan.Task -> Elem
dep_checkbox = |tasks, key, row, other|
	Html.checkbox(
		"${name_of(key)} after ${other.name}",
		row.map(|value| value.deps.contains(other.id)),
		tasks.on_bool(|list, checked| Plan.set_dep(list, key, other.id, checked)),
	)

move_button : Ui.State(List(Plan.Task)), Str, Str, (List(Plan.Task), Str -> List(Plan.Task)) -> Elem
move_button = |tasks, key, verb, apply|
	Html.button_c("${verb} ${name_of(key)}", button_class, tasks.on_unit(|list| apply(list, key)))

render_row : Ui.State(List(Plan.Task)), Str, Signal.Signal(Plan.Row) -> Elem
render_row = |tasks, key, row|
	Html.section(
		"Task ${name_of(key)}",
		[
			Html.class_attr(row_class),
			Html.test_id("row-${key}"),
			Html.attr_s("data-tone", row.map(row_tone)),
		],
		[
			Html.paragraph_s_attrs(row.map(row_line), [Html.test_id("line-${key}"), Html.class_attr(note_class)]),
			Html.div_c(
				controls_class,
				[
					move_button(tasks, key, "Delay", Plan.delay),
					move_button(tasks, key, "Pull in", Plan.pull_in),
					move_button(tasks, key, "Extend", Plan.extend),
					move_button(tasks, key, "Shorten", Plan.shorten),
				],
			),
			Html.div_c(
				deps_class,
				Plan.initial_tasks.keep_if(|t| t.id != key).map(|other| dep_checkbox(tasks, key, row, other)),
			),
		],
	)

main : () -> Elem
main = || {
	Ui.state(
		Plan.initial_tasks,
		|tasks| {
			Ui.state(
				"ui",
				|focus| {
					Ui.state(
						False,
						|only_critical| {
							Ui.state(
								False,
								|by_slack| {
									tasks_signal = tasks.signal()
									focus_signal = focus.signal()
									critical_only_signal = only_critical.signal()
									by_slack_signal = by_slack.signal()

									# The single derived solve, shared by every consumer
									# below. Chain: tasks -> schedule -> rows -> per-row
									# text and per-row checkbox states.
									schedule = tasks_signal.map(Plan.compute)

									no_cycle = schedule.map(|s| s.cycle.is_empty())

									# Fan-in A: the task list and the focus selection are
									# two independent sources meeting in one `map2`.
									detail = Signal.map2(schedule, focus_signal, detail_line)

									# Fan-in B: three independent sources - the task list
									# and both list checkboxes - decide which rows exist
									# and in what order.
									row_view : Signal.Signal(RowFilter)
									row_view =
										{
											rows: schedule.map(|s| s.rows),
											only_critical: critical_only_signal,
											by_slack: by_slack_signal,
										}.Signal

									visible_rows = row_view.map(visible_of)

									# Fan-in C: a wide same-shaped fan-in over three
									# already-derived lines, one of which is itself the
									# `map2` above, so this is four hops from `tasks`.
									headline =
										Signal.combine([
											schedule.map(summary_line),
											schedule.map(path_line),
											detail,
										])

									Html.div_c(
										page_class,
										[
											Html.section_c(
												"Dependency Scheduler",
												hero_class,
												[
													Html.heading_c("Dependency Scheduler", "text-3xl font-semibold text-zinc-950"),
													Html.paragraph_c(
														"Move or resize a task and every downstream start date cascades. Slack and the critical path are derived, never stored, and a cyclic dependency is reported instead of hanging.",
														"max-w-3xl text-sm text-zinc-700",
													),
												],
											),
											Html.section_c(
												"Project summary",
												panel_class,
												[
													Html.heading_c("Project summary", heading_class),
													Html.paragraph_s_attrs(
														headline.map(|lines| nth(lines, 0)),
														[Html.test_id("project-summary"), Html.class_attr(strong_class)],
													),
													Html.paragraph_s_attrs(
														headline.map(|lines| nth(lines, 1)),
														[Html.test_id("critical-path"), Html.class_attr(strong_class)],
													),
													Html.paragraph_s_attrs(
														headline.map(|lines| nth(lines, 2)),
														[Html.test_id("focus-detail"), Html.class_attr(note_class)],
													),
													Html.select("Focus task", focus_signal, task_options, focus.on_str(|_, value| value)),
												],
											),
											Ui.when(
												no_cycle,
												|| Html.section_c(
													"Plan health",
													panel_class,
													[Html.paragraph_c("Plan health: schedulable", strong_class)],
												),
												|| Html.section_c(
													"Cycle report",
													panel_class,
													[
														Html.heading_c("Cycle report", heading_class),
														Html.paragraph_s_attrs(
															schedule.map(cycle_line),
															[Html.test_id("cycle-report"), Html.class_attr(strong_class)],
														),
														Html.paragraph_c(
															"Clear one of the prerequisite checkboxes below to schedule the project again.",
															note_class,
														),
													],
												),
											),
											Html.section_c(
												"Schedule",
												panel_class,
												[
													Html.heading_c("Schedule", heading_class),
													Html.checkbox("Only critical path", critical_only_signal, only_critical.on_bool(|_, checked| checked)),
													Html.checkbox("Sort by slack", by_slack_signal, by_slack.on_bool(|_, checked| checked)),
													Html.paragraph_s_attrs(
														row_view.map(filter_line),
														[Html.test_id("filter-state"), Html.class_attr(note_class)],
													),
													Ui.each_str(visible_rows, |row| row.id, |key, row| render_row(tasks, key, row)),
												],
											),
										],
									)
								},
							)
						},
					)
				},
			)
		},
	)
}
