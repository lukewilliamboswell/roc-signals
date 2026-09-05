app [main] { pf: platform "../../platform/main.roc" }

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
#    `Ui.each` row body runs when the row mounts, with the row key in hand -
#    so keying a single row by the saved ledger text lets the state inside it
#    start from saved data. The trade-off is visible in the spec: saving the
#    ledger changes that key, so the ledger scope re-mounts from the saved text.
# 3. Every total on the page is derived. The per-row minutes, the block count and
#    the daily rollup all fan in from the ledger and the clock; nothing is kept
#    in sync by hand.

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
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
project_name = |id|
	match catalogue.find_first(|entry| entry.id == id) {
		Ok(entry) => entry.name
		Err(_) => "none"
	}

## A catalogue id resolves to the display name shown in the row title.
expect project_name("docs") == "Docs pass"

## An unattached timer, whose project id is empty, reads as "none".
expect project_name("") == "none"

# --- storage codec -----------------------------------------------------------

stored_text : Browser.StorageText -> Str
stored_text = |stored|
	match stored {
		StorageValue(value) => value
		_ => ""
	}

## Deliberately lenient: every non-digit byte is dropped before parsing, so a
## corrupt field still reads as a number and a field with no digits reads as `0`.
## Saved ledgers are user-editable text, so this never fails.
parse_u64 : Str -> U64
parse_u64 = |text| {
	digits = Str.from_utf8_lossy(text.to_utf8().keep_if(|byte| byte >= 48 and byte <= 57))
	U64.from_str(digits) ?? 0
}

## A plain digit field parses to its number.
expect parse_u64("2") == 2

## A field with no digits at all reads as zero rather than failing.
expect parse_u64("") == 0

## Non-digit bytes are dropped, so a corrupted field still yields a count.
expect parse_u64("1x2") == 12

second_field : List(Str) -> Str
second_field = |parts| parts.get(1) ?? ""

## `docs=2` is this project's entry when the key before the `=` matches; the
## junk the specs feed us (`bogus`) simply never matches.
is_pair_for : Str, Str -> Bool
is_pair_for = |pair, id| (pair.split_on("=").first() ?? "") == id

blocks_for : List(Str), Str -> U64
blocks_for = |pairs, id|
	match pairs.find_first(|pair| is_pair_for(pair, id)) {
		Ok(pair) => parse_u64(second_field(pair.split_on("=")))
		Err(_) => 0
	}

## A saved ledger yields the block count stored against the matching id.
expect blocks_for(["docs=2", "bogus", "gone=9", "triage=1"], "docs") == 2

## A project absent from the saved ledger starts the day at zero blocks.
expect blocks_for(["docs=2", "bogus", "gone=9", "triage=1"], "api") == 0

decode_ledger : Str -> List(Project)
decode_ledger = |text| {
	pairs = text.split_on(";")
	catalogue.map(|entry| { id: entry.id, name: entry.name, blocks: blocks_for(pairs, entry.id) })
}

encode_ledger : List(Project) -> Str
encode_ledger = |projects| Str.join_with(projects.map(|p| "${p.id}=${p.blocks.to_str()}"), ";")

## The saved text the specs start from decodes to the catalogue in order, and
## re-encodes to the canonical form the spec expects back in storage.
expect encode_ledger(decode_ledger("docs=2;bogus;gone=9;triage=1")) == "api=0;docs=2;triage=1"

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

## Where the cycle currently is. The tag carries the minutes already spent in
## that phase, so the clock face needs no second look at the tick count.
Phase := [Focus(U64), Break(U64), Complete].{
	to_str : Phase -> Str
	to_str = |phase|
		match phase {
			Focus(minutes) => "Focus ${minutes.to_str()}/${focus_len.to_str()} min"
			Break(minutes) => "Break ${minutes.to_str()}/${break_len.to_str()} min"
			Complete => "Cycle complete"
		}
}

## The whole clock face is one pure function of the tick count: classify once,
## then render the tag.
phase_of : U64 -> Phase
phase_of = |ticks|
	if ticks < focus_len {
		Phase.Focus(ticks)
	} else if ticks < focus_len + break_len {
		Phase.Break(ticks - focus_len)
	} else {
		Phase.Complete
	}

phase_text : U64 -> Str
phase_text = |ticks| Phase.to_str(phase_of(ticks))

## A fresh clock shows no focus minutes spent yet.
expect phase_text(0) == "Focus 0/5 min"

## The last tick of the focus block still reads as focus, not break.
expect phase_text(4) == "Focus 4/5 min"

## The tick that fills the focus block rolls the face over to the break.
expect phase_text(5) == "Break 0/2 min"

## Once focus and break are both spent the cycle reports itself complete.
expect phase_text(7) == "Cycle complete"

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

## The handles a row needs, named rather than positional: `attach` and `ledger`
## are both writable state and would otherwise be a transposable pair.
RowCtx : { attach : Ui.State(Str), ledger : Ui.State(List(Project)), live : Signal.Signal(Live) }

render_row : RowCtx, Str, Signal.Signal(Project) -> Elem
render_row = |ctx, key, item| {
	{ attach, ledger, live } = ctx
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

## The three handles that live for the whole page. Grouping them keeps the
## `Ui.State(Str)` and the `Signal.Signal(Str)` from being swapped at a call site.
PageCtx : { attach : Ui.State(Str), run : Ui.State(RunState), attached : Signal.Signal(Str) }

## Everything the board renders from: the page-wide handles, the ledger scope it
## was mounted inside, and whichever clock the run branch chose.
Board : { ctx : PageCtx, ledger : Ui.State(List(Project)), ticks : Signal.Signal(U64) }

board : Board, List(Elem) -> Elem
board = |b, extras| {
	ledger = b.ledger
	ticks = b.ticks
	attach = b.ctx.attach
	# Field access, not `{ attach, run, attached } = b.ctx`: destructuring the
	# record breaks method dispatch downstream. See UPSTREAM_COMPILER_BUGS.md #7.
	run = b.ctx.run
	attached = b.ctx.attached
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
						|| Ui.each(Signal.map(projects, |rows_items| Rows.from_list(rows_items, |p| p.id) ?? crash "duplicate row key"), |each_row| render_row({ attach, ledger, live }, each_row.key(), each_row.signal())),
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
tracker : PageCtx, Str -> Elem
tracker = |ctx, saved|
	Ui.state(
		decode_ledger(saved),
		|ledger|
			Html.div_c(
				stack_class,
				[
					Ui.when(
						ctx.run.signal().map(is_running),
						|| board({ ctx, ledger, ticks: Signal.interval(1000) }, [Ui.on_cleanup(Signal.cleanup("pomodoro clock cleanup"))]),
						|| board({ ctx, ledger, ticks: Signal.const(0) }, []),
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
							Ui.each(Signal.map(seed, |rows_items| Rows.from_list(rows_items, |saved| saved) ?? crash "duplicate row key"), |each_row| tracker({ attach, run, attached }, each_row.key())),
							Ui.on_change(attached, |value| Browser.set_local_storage_text(project_key, value)),
						],
					)
				},
			),
	)
