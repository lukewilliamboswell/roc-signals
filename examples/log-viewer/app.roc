app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

row_class = "grid gap-1 rounded border border-zinc-200 p-2"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

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

tail_text : List(VisibleLine) -> Str
tail_text = |lines|
	if lines.is_empty() {
		"Tail: waiting for the first line"
	} else {
		match lines.get(lines.len() - 1) {
			Ok(line) => "Tail: ${line.text}"
			Err(_) => "Tail: waiting for the first line"
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

render_row : Str, Signal.Signal(VisibleLine) -> Elem
render_row = |key, line| {
	line_text = line.map(|value| value.text)
	marker_text =
		line.map(
			|value|
				if value.matched {
					"${value.id} match: yes"
				} else {
					"${value.id} match: no"
				},
		)

	Html.section_c(
		"Log ${key}",
		row_class,
		[
			Html.paragraph_s_c(line_text, "font-mono text-sm text-zinc-900"),
			Html.paragraph_s_c(marker_text, "text-xs text-zinc-600"),
		],
	)
}

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

	Html.section_c(
		"Log stream",
		panel_class,
		[
			Html.paragraph_s_c(summary_text, "text-sm font-medium text-zinc-900"),
			Html.paragraph_s_c(matches_text, "text-sm text-zinc-700"),
			Html.paragraph_s_c(order_text, "text-sm text-zinc-700"),
			Ui.when(
				no_matches,
				|| Html.paragraph_c("No lines match the query.", "text-sm text-amber-800"),
				|| Html.paragraph_c("Query filter idle.", "text-sm text-zinc-600"),
			),
			Ui.when(
				follow_tail,
				|| Html.section_c("Tail", panel_class, [Html.paragraph_s_c(visible.map(tail_text), "font-mono text-sm text-zinc-900")]),
				|| Html.section_c("Tail paused", panel_class, [Html.paragraph("Follow tail is off")]),
			),
			Ui.when(
				has_lines,
				|| Html.section_c("Log lines", "grid gap-2", [Ui.each_str(ordered, |line| line.id, render_row)]),
				|| Html.section_c("Log empty", "grid gap-2", [Html.paragraph("Log buffer is empty")]),
			),
			Ui.on_cleanup(Signal.cleanup("log stream cleanup")),
		],
	)
}

page : Ui.State(Bool), Ui.State(Bool), Ui.State(Bool), Ui.State(Bool), Ui.State(Str), Ui.State(Bool), Ui.State(Bool), Ui.State(Bool) -> Elem
page = |show_debug, show_info, show_warn, show_error, query, follow_tail, newest_first, epoch| {
	# Four independent level toggles fan in to one list-of-flags signal.
	# `Signal.combine` cannot be used here: it reads every input through the
	# first input's capability, which fails for sources that own separate
	# capabilities.
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
				hero_class,
				[
					Html.heading_c("Log Viewer", "text-3xl font-semibold text-zinc-950"),
					Html.paragraph_c("Stream log lines on an interval, filter by level, highlight query matches, follow the tail, pin rows, and clear the buffer.", "max-w-3xl text-sm text-zinc-700"),
				],
			),
			Html.section_c(
				"Log controls",
				panel_class,
				[
					Html.div_c(
						toolbar_class,
						[
							Html.checkbox("Show debug", show_debug.signal(), show_debug.on_bool(|_, value| value)),
							Html.checkbox("Show info", show_info.signal(), show_info.on_bool(|_, value| value)),
							Html.checkbox("Show warn", show_warn.signal(), show_warn.on_bool(|_, value| value)),
							Html.checkbox("Show error", show_error.signal(), show_error.on_bool(|_, value| value)),
							Html.checkbox("Follow tail", follow_signal, follow_tail.on_bool(|_, value| value)),
							Html.checkbox("Newest first", newest_signal, newest_first.on_bool(|_, value| value)),
						],
					),
					Html.text_input_c("Query", query_signal, input_class, query.on_str(|_, value| value)),
					Html.button_c("Clear log", "button justify-self-start", epoch.on_unit(|value| !value)),
				],
			),
			# Clearing flips this flag, disposing the mounted stream scope and its
			# interval, and mounting a fresh one with an empty buffer. The control
			# state above the branch survives the clear.
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
