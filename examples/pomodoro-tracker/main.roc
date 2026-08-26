app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

# Pomodoro Tracker
#
# A focus timer with per-project time tracking. Three things are worth studying:
#
# 1. Elapsed time is *derived*, never accumulated. The clock is
#    `Signal.interval(1000)` and every timer reading is a `Signal.map` of that
#    tick count. Starting/pausing swaps a `Ui.when` branch, and the branch swap
#    is what disposes the interval and rewinds the clock to zero.
#    `Ui.on_change(ticks, |n| elapsed.set_cmd(n))` could push ticks into a
#    `Ui.state` instead, but that would only mirror the tick count into storage:
#    `set_cmd` takes a value, and the `on_change` callback cannot read the
#    state's current value, so nothing here could actually be *accumulated*.
#    Deriving also gives the intended semantics for free - "pausing voids the
#    block in progress" is exactly what disposing the interval scope means.
# 2. Retained state is seeded from localStorage through a keyed row. `Ui.state`
#    takes a plain initial value, so it cannot await a host source. But an
#    `Ui.each_str` row body runs when the row mounts, with the row key in hand -
#    so keying a single row by the saved ledger text lets the state inside it
#    start from saved data. The trade-off is visible in the spec: saving the
#    ledger changes that key, so the ledger scope re-mounts from the saved text.
# 3. Every total on the page is derived. The per-row minutes, the block count and
#    the daily rollup all fan in from the ledger and the clock; nothing is kept
#    in sync by hand.

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell app-shell-narrow"
stack_class = "grid gap-5"
header_class = "app-header"
panel_class = "panel grid gap-4 p-5"
card_class = "card grid gap-3"
toolbar_class = "toolbar"
clock_class = "text-5xl font-semibold tabular-nums text-zinc-950"
value_class = "value numeric"
muted_class = "muted"
hint_class = "hint"

## One focus block, in minutes. This demo ticks once per second and counts each
## tick as a minute so the whole cycle is short enough to watch.
focus_len : U64
focus_len = 5

## The break that follows a focus block.
break_len : U64
break_len = 2

ledger_key = "pomodoro:ledger"
project_key = "pomodoro:project"

Project : { id : Str, name : Str, blocks : U64 }

## What the clock currently contributes: which project it is attached to, and
## how many ticks the current cycle has run for.
Live : { project : Str, ticks : U64 }

## One project row's display values, fanned in from the row item and the clock.
RowView : { name : Str, minutes : U64, attached : Bool, can_log : Bool }

RunState := [Idle, Running, Paused].{
	is_eq : RunState, RunState -> Bool
	is_eq = |left, right|
		match left {
			Idle => match right {
				Idle => True
				_ => False
			}
			Running => match right {
				Running => True
				_ => False
			}
			Paused => match right {
				Paused => True
				_ => False
			}
		}
}

catalogue : List({ id : Str, name : Str })
catalogue = [
	{ id: "api", name: "API rewrite" },
	{ id: "docs", name: "Docs pass" },
	{ id: "triage", name: "Bug triage" },
]

project_name : Str -> Str
project_name = |id| catalogue.fold("none", |acc, entry| if entry.id == id { entry.name } else { acc })

# --- storage codec -----------------------------------------------------------

stored_text : Browser.StorageText -> Str
stored_text = |stored|
	match stored {
		StorageValue(value) => value
		_ => ""
	}

parse_u64 : Str -> U64
parse_u64 = |text|
	text.to_utf8().fold(
		0,
		|acc, byte|
			if byte >= 48 and byte <= 57 {
				acc * 10 + U8.to_u64(byte) - 48
			} else {
				acc
			},
	)

second_field : List(Str) -> Str
second_field = |parts|
	match parts.drop_first(1).first() {
		Ok(value) => value
		Err(_) => ""
	}

blocks_for : List(Str), Str -> U64
blocks_for = |pairs, id|
	pairs.fold(
		0,
		|acc, pair| {
			parts = pair.split_on("=")
			match parts.first() {
				Ok(key) => if key == id { parse_u64(second_field(parts)) } else { acc }
				Err(_) => acc
			}
		},
	)

decode_ledger : Str -> List(Project)
decode_ledger = |text| {
	pairs = text.split_on(";")
	catalogue.map(|entry| { id: entry.id, name: entry.name, blocks: blocks_for(pairs, entry.id) })
}

encode_ledger : List(Project) -> Str
encode_ledger = |projects| Str.join_with(projects.map(|p| "${p.id}=${p.blocks.to_str()}"), ";")

# --- derived timer readings --------------------------------------------------

is_running : RunState -> Bool
is_running = |run|
	match run {
		Running => True
		_ => False
	}

is_idle : RunState -> Bool
is_idle = |run|
	match run {
		Idle => True
		_ => False
	}

run_text : RunState -> Str
run_text = |run|
	match run {
		Idle => "Timer: idle"
		Running => "Timer: running"
		Paused => "Timer: paused"
	}

## The badge tone comes off the same signal as its caption, so the two can
## never disagree.
run_badge_class : RunState -> Str
run_badge_class = |run|
	match run {
		Idle => "badge badge-neutral shrink-0"
		Running => "badge badge-ok shrink-0"
		Paused => "badge badge-warn shrink-0"
	}

start_label : RunState -> Str
start_label = |run|
	match run {
		Idle => "Start timer"
		Running => "Pause timer"
		Paused => "Resume timer"
	}

toggle_run : RunState -> RunState
toggle_run = |run|
	match run {
		Running => RunState.Paused
		_ => RunState.Running
	}

## The whole clock face is one pure function of the tick count.
phase_text : U64 -> Str
phase_text = |ticks|
	if ticks < focus_len {
		"Focus ${ticks.to_str()}/${focus_len.to_str()} min"
	} else if ticks < focus_len + break_len {
		"Break ${(ticks - focus_len).to_str()}/${break_len.to_str()} min"
	} else {
		"Cycle complete"
	}

## Minutes the current cycle has contributed so far, capped at one focus block.
live_minutes : Live -> U64
live_minutes = |live|
	if live.project == "" {
		0
	} else if live.ticks > focus_len {
		focus_len
	} else {
		live.ticks
	}

row_view : Project, Live -> RowView
row_view = |project, live| {
	attached = live.project == project.id
	{
		name: project.name,
		minutes: project.blocks * focus_len + (if attached { live_minutes(live) } else { 0 }),
		attached,
		can_log: attached and live.ticks >= focus_len,
	}
}

## The row's name sits in the card title, so the value beside it carries only
## the number and its unit.
row_minutes_text : RowView -> Str
row_minutes_text = |view| "${view.minutes.to_str()} min today"

attached_text : Str -> Str
attached_text = |id| "Attached project: ${project_name(id)}"

logged_blocks : List(Project) -> U64
logged_blocks = |projects| projects.fold(0, |acc, p| acc + p.blocks)

log_block : List(Project), Str -> List(Project)
log_block = |projects, id| projects.map(|p| if p.id == id { { ..p, blocks: p.blocks + 1 } } else { p })

# --- views -------------------------------------------------------------------

render_row : Ui.State(Str), Ui.State(List(Project)), Signal.Signal(Live), Str, Signal.Signal(Project) -> Elem
render_row = |attach, ledger, live, key, item| {
	name = project_name(key)
	# Fan-in: this row's item signal and the shared clock signal.
	view = Signal.map2(item, live, row_view)

	Html.section(
		name,
		[Html.class_attr(card_class)],
		[
			Html.div_c(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.paragraph_c(name, "card-title"),
					# One text sink for the number, so attaching a project costs one
					# patch per row whose total actually moved.
					Html.paragraph_s_attrs(view.map(row_minutes_text), [Html.class_attr(value_class), Html.test_id("row-total-${key}")]),
				],
			),
			Html.div_c(
				toolbar_class,
				[
					Html.button_c("Attach ${name}", "button button-sm", attach.on_unit(|_| key)),
					Html.action_button_c(
						Signal.const("Log block to ${name}"),
						view.map(|v| !v.can_log),
						"button button-sm",
						ledger.on_unit(|projects| log_block(projects, key)),
					),
				],
			),
		],
	)
}

## One metric tile: a label and the number under it. The test id rides on the
## value, which is the part a spec cares about.
stat_tile : Str, Str, Signal.Signal(Str) -> Elem
stat_tile = |test_id, label, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value numeric"), Html.test_id(test_id)]),
		],
	)

board : Ui.State(Str), Ui.State(RunState), Ui.State(List(Project)), Signal.Signal(Str), Signal.Signal(U64), List(Elem) -> Elem
board = |attach, run, ledger, attached, ticks, extras| {
	run_signal = run.signal()
	projects = ledger.signal()

	# Fan-in: the attached-project state and the interval tick count.
	live = Signal.map2(attached, ticks, |project, count| { project, ticks: count })

	# Fan-in over every project plus the live clock: the daily rollup.
	# Chain: ticks -> live -> rollup -> rollup_text is four hops deep.
	rollup = Signal.map2(projects, live, |list, l| logged_blocks(list) * focus_len + live_minutes(l))

	Html.div_c(
		stack_class,
		[
			Html.section_c(
				"Timer",
				panel_class,
				[
					Html.heading_c("Timer", "panel-title"),
					# The hero: one big calm countdown, with the run state beside it.
					Html.div_c(
						"flex flex-wrap items-center justify-between gap-3",
						[
							Html.paragraph_s_attrs(ticks.map(phase_text), [Html.class_attr(clock_class), Html.test_id("clock-face")]),
							Html.paragraph_s_attrs(
								run_signal.map(run_text),
								[Html.class_attr_s(run_signal.map(run_badge_class)), Html.test_id("timer-state")],
							),
						],
					),
					Html.paragraph_s_attrs(attached.map(attached_text), [Html.class_attr(muted_class), Html.test_id("attached-project")]),
					Html.div_c(
						toolbar_class,
						[
							Html.button_s_c(run_signal.map(start_label), "button-primary", run.on_unit(toggle_run)),
							Html.action_button_c(
								Signal.const("Reset timer"),
								run_signal.map(is_idle),
								"button",
								run.on_unit(|_| RunState.Idle),
							),
						],
					),
					Html.paragraph_c(
						"Pausing voids the block in progress: a pomodoro is indivisible. Resuming starts a fresh block.",
						hint_class,
					),
				].concat(extras),
			),
			Html.section_c(
				"Projects",
				panel_class,
				[
					Html.heading_c("Projects", "panel-title"),
					Ui.when(
						projects.map(|list| list.is_empty()),
						|| Html.paragraph_c("No projects in the ledger yet.", "empty-state"),
						|| Ui.each_str(projects, |p| p.id, |key, item| render_row(attach, ledger, live, key, item)),
					),
				],
			),
			Html.section_c(
				"Today",
				panel_class,
				[
					Html.heading_c("Today", "panel-title"),
					Html.div_c(
						"stat-grid",
						[
							stat_tile("blocks-logged", "Blocks logged today", projects.map(|list| logged_blocks(list).to_str())),
							stat_tile("focus-minutes", "Focus minutes today", rollup.map(|total| total.to_str())),
						],
					),
				],
			),
		],
	)
}

## The row body runs at row mount time, so the ledger state below can start from
## the saved text carried in the row key.
tracker : Ui.State(Str), Ui.State(RunState), Signal.Signal(Str), Str -> Elem
tracker = |attach, run, attached, saved|
	Ui.state(
		decode_ledger(saved),
		|ledger|
			Html.div_c(
				stack_class,
				[
					Ui.when(
						run.signal().map(is_running),
						|| board(attach, run, ledger, attached, Signal.interval(1000), [Ui.on_cleanup(Signal.cleanup("pomodoro clock cleanup"))]),
						|| board(attach, run, ledger, attached, Signal.const(0), []),
					),
					Ui.on_change(ledger.signal(), |projects| Browser.set_local_storage_text(ledger_key, encode_ledger(projects))),
				],
			),
	)

main : () -> Elem
main = ||
	Ui.state(
		"",
		|attach|
			Ui.state(
				RunState.Idle,
				|run| {
					stored_project = Browser.local_storage_text(project_key)
					stored_ledger = Browser.local_storage_text(ledger_key)

					# The user's choice wins; otherwise fall back to what was saved.
					attached = Signal.map2(attach.signal(), stored_project, |draft, saved| if draft == "" { stored_text(saved) } else { draft })

					# One row, keyed by the saved ledger text.
					seed = stored_ledger.map(|saved| [stored_text(saved)])

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Pomodoro Tracker",
								header_class,
								[
									Html.heading_c("Pomodoro Tracker", "app-title"),
									Html.paragraph_c(
										"Attach the timer to a project, run a focus block, then log it. Elapsed time is derived from interval ticks; totals are derived from the ledger.",
										"app-subtitle",
									),
								],
							),
							Ui.each_str(seed, |saved| saved, |saved, _item| tracker(attach, run, attached, saved)),
							Ui.on_change(attached, |value| Browser.set_local_storage_text(project_key, value)),
						],
					)
				},
			),
	)
