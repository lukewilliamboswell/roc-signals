app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

## Log Viewer — a streaming console built from one interval and six toggles.
##
## The buffer is not stored. `Signal.interval(1000)` counts ticks and the whole
## line list is *derived* from that count, so there is no append reducer and no
## retained list to keep in step with the filters.
##
## The signal graph:
##
##     interval ──> all_lines ─┬─> visible ──> ordered ──> each_str (rows)
##                             │      │
##     4 level toggles ──> levels ─────┤        └─> match_count / tail / stats
##     query ─────────────────────────┘
##
## `levels` and `query` fan in to the one `visible` signal via a record-builder
## `.Signal`, so a level toggle and a query edit take the same path. `ordered`
## only reverses; it never rebuilds, which is what lets the row list move rows
## instead of recreating them.
##
## Two things worth noticing in the view layer:
##
##   * A row's timestamp and level tag are derived from its *key*, not from the
##     row signal, so they are static nodes. Appending a line therefore patches
##     one new row and nothing else.
##   * The level colour and the level text come from the same `level` value, so
##     a row can never show `ERROR` in the info colour.

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# --- classes -----------------------------------------------------------------

page_class : Str
page_class = "app-shell app-shell-wide"

panel_class : Str
panel_class = "panel grid gap-4 p-4"

## The one dark surface in the gallery: a log console is expected to look like
## a terminal, and the levels need a dark ground to read against.
stream_class : Str
stream_class = "grid gap-0.5 overflow-y-auto rounded-lg border border-zinc-800 bg-zinc-950 p-3 font-mono text-xs text-zinc-100 max-h-[28rem]"

# --- domain ------------------------------------------------------------------

LogLine : { id : Str, index : U64, level : U64, text : Str }

VisibleLine : { id : Str, text : Str, matched : Bool }

level_name : U64 -> Str
level_name = |code|
	if code == 0 {
		"debug"
	} else if code == 1 {
		"info"
	} else if code == 2 {
		"warn"
	} else {
		"error"
	}

## The tag drawn in the stream. Same source value as `level_name`, uppercased
## for the fixed-width column.
level_tag : U64 -> Str
level_tag = |code|
	if code == 0 {
		"DEBUG"
	} else if code == 1 {
		"INFO"
	} else if code == 2 {
		"WARN"
	} else {
		"ERROR"
	}

## Colour is derived from the same `level` the tag is, so the two cannot
## disagree. Full class strings, because Tailwind scans this file literally.
level_tag_class : U64 -> Str
level_tag_class = |code|
	if code == 0 {
		"w-14 shrink-0 font-semibold text-zinc-500"
	} else if code == 1 {
		"w-14 shrink-0 font-semibold text-emerald-400"
	} else if code == 2 {
		"w-14 shrink-0 font-semibold text-amber-400"
	} else {
		"w-14 shrink-0 font-semibold text-red-400"
	}

## The message tints with the level too, but far more gently: the tag carries
## the signal, the message carries the words.
level_text_class : U64 -> Str
level_text_class = |code|
	if code == 0 {
		"min-w-0 flex-1 text-zinc-400"
	} else if code == 1 {
		"min-w-0 flex-1 text-zinc-100"
	} else if code == 2 {
		"min-w-0 flex-1 text-amber-200"
	} else {
		"min-w-0 flex-1 text-red-200"
	}

message_text : U64 -> Str
message_text = |slot|
	if slot == 0 {
		"cache warmed"
	} else if slot == 1 {
		"request handled"
	} else if slot == 2 {
		"disk pressure rising"
	} else if slot == 3 {
		"upstream timeout"
	} else if slot == 4 {
		"config reloaded"
	} else {
		"session expired"
	}

make_line : U64 -> LogLine
make_line = |index| {
	level = index % 4
	name = level_name(level)
	message = message_text(index % 6)
	number = index.to_str()

	{
		id: "line-${number}",
		index,
		level,
		text: "[${number}] ${name} ${message}",
	}
}

build_lines_from : U64, U64, List(LogLine) -> List(LogLine)
build_lines_from = |index, count, acc|
	if index > count {
		acc
	} else {
		build_lines_from(index + 1, count, acc.append(make_line(index)))
	}

build_lines : U64 -> List(LogLine)
build_lines = |count| build_lines_from(1, count, [])

contains_text : Str, Str -> Bool
contains_text = |haystack, needle|
	if needle.is_empty() {
		False
	} else {
		haystack.split_on(needle).len() > 1
	}

level_enabled : List(Bool), U64 -> Bool
level_enabled = |levels, code|
	match levels.get(code) {
		Ok(flag) => flag
		Err(_) => False
	}

select_lines : List(LogLine), List(Bool), Str -> List(VisibleLine)
select_lines = |lines, levels, query|
	lines
		.keep_if(|line| level_enabled(levels, line.level))
		.map(
			|line| {
				id: line.id,
				text: line.text,
				matched: contains_text(line.text, query),
			},
		)

match_count : List(VisibleLine) -> U64
match_count = |lines| lines.keep_if(|line| line.matched).len()

## Errors currently on screen, counted from the buffer rather than the visible
## set so the level filter is what decides whether they count.
error_count : List(LogLine), List(Bool) -> U64
error_count = |lines, levels|
	if level_enabled(levels, 3) {
		lines.keep_if(|line| line.level == 3).len()
	} else {
		0
	}

## The pinned latest line. It is drawn in a box already captioned "Latest", so
## it carries the line and nothing else.
tail_text : List(VisibleLine) -> Str
tail_text = |lines|
	if lines.is_empty() {
		"waiting for the first line"
	} else {
		match lines.get(lines.len() - 1) {
			Ok(line) => line.text
			Err(_) => "waiting for the first line"
		}
	}

reverse_from : List(VisibleLine), U64, List(VisibleLine) -> List(VisibleLine)
reverse_from = |lines, index, acc|
	if index == 0 {
		acc
	} else {
		match lines.get(index - 1) {
			Ok(line) => reverse_from(lines, index - 1, acc.append(line))
			Err(_) => acc
		}
	}

reverse_lines : List(VisibleLine) -> List(VisibleLine)
reverse_lines = |lines| reverse_from(lines, lines.len(), [])

# --- row rendering -----------------------------------------------------------

digits_to_u64 : Str -> U64
digits_to_u64 = |text|
	text.to_utf8().fold(
		0,
		|acc, byte|
			if byte >= 48 and byte <= 57 {
				acc * 10 + (U8.to_u64(byte) - 48)
			} else {
				acc
			},
	)

pad2 : U64 -> Str
pad2 = |value| if value < 10 { "0${value.to_str()}" } else { value.to_str() }

## One wall-clock second per tick, starting at 09:14:00, so the column looks
## like a real service log rather than a counter.
clock_text : U64 -> Str
clock_text = |index| {
	total = 33240 + index
	"${pad2((total // 3600) % 24)}:${pad2((total // 60) % 60)}:${pad2(total % 60)}"
}

## A matched row lifts off the ground instead of announcing itself in words.
row_class_for : VisibleLine -> Str
row_class_for = |line|
	if line.matched {
		"flex items-baseline gap-3 rounded bg-emerald-500/10 px-2 py-1 ring-1 ring-emerald-500/30"
	} else {
		"flex items-baseline gap-3 rounded px-2 py-1 hover:bg-zinc-900"
	}

## The timestamp and the level tag are computed from the row *key*, which
## already carries the line number, so they are static nodes: appending a line
## patches the one new row and touches nothing else.
##
## Query matching is shown by the row's wash and published on `data-match`, so
## nothing has to print "match: yes" into a console the user is reading.
render_row : Str, Signal.Signal(VisibleLine) -> Elem
render_row = |key, line| {
	index = digits_to_u64(key)
	level = index % 4
	line_text = line.map(|value| value.text)
	match_flag = line.map(|value| if value.matched { "yes" } else { "no" })

	Html.section(
		"Log ${key}",
		[
			Html.class_attr_s(line.map(row_class_for)),
			Html.attr_s("data-match", match_flag),
			Html.test_id("match-${key}"),
		],
		[
			Html.paragraph_c(clock_text(index), "shrink-0 tabular-nums text-zinc-500"),
			Html.paragraph_c(level_tag(level), level_tag_class(level)),
			Html.paragraph_s_attrs(line_text, [Html.class_attr(level_text_class(level)), Html.test_id("text-${key}")]),
		],
	)
}

# --- stream ------------------------------------------------------------------

stat : Str, Signal.Signal(Str) -> Elem
stat = |label, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_c(value, "stat-value"),
		],
	)

stream_panel : Signal.Signal(List(Bool)), Signal.Signal(Str), Signal.Signal(Bool), Signal.Signal(Bool) -> Elem
stream_panel = |levels, query, follow_tail, newest_first| {
	ticks = Signal.interval(1000)

	all_lines : Signal.Signal(List(LogLine))
	all_lines = ticks.map(build_lines)

	# Fan-in: the streamed buffer, the four level toggles, and the query all
	# feed the one derived visible-set signal.
	filters = { levels: levels, query: query }.Signal

	visible : Signal.Signal(List(VisibleLine))
	visible =
		Signal.map2(
			all_lines,
			filters,
			|lines, active| select_lines(lines, active.levels, active.query),
		)

	summary_text =
		Signal.map2(
			all_lines,
			visible,
			|lines, shown| "Showing ${shown.len().to_str()} of ${lines.len().to_str()} lines",
		)

	ordered : Signal.Signal(List(VisibleLine))
	ordered =
		Signal.map2(
			visible,
			newest_first,
			|lines, flip| if flip { reverse_lines(lines) } else { lines },
		)

	order_text = newest_first.map(|flip| if flip { "Order: newest first" } else { "Order: oldest first" })
	matches_text = visible.map(|lines| "Query matches: ${match_count(lines).to_str()}")
	has_lines = visible.map(|lines| !lines.is_empty())
	no_matches =
		Signal.map2(visible, query, |shown, text| (!text.is_empty()) and match_count(shown) == 0)

	shown_count = visible.map(|lines| lines.len().to_str())
	buffered_count = all_lines.map(|lines| lines.len().to_str())
	dropped_count = Signal.map2(all_lines, visible, |lines, shown| (lines.len() - shown.len()).to_str())
	errors_count = Signal.map2(all_lines, levels, |lines, active| error_count(lines, active).to_str())

	# The badge text and its colour come off the one `follow_tail` signal.
	status_text = follow_tail.map(|on| if on { "Live" } else { "Paused" })
	status_class = follow_tail.map(|on| if on { "badge badge-ok" } else { "badge badge-warn" })

	Html.section_c(
		"Log stream",
		"panel",
		[
			Html.div_c(
				"panel-head",
				[
					Html.div_c(
						"flex flex-wrap items-center gap-2",
						[
							Html.paragraph_c("Log stream", "panel-title"),
							Html.paragraph_s_attrs(status_text, [Html.class_attr_s(status_class)]),
							Html.paragraph_s_attrs(order_text, [Html.class_attr("badge badge-neutral"), Html.test_id("order-mode")]),
						],
					),
					Html.div_c(
						"flex flex-wrap items-center gap-3",
						[
							Html.paragraph_s_attrs(summary_text, [Html.class_attr("hint numeric"), Html.test_id("line-count")]),
							Html.paragraph_s_attrs(matches_text, [Html.class_attr("hint numeric"), Html.test_id("query-matches")]),
						],
					),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.div_c(
						"stat-grid",
						[
							stat("Lines shown", shown_count),
							stat("Lines dropped", dropped_count),
							stat("Errors", errors_count),
							stat("Buffered", buffered_count),
						],
					),
					Ui.when(
						no_matches,
						|| Html.paragraph_attrs("No lines match the query.", [Html.class_attr("notice notice-warn"), Html.test_id("query-note")]),
						|| Html.paragraph_attrs("Query filter idle.", [Html.class_attr("hint"), Html.test_id("query-note")]),
					),
					# A one-line pinned readout, so the newest line stays in view once
					# the console below has scrolled away from it.
					Ui.when(
						follow_tail,
						|| Html.section_c(
							"Tail",
							"flex items-baseline gap-3 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2",
							[
								Html.paragraph_c("Latest", "stat-label shrink-0"),
								Html.paragraph_s_attrs(visible.map(tail_text), [Html.class_attr("min-w-0 truncate font-mono text-xs text-zinc-800"), Html.test_id("tail-line")]),
							],
						),
						|| Html.section_c(
							"Tail paused",
							"flex items-baseline gap-3 rounded-md border border-dashed border-zinc-300 px-3 py-2",
							[
								Html.paragraph_c("Latest", "stat-label shrink-0"),
								Html.paragraph_c("Follow tail is off", "hint"),
							],
						),
					),
					Ui.when(
						has_lines,
						|| Html.section_c("Log lines", stream_class, [Ui.each_str(ordered, |line| line.id, render_row)]),
						|| Html.section_c("Log empty", "grid gap-2", [Html.paragraph_c("Log buffer is empty", "empty-state")]),
					),
					Ui.on_cleanup(Signal.cleanup("log stream cleanup")),
				],
			),
		],
	)
}

# --- controls ----------------------------------------------------------------

## Checkboxes are bare inputs, so the visible caption is drawn beside them here.
check_row : Str, Signal.Signal(Bool), _ -> Elem
check_row = |label, checked, msg|
	Html.div_c(
		"check-row",
		[
			Html.checkbox_c(label, checked, "checkbox", msg),
			Html.text(label),
		],
	)

page : Ui.State(Bool), Ui.State(Bool), Ui.State(Bool), Ui.State(Bool), Ui.State(Str), Ui.State(Bool), Ui.State(Bool), Ui.State(Bool) -> Elem
page = |show_debug, show_info, show_warn, show_error, query, follow_tail, newest_first, epoch| {
	# Four independent level toggles fan in to one list-of-flags signal via the
	# record-builder `.Signal`.
	level_flags =
		{
			debug: show_debug.signal(),
			info: show_info.signal(),
			warn: show_warn.signal(),
			error: show_error.signal(),
		}.Signal
	levels = level_flags.map(|flags| [flags.debug, flags.info, flags.warn, flags.error])
	query_signal = query.signal()
	follow_signal = follow_tail.signal()
	newest_signal = newest_first.signal()

	Html.div_c(
		page_class,
		[
			Html.section_c(
				"Log Viewer",
				"app-header",
				[
					Html.heading_c("Log Viewer", "app-title"),
					Html.paragraph_c(
						"A line arrives every second. Filter by level, search the stream, follow the tail, flip the order, or clear the buffer and start the clock again.",
						"app-subtitle",
					),
				],
			),
			Html.section_c(
				"Log controls",
				panel_class,
				[
					Html.div_c(
						"toolbar",
						[
							Html.div_c(
								"field min-w-[16rem] flex-1",
								[
									Html.paragraph_c("Search", "field-label"),
									Html.text_input_attrs(
										"Query",
										query_signal,
										[Html.class_attr("input"), Html.attr("placeholder", "upstream timeout")],
										query.on_str(|_, value| value),
									),
									Html.paragraph_c("Matching lines are highlighted in the stream.", "hint"),
								],
							),
							Html.div_c(
								"field",
								[
									Html.paragraph_c("Levels", "field-label"),
									Html.div_c(
										"flex flex-wrap items-center gap-3",
										[
											check_row("Show debug", show_debug.signal(), show_debug.on_bool(|_, value| value)),
											check_row("Show info", show_info.signal(), show_info.on_bool(|_, value| value)),
											check_row("Show warn", show_warn.signal(), show_warn.on_bool(|_, value| value)),
											check_row("Show error", show_error.signal(), show_error.on_bool(|_, value| value)),
										],
									),
								],
							),
							Html.div_c(
								"field",
								[
									Html.paragraph_c("Stream", "field-label"),
									Html.div_c(
										"flex flex-wrap items-center gap-3",
										[
											check_row("Follow tail", follow_signal, follow_tail.on_bool(|_, value| value)),
											check_row("Newest first", newest_signal, newest_first.on_bool(|_, value| value)),
										],
									),
								],
							),
							Html.div_c(
								"field",
								[
									Html.paragraph_c("Buffer", "field-label"),
									Html.button_c("Clear log", "button-danger", epoch.on_unit(|value| !value)),
								],
							),
						],
					),
				],
			),
			# The buffer is derived from the tick count, so "clear" means "rewind
			# the clock": flipping this flag disposes the mounted stream scope and
			# its interval and mounts a fresh one, whose interval starts again at
			# zero. The control state above the branch survives the clear.
			#
			# `State.set_cmd` now lets a signal change write retained state, so the
			# buffer could be a `Ui.state(List(LogLine))` fed by
			# `Ui.on_change(ticks, ...)`. It is not, because appending needs the
			# buffer's current value and the `on_change` callback only receives the
			# signal's value - so a retained buffer would still have to rebuild
			# itself from the tick count, and would trade one derived signal for a
			# state plus a write hook.
			Ui.when(
				epoch.signal(),
				|| stream_panel(levels, query_signal, follow_signal, newest_signal),
				|| stream_panel(levels, query_signal, follow_signal, newest_signal),
			),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		True,
		|show_debug|
			Ui.state(
				True,
				|show_info|
					Ui.state(
						True,
						|show_warn|
							Ui.state(
								True,
								|show_error|
									Ui.state(
										"",
										|query|
											Ui.state(
												True,
												|follow_tail|
													Ui.state(
														False,
														|newest_first|
															Ui.state(
																True,
																|epoch| page(show_debug, show_info, show_warn, show_error, query, follow_tail, newest_first, epoch),
															),
													),
											),
									),
							),
					),
			),
	)
