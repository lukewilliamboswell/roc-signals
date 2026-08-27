app [main] { pf: platform "../../platform/main.roc" }

# Dependency Scheduler.
#
# Tasks have durations and prerequisites. Moving or resizing one task cascades
# start dates through everything downstream, the critical path is highlighted,
# per-task slack is shown, and a cyclic dependency is detected and reported
# instead of hanging.
#
# The schedule renders as a Gantt chart: each row's bar is positioned and sized
# from the same solved `Plan.Row` that feeds its slack figure and its badge, so
# the bar, the number and the status word can never disagree.
#
# The platform's signal edges are static - they are declared once by
# `Signal.map` / `map2` / `combine` / `Ui.each_str` - so the task dependency
# graph is deliberately NOT mapped onto the signal graph. `Plan.compute` solves
# the whole schedule in one pure pass; the view is a small static signal graph
# over that single derived value, and keyed rows with per-row equality cutoffs
# are what keep a one-task move from touching every row.
#
# State is decomposed into four independent `Ui.state` handles:
#
#   tasks         : List(Plan.Task)  the only stored model
#   focus         : Str              which task the detail readout describes
#   only_critical : Bool             whether the list is filtered
#   by_slack      : Bool             whether the list is ordered by slack
#
# Everything else - start dates, finish dates, latest starts, slack, the
# critical path, the cycle report, the visible row set, and every bar geometry
# - is derived.

import Plan
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# ---------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------

page_class = "app-shell app-shell-wide"

panel_class = "panel"

panel_body_class = "panel-body"

row_class = "card gap-3"

row_grid_class = "grid gap-3 md:grid-cols-[16rem_minmax(0,1fr)_5rem] md:items-center"

axis_grid_class = "hidden gap-3 md:grid md:grid-cols-[16rem_minmax(0,1fr)_5rem] md:items-center"

track_class = "relative h-6 w-full overflow-hidden rounded-md bg-zinc-100 ring-1 ring-inset ring-zinc-200"

controls_class = "flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-zinc-100 pt-3"

stepper_class = "flex items-center gap-1.5"

step_button_class = "button button-sm w-7"

deps_box_class = "flex flex-wrap items-center gap-x-3 gap-y-1"

check_row_class = "check-row text-xs"

task_options : List(Elem)
task_options = Plan.initial_tasks.map(|t| Html.option(t.id, t.name))

name_of : Str -> Str
name_of = |id| Plan.initial_tasks.find_first(|t| t.id == id).map_ok(|found| found.name).ok_or(id)

# ---------------------------------------------------------------------------
# Display text. No domain logic and no classes live here.
# ---------------------------------------------------------------------------

days : U64 -> Str
days = |n| if n == 1 {
	"1 day"
} else {
	"${n.to_str()} days"
}

## The scheduled window, the one figure that moves on every cascade.
window_text : Plan.Row -> Str
window_text = |row|
	match row.status {
		Blocked => "Not scheduled"
		_ => "Day ${row.start.to_str()} → ${row.finish.to_str()}"
	}

## The duration shown between the resize buttons.
duration_text : Plan.Row -> Str
duration_text = |row| if row.duration == 0 {
	"milestone"
} else {
	days(row.duration)
}

## Slack as a bare figure so it can sit in a `tabular-nums` cell.
slack_text : Plan.Row -> Str
slack_text = |row|
	match row.status {
		Blocked => "—"
		_ => row.slack.to_str()
	}

## Prerequisites by name rather than by id, so a row explains why it moved.
deps_text : Plan.Row -> Str
deps_text = |row|
	if row.deps.is_empty() {
		"Starts the project"
	} else {
		"After ${Str.join_with(row.deps.map(name_of), ", ")}"
	}

## The status word. `Plan.Status` is `Critical` exactly when slack is zero, so
## the badge and the slack figure beside it are the same fact twice.
status_text : Plan.Row -> Str
status_text = |row|
	match row.status {
		Blocked => "Blocked"
		Critical => "Critical"
		HasSlack => "Has slack"
	}

row_tone : Plan.Row -> Str
row_tone = |row|
	match row.status {
		Blocked => "unscheduled"
		Critical => "critical"
		HasSlack => "slack"
	}

status_class : Plan.Row -> Str
status_class = |row|
	match row.status {
		Blocked => "badge badge-warn"
		Critical => "badge badge-danger"
		HasSlack => "badge badge-neutral"
	}

## Zero slack is the alarm colour, one day is a warning, anything looser is
## quiet. Same three-way split as the badge, one step finer.
slack_class : Plan.Row -> Str
slack_class = |row|
	match row.status {
		Blocked => "value numeric text-zinc-400"
		_ =>
			if row.slack == 0 {
				"value numeric text-red-600"
			} else if row.slack == 1 {
				"value numeric text-amber-600"
			} else {
				"value numeric text-zinc-500"
			}
	}

bar_class : Plan.Row -> Str
bar_class = |row|
	match row.status {
		Blocked => "absolute inset-y-1 rounded-sm bg-zinc-300"
		Critical => "absolute inset-y-1 rounded-sm bg-red-500 ring-1 ring-red-600"
		HasSlack => "absolute inset-y-1 rounded-sm bg-emerald-400"
	}

## A row's bar needs its own window *and* the project span, so this is the one
## place the per-row signal is joined with a project-wide one.
BarGeometry : { row : Plan.Row, span : U64 }

## Tailwind cannot emit a class for a percentage only known at runtime, so the
## geometry goes through a plain `style` attribute instead.
bar_style : BarGeometry -> Str
bar_style = |geometry| {
	row = geometry.row
	match row.status {
		Blocked => "display: none"
		_ => {
			total = if geometry.span == 0 {
				1
			} else {
				geometry.span
			}
			raw_left = (row.start * 100) // total
			left = if raw_left > 98 {
				98
			} else {
				raw_left
			}
			raw_width = (row.duration * 100) // total
			room = Plan.sat_sub(100, left)
			capped = if raw_width > room {
				room
			} else {
				raw_width
			}
			# A milestone has no duration at all, so it gets a minimum nub rather
			# than a zero-width bar that would render as nothing.
			width = if capped < 2 {
				2
			} else {
				capped
			}
			"left: ${left.to_str()}%; width: ${width.to_str()}%"
		}
	}
}

span_text : Plan.Schedule -> Str
span_text = |schedule| if schedule.cycle.is_empty() {
	days(schedule.project_end)
} else {
	"Unknown"
}

task_count_text : Plan.Schedule -> Str
task_count_text = |schedule| schedule.rows.len().to_str()

critical_count_text : Plan.Schedule -> Str
critical_count_text = |schedule| schedule.path.len().to_str()

## Tasks that still have room to move. The complement of the critical path, so
## the two figures always add up to the task count.
slack_count_text : Plan.Schedule -> Str
slack_count_text = |schedule| schedule.rows.keep_if(|r| Plan.Status.is_eq(r.status, HasSlack)).len().to_str()

path_text : Plan.Schedule -> Str
path_text = |schedule| if schedule.path.is_empty() {
	"None"
} else {
	Str.join_with(schedule.path, " → ")
}

axis_end_text : Plan.Schedule -> Str
axis_end_text = |schedule| if schedule.cycle.is_empty() {
	"Day ${schedule.project_end.to_str()}"
} else {
	"—"
}

cycle_text : Plan.Schedule -> Str
cycle_text = |schedule|
	if schedule.cycle.is_empty() {
		"No dependency cycle"
	} else {
		"Cycle detected among ${schedule.cycle.len().to_str()} tasks: ${Str.join_with(schedule.cycle.map(name_of), ", ")}"
	}

## The focus readout is four figures about one task, not a sentence about it.
detail_text : Plan.Schedule, Str -> Str
detail_text = |schedule, focus|
	match schedule.rows.find_first(|r| r.id == focus) {
		Ok(row) =>
			match row.status {
				Blocked => "Not scheduled while the plan is cyclic · moved ${days(row.lag)}"
				_ => "Earliest day ${row.start.to_str()} · latest day ${row.latest_start.to_str()} · slack ${days(row.slack)} · moved ${days(row.lag)}"
			}
		Err(_) => "${name_of(focus)} is not in the plan"
	}

## The shipped plan solves to a ten-day project down spec → api → sync → qa →
## launch; the parallel UI branch holds a day of slack and the docs branch more.
initial_schedule = Plan.compute(Plan.initial_tasks)

expect days(1) == "1 day"
expect days(0) == "0 days"
expect span_text(initial_schedule) == "10 days"
expect path_text(initial_schedule) == "Write spec → Build API → Integrate → QA pass → Launch"
expect slack_count_text(initial_schedule) == "2"
expect detail_text(initial_schedule, "ui") == "Earliest day 2 · latest day 3 · slack 1 day · moved 0 days"

## Delaying the head of the critical path pushes the whole project out a day.
expect span_text(Plan.compute(Plan.delay(Plan.initial_tasks, "spec"))) == "11 days"

## A cycle is reported rather than hung on, and every row reads as `Blocked`.
cyclic_schedule = Plan.compute(Plan.add_dep(Plan.initial_tasks, "spec", "launch"))

expect span_text(cyclic_schedule) == "Unknown"
expect path_text(cyclic_schedule) == "None"
expect axis_end_text(cyclic_schedule) == "—"
expect cyclic_schedule.rows.keep_if(|r| Plan.Status.is_eq(r.status, Blocked)).len() == 7

RowFilter : { rows : List(Plan.Row), only_critical : Bool, by_slack : Bool }

filter_text : RowFilter -> Str
filter_text = |view| {
	order = if view.by_slack {
		"most slack first"
	} else {
		"plan order"
	}
	"${visible_of(view).len().to_str()} of ${view.rows.len().to_str()} tasks · ${order}"
}

## The empty state is always in the tree and simply hidden while the list has
## rows, so toggling the filter never creates or disposes a scope.
empty_class : RowFilter -> Str
empty_class = |view| if visible_of(view).is_empty() {
	"empty-state"
} else {
	"hidden"
}

nth : List(Str), U64 -> Str
nth = |lines, index| lines.get(index).ok_or("")

visible_of : RowFilter -> List(Plan.Row)
visible_of = |view| {
	kept = if view.only_critical {
		view.rows.keep_if(|r| Plan.Status.is_eq(r.status, Critical))
	} else {
		view.rows
	}
	if view.by_slack {
		Plan.by_slack(kept)
	} else {
		kept
	}
}

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

## A metric tile. The value carries a `test_id` so a spec can address the
## number instead of a sentence wrapped around it.
stat : Str, Str, Signal.Signal(Str) -> Elem
stat = |label, id, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value")]),
		],
	)

## A visible caption plus its control. `Html.checkbox`'s first argument is only
## the accessible name, so the text beside it has to be drawn.
check_row : Str, Signal.Signal(Bool), Ui.State(Bool) -> Elem
check_row = |label, checked, state|
	Html.div_c(
		"check-row",
		[
			Html.checkbox_c(label, checked, "checkbox", state.on_bool(|_, value| value)),
			Html.text(label),
		],
	)

## One prerequisite checkbox. The reducer closes over the two task ids, so it
## needs nothing but the task list state it writes to.
dep_checkbox : Ui.State(List(Plan.Task)), Str, Signal.Signal(Plan.Row), Plan.Task -> Elem
dep_checkbox = |tasks, key, row, other|
	Html.div_c(
		check_row_class,
		[
			Html.checkbox_c(
				"${name_of(key)} after ${other.name}",
				row.map(|value| value.deps.contains(other.id)),
				"checkbox",
				tasks.on_bool(|list, checked| Plan.set_dep(list, key, other.id, checked)),
			),
			Html.text(other.name),
		],
	)

## What one stepper button does: the glyph it draws, the verb that names it and
## the edit it applies. Three `Str` arguments in a row are interchangeable at a
## call site, a record of them is not.
StepAction : {
	glyph : Str,
	verb : Str,
	apply : List(Plan.Task), Str -> List(Plan.Task),
}

## A stepper button. The glyph is the visible label and `aria_label` carries the
## descriptive name, so the control stays compact without going unnamed.
step_button : Ui.State(List(Plan.Task)), Str, StepAction -> Elem
step_button = |tasks, key, action|
	Html.button_attrs(
		action.glyph,
		[Html.class_attr(step_button_class), Html.aria_label("${action.verb} ${name_of(key)}")],
		# The parentheses keep `apply` a stored function being called rather than a
		# method lookup on the record.
		tasks.on_unit(|list| (action.apply)(list, key)),
	)

## The three cells of one stepper, named so a caller cannot swap the buttons for
## the readout they sit either side of.
Stepper : { down : Elem, readout : Elem, up : Elem }

## A labelled numeric readout between a decrement and an increment button.
stepper : Str, Stepper -> Elem
stepper = |label, cells|
	Html.div_c(
		stepper_class,
		[Html.paragraph_c(label, "hint"), cells.down, cells.readout, cells.up],
	)

render_row : Ui.State(List(Plan.Task)), Signal.Signal(U64), Str, Signal.Signal(Plan.Row) -> Elem
render_row = |tasks, span, key, row| {
	geometry : Signal.Signal(BarGeometry)
	geometry = { row: row, span: span }.Signal

	Html.section(
		"Task ${name_of(key)}",
		[
			Html.class_attr(row_class),
			Html.test_id("row-${key}"),
			Html.attr_s("data-tone", row.map(row_tone)),
		],
		[
			Html.div_c(
				row_grid_class,
				[
					Html.div_c(
						"grid gap-1 min-w-0",
						[
							Html.div_c(
								"flex flex-wrap items-center gap-2",
								[
									Html.heading_c(name_of(key), "card-title"),
									Html.paragraph_s_attrs(
										row.map(status_text),
										[Html.test_id("status-${key}"), Html.class_attr_s(row.map(status_class))],
									),
								],
							),
							Html.paragraph_s_attrs(
								row.map(window_text),
								[Html.test_id("line-${key}"), Html.class_attr("muted numeric")],
							),
							Html.paragraph_s_attrs(
								row.map(deps_text),
								[Html.test_id("deps-${key}"), Html.class_attr("hint")],
							),
						],
					),
					Html.div_c(
						track_class,
						[
							Html.div(
								[
									Html.test_id("bar-${key}"),
									Html.class_attr_s(row.map(bar_class)),
									Html.attr_s("style", geometry.map(bar_style)),
								],
								[],
							),
						],
					),
					Html.div_c(
						"flex items-baseline gap-1.5 md:grid md:justify-items-end md:gap-0",
						[
							# The column header carries this label on wide screens.
							Html.paragraph_c("Slack", "hint md:hidden"),
							Html.paragraph_s_attrs(
								row.map(slack_text),
								[Html.test_id("slack-${key}"), Html.class_attr_s(row.map(slack_class))],
							),
						],
					),
				],
			),
			Html.div_c(
				controls_class,
				[
					stepper(
						"Start",
						{
							down: step_button(tasks, key, { glyph: "◀", verb: "Pull in", apply: Plan.pull_in }),
							readout: Html.paragraph_s_attrs(
								row.map(|value| "+${value.lag.to_str()}d"),
								[Html.test_id("lag-${key}"), Html.class_attr("value numeric w-10 text-center")],
							),
							up: step_button(tasks, key, { glyph: "▶", verb: "Delay", apply: Plan.delay }),
						},
					),
					stepper(
						"Duration",
						{
							down: step_button(tasks, key, { glyph: "−", verb: "Shorten", apply: Plan.shorten }),
							readout: Html.paragraph_s_attrs(
								row.map(duration_text),
								[Html.test_id("duration-${key}"), Html.class_attr("value numeric w-20 text-center")],
							),
							up: step_button(tasks, key, { glyph: "+", verb: "Extend", apply: Plan.extend }),
						},
					),
					Html.div_c(
						deps_box_class,
						[Html.paragraph_c("Needs", "hint")].concat(
							Plan.initial_tasks.keep_if(|t| t.id != key).map(|other| dep_checkbox(tasks, key, row, other)),
						),
					),
				],
			),
		],
	)
}

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
									# text, bar geometry and checkbox states.
									schedule = tasks_signal.map(Plan.compute)

									no_cycle = Signal.map(schedule, |s| s.cycle.is_empty())

									# The project span every bar is measured against.
									span : Signal.Signal(U64)
									span = Signal.map(schedule, |s| s.project_end)

									# Fan-in A: the task list and the focus selection are
									# two independent sources meeting in one `map2`.
									detail = Signal.map2(schedule, focus_signal, detail_text)

									# Fan-in B: three independent sources - the task list
									# and both list checkboxes - decide which rows exist
									# and in what order.
									row_view : Signal.Signal(RowFilter)
									row_view =
										{
											rows: Signal.map(schedule, |s| s.rows),
											only_critical: critical_only_signal,
											by_slack: by_slack_signal,
										}.Signal

									visible_rows = row_view.map(visible_of)

									# Fan-in C: a wide same-shaped fan-in over three
									# already-derived lines, one of which is itself the
									# `map2` above, so this is four hops from `tasks`.
									headline =
										Signal.combine([
											schedule.map(span_text),
											schedule.map(path_text),
											detail,
										])

									Html.div_c(
										page_class,
										[
											Html.div_c(
												"app-header",
												[
													Html.heading_c("Dependency Scheduler", "app-title"),
													Html.paragraph_c(
														"Move or resize a task and every downstream start date cascades. Slack and the critical path are derived, never stored, and a cyclic dependency is reported instead of hanging.",
														"app-subtitle",
													),
												],
											),
											Html.section_c(
												"Project summary",
												panel_class,
												[
													Html.div_c(
														"panel-head",
														[Html.heading_c("Project summary", "panel-title")],
													),
													Html.div_c(
														panel_body_class,
														[
															Html.div_c(
																"stat-grid",
																[
																	stat("Project span", "project-summary", headline.map(|lines| nth(lines, 0))),
																	stat("Tasks", "task-count", schedule.map(task_count_text)),
																	stat("On the critical path", "path-length", schedule.map(critical_count_text)),
																	stat("Tasks with slack", "slack-count", schedule.map(slack_count_text)),
																],
															),
															Html.div_c(
																"field",
																[
																	Html.paragraph_c("Critical path", "field-label"),
																	Html.paragraph_s_attrs(
																		headline.map(|lines| nth(lines, 1)),
																		[Html.test_id("critical-path"), Html.class_attr("value")],
																	),
																],
															),
															Ui.when(
																no_cycle,
																|| Html.section_c(
																	"Plan health",
																	"notice notice-ok",
																	[Html.text("Every task is schedulable.")],
																),
																|| Html.section_c(
																	"Cycle report",
																	"notice notice-error grid gap-1",
																	[
																		Html.paragraph_s_attrs(
																			schedule.map(cycle_text),
																			[Html.test_id("cycle-report"), Html.class_attr("font-medium")],
																		),
																		Html.paragraph_c(
																			"Clear one of the Needs checkboxes below to schedule the project again.",
																			"text-xs",
																		),
																	],
																),
															),
															Html.div_c(
																"field",
																[
																	Html.paragraph_c("Focus task", "field-label"),
																	Html.select_c("Focus task", focus_signal, "input", task_options, focus.on_str(|_, value| value)),
																	Html.paragraph_s_attrs(
																		headline.map(|lines| nth(lines, 2)),
																		[Html.test_id("focus-detail"), Html.class_attr("hint numeric")],
																	),
																],
															),
														],
													),
												],
											),
											Html.section_c(
												"Schedule",
												panel_class,
												[
													Html.div_c(
														"panel-head",
														[
															Html.heading_c("Schedule", "panel-title"),
															Html.paragraph_s_attrs(
																row_view.map(filter_text),
																[Html.test_id("filter-state"), Html.class_attr("hint numeric")],
															),
														],
													),
													Html.div_c(
														panel_body_class,
														[
															Html.div_c(
																"toolbar",
																[
																	check_row("Only critical path", critical_only_signal, only_critical),
																	check_row("Sort by slack", by_slack_signal, by_slack),
																],
															),
															Html.div_c(
																axis_grid_class,
																[
																	Html.paragraph_c("Task", "hint"),
																	Html.div_c(
																		"flex items-center justify-between",
																		[
																			Html.paragraph_c("Day 0", "hint numeric"),
																			Html.paragraph_s_attrs(
																				schedule.map(axis_end_text),
																				[Html.test_id("axis-end"), Html.class_attr("hint numeric")],
																			),
																		],
																	),
																	Html.paragraph_c("Slack", "hint md:text-right"),
																],
															),
															Html.div_c(
																"grid gap-3",
																[Ui.each_str(visible_rows, |row| row.id, |key, row| render_row(tasks, span, key, row))],
															),
															Html.div(
																[
																	Html.test_id("empty-schedule"),
																	Html.class_attr_s(row_view.map(empty_class)),
																],
																[Html.text("No tasks match this filter. Clear \"Only critical path\" to see the whole plan.")],
															),
														],
													),
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
