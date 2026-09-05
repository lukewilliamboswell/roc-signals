app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Edit
import Markdown
import Outline
import Stats
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

# Markdown Editor.
#
# One editable source string feeds four independently derived views:
#
#   source (Ui.state Str)
#     |
#     +-- blocks = map(source, Markdown.parse)
#     |     +-- (1) preview       : Ui.each over blocks
#     |     +-- headings = map(blocks, Outline.headings)
#     |           +-- (2) outline : map2(headings, numbered) -> Ui.each
#     |           +-- heading_count = map(headings, len)
#     |
#     +-- counts = map(source, Stats.counts)
#           +-- (3) word/character readouts
#           +-- reading = map2(counts, words_per_minute)
#                 +-- (4) reading-time readout
#
# The four views cost very different amounts, and none of them is recomputed
# because a sibling changed. Editing a paragraph changes `blocks` and `counts`,
# but `headings` recomputes to an equal value, so the equality cutoff stops
# propagation there and neither `Outline.rows` nor any outline row is touched.
#
# Fan-ins:
#   * outline_rows  = Signal.map2(headings, numbered)
#   * reading       = Signal.map2(counts, words_per_minute)
#   * summary_line  = { counts, headings, minutes }.Signal (record builder)
#
# Chains (source -> ... -> sink):
#   * source -> blocks -> headings -> outline_rows -> row label   (4 hops)
#   * source -> counts -> reading -> summary_line                 (3 hops)

sample_document : Str
sample_document = "# Roc Signals Field Guide\n\nSignals keep the graph alive instead of rebuilding a whole view after every event.\n\n## Getting Started\n\nRun `roc check main.roc` before you build anything larger, then read the guide.\n\n- Read the guide end to end\n- Skim the gallery examples\n  - Live search covers async and cleanup\n- Write the spec first\n\n### Editor Notes\n\nSpecial characters such as * and _ and # stay literal when they are not real markup.\n\nA line that says 2 * 3 = 6 is arithmetic, not emphasis, and [not a link( either.\n\n##### Deep Dive\n\nThis heading skips from level three to level five on purpose.\n\n## Performance\n\n> Keep derived values derived.\n\n```\n# this hash lives inside a fence and is not a heading\n```\n\nUse **map2** for fan-in and `combine` for wide fan-in, and see [the guide](https://example.test/guide) for more."

no_heading_document : Str
no_heading_document = "Just a paragraph with no headings at all.\n\nAnd a second paragraph so the preview has something to show."

heading_drill_document : Str
heading_drill_document = "# Alpha\n\n## Beta\n\n## Gamma\n\n## Delta"

render_outline_row : Str, Signal.Signal(Outline.Row) -> Elem
render_outline_row = |key, row| {
	label = row.map(|value| value.label)
	level_text = row.map(|value| value.level_text)
	indent = row.map(|value| value.indent)
	href = row.map(|value| value.href)

	Elem.Element(
		{
			tag: "li",
			attrs: [Html.class_attr_s(indent)],
			children: [
				Elem.Element(
					{
						tag: "a",
						attrs: [
							Html.test_id(key),
							Html.attr_s("href", href),
							Html.attr_s("data-level", level_text),
							Html.class_attr("block rounded px-2 py-1 text-sm text-zinc-700 transition hover:bg-zinc-100 hover:text-emerald-700"),
						],
						children: [Html.text_s(label)],
					},
				),
			],
		},
	)
}

## A labelled group of document buttons. The editor has nine commands, which is
## too many for one undifferentiated row, so they are split by what they do.
button_group : Str, List(Elem) -> Elem
button_group = |caption, buttons|
	Html.div_c(
		"grid gap-2",
		[
			Html.paragraph_c(caption, "hint"),
			Html.div_c("toolbar", buttons),
		],
	)

## One metric tile. The test id sits on the value, not on a sentence, so the
## spec asserts the number the reader actually sees.
stat_tile : Str, Str, Signal.Signal(Str) -> Elem
stat_tile = |caption, id, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(caption, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value numeric")]),
		],
	)

editor_panel : Ui.State(Str), Signal.Signal(Str) -> Elem
editor_panel = |source, source_signal|
	Html.section(
		"Editor",
		[Html.attr("data-panel", "editor"), Html.class_attr("panel flex flex-col")],
		[
			Html.div_c("panel-head", [Html.heading_c("Editor", "panel-title")]),
			Html.div_c(
				"panel-body content-start",
				[
					Html.div_c(
						"field",
						[
							Html.paragraph_c("Markdown source", "field-label"),
							Html.textarea_c(
								"Markdown source",
								source_signal,
								"input textarea font-mono min-h-96 text-sm",
								source.on_str(|_, value| value),
							),
							Html.paragraph_c("Headings, lists, fenced code, quotes, and links all render live in the preview.", "hint"),
						],
					),
					button_group(
						"Documents",
						[
							Html.button_c("Load sample document", "button button-primary button-sm", source.on_unit(|_| sample_document)),
							Html.button_c("Load document without headings", "button button-sm", source.on_unit(|_| no_heading_document)),
							Html.button_c("Load heading drill", "button button-sm", source.on_unit(|_| heading_drill_document)),
						],
					),
					button_group(
						"Edit the document",
						[
							Html.button_c("Append a word", "button button-sm", source.on_unit(Edit.append_word)),
							Html.button_c("Append a section", "button button-sm", source.on_unit(Edit.append_section)),
							Html.button_c("Move the last section up", "button button-sm", source.on_unit(Edit.move_last_section_up)),
							Html.button_c("Demote the last heading", "button button-sm", source.on_unit(Edit.demote_last_heading)),
							Html.button_c("Remove the last section", "button button-sm", source.on_unit(Edit.remove_last_section)),
							Html.button_c("Clear document", "button-danger button-sm", source.on_unit(|_| "")),
						],
					),
				],
			),
		],
	)

preview_panel : Signal.Signal(List(Markdown.Block)) -> Elem
preview_panel = |blocks| {
	empty = blocks.map(|value| value.is_empty())

	Html.section(
		"Preview",
		[Html.attr("data-panel", "preview"), Html.class_attr("panel flex flex-col")],
		[
			Html.div_c("panel-head", [Html.heading_c("Preview", "panel-title")]),
			Html.div_c(
				"panel-body content-start",
				[
					Ui.when(
						empty,
						|| Html.paragraph_c("Preview is empty: type markdown to see it rendered.", "empty-state"),
						|| Markdown.view_blocks(blocks),
					),
				],
			),
		],
	)
}

outline_panel : Signal.Signal(List(Outline.Row)), Ui.State(Bool), Signal.Signal(Bool) -> Elem
outline_panel = |rows, numbered, numbered_signal| {
	empty = rows.map(|value| value.is_empty())

	Html.section(
		"Table of contents",
		[Html.attr("data-panel", "outline"), Html.class_attr("panel")],
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Table of contents", "panel-title"),
					Html.div_c(
						"check-row",
						[
							Html.checkbox_c("Number the outline", numbered_signal, "checkbox", numbered.on_bool(|_, value| value)),
							Html.paragraph_c("Number the outline", ""),
						],
					),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Ui.when(
						empty,
						|| Html.paragraph_c("No headings yet: add a line that starts with a hash.", "empty-state"),
						|| Elem.Element(
							{
								tag: "ul",
								attrs: [Html.attr("data-panel", "outline-body"), Html.class_attr("grid gap-0.5")],
								children: [Ui.each(Signal.map(rows, |rows_items| Rows.from_list(rows_items, |row| row.key) ?? crash "duplicate row key"), |each_row| render_outline_row(each_row.key(), each_row.signal()))],
							},
						),
					),
				],
			),
		],
	)
}

## The four inputs of the statistics panel. `heading_count` and `minutes` are
## both `Signal(U64)`, so they travel in a named record rather than as adjacent
## positional arguments a caller could silently transpose.
StatisticsInputs : {
	counts : Signal.Signal(Stats.Counts),
	heading_count : Signal.Signal(U64),
	minutes : Signal.Signal(U64),
	speed : Ui.State(Str),
	speed_signal : Signal.Signal(Str),
}

statistics_panel : StatisticsInputs -> Elem
statistics_panel = |{ counts, heading_count, minutes, speed, speed_signal }| {
	words_text = counts.map(|value| value.words.to_str())
	characters_text = counts.map(|value| value.characters.to_str())
	headings_text = heading_count.map(|value| value.to_str())
	reading_text = minutes.map(|value| "${value.to_str()} min")

	# Wide fan-in: the raw counts, the heading spine size, and the reading
	# estimate meet in one record-builder signal.
	summary_input : Signal.Signal({ counts : Stats.Counts, headings : U64, minutes : U64 })
	summary_input = { counts, headings: heading_count, minutes }.Signal

	summary_line : Signal.Signal(Str)
	summary_line =
		summary_input.map(
			|value| {
				words = value.counts.words.to_str()
				characters = value.counts.characters.to_str()
				headings = value.headings.to_str()
				estimate = value.minutes.to_str()
				"${words} words | ${characters} characters | ${headings} headings | ${estimate} min"
			},
		)

	Html.section(
		"Statistics",
		[Html.attr("data-panel", "statistics"), Html.class_attr("panel")],
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Statistics", "panel-title"),
					Html.paragraph_s_attrs(summary_line, [Html.test_id("stat-summary"), Html.class_attr("hint numeric")]),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.div_c(
						"stat-grid",
						[
							stat_tile("Words", "stat-words", words_text),
							stat_tile("Characters", "stat-characters", characters_text),
							stat_tile("Headings", "stat-headings", headings_text),
							stat_tile("Reading time", "stat-reading", reading_text),
						],
					),
					Html.div_c(
						"field sm:max-w-xs",
						[
							Html.paragraph_c("Reading speed", "field-label"),
							Html.select_c(
								"Reading speed",
								speed_signal,
								"input",
								[
									Html.option("100", "Careful (100 wpm)"),
									Html.option("200", "Average (200 wpm)"),
									Html.option("300", "Fast (300 wpm)"),
								],
								speed.on_str(|_, value| value),
							),
							Html.paragraph_c("The estimate is a fan-in of the word count and this speed; it never touches the preview or the outline.", "hint"),
						],
					),
				],
			),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		sample_document,
		|source| {
			source_signal : Signal.Signal(Str)
			source_signal = source.signal()

			# One parse, shared by the preview and the outline.
			blocks : Signal.Signal(List(Markdown.Block))
			blocks = source_signal.map(Markdown.parse)

			# Cheap branch: raw-source statistics, independent of the parse.
			counts : Signal.Signal(Stats.Counts)
			counts = source_signal.map(Stats.counts)

			# Second hop: the heading spine. Equal spines cut off here.
			headings : Signal.Signal(List(Outline.Heading))
			headings = blocks.map(Outline.headings)

			heading_count : Signal.Signal(U64)
			heading_count = headings.map(|value| value.len())

			Ui.state(
				True,
				|numbered| {
					numbered_signal = numbered.signal()

					# Fan-in: the heading spine and the numbering toggle.
					outline_rows : Signal.Signal(List(Outline.Row))
					outline_rows = Signal.map2(headings, numbered_signal, Outline.rows)

					Ui.state(
						"200",
						|speed| {
							speed_signal = speed.signal()

							words_per_minute : Signal.Signal(U64)
							words_per_minute = speed_signal.map(Stats.parse_wpm)

							# Fan-in: document counts and the reading speed.
							reading : Signal.Signal(U64)
							reading =
								Signal.map2(
									counts,
									words_per_minute,
									|value, wpm| Stats.reading_minutes(value.words, wpm),
								)

							Html.div_c(
								"app-shell app-shell-wide",
								[
									Html.section_c(
										"Markdown Editor",
										"app-header",
										[
											Html.heading_c("Markdown Editor", "app-title"),
											Html.paragraph_c("One source string, four independently derived views.", "app-subtitle"),
										],
									),
									statistics_panel({ counts, heading_count, minutes: reading, speed, speed_signal }),
									Html.div_c(
										"grid gap-6 lg:grid-cols-2",
										[
											editor_panel(source, source_signal),
											preview_panel(blocks),
										],
									),
									outline_panel(outline_rows, numbered, numbered_signal),
								],
							)
						},
					)
				},
			)
		},
	)
