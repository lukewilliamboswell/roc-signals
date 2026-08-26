app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Edit
import Markdown
import Outline
import Stats
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# Markdown Editor.
#
# One editable source string feeds four independently derived views:
#
#   source (Ui.state Str)
#     |
#     +-- blocks = map(source, Markdown.parse)
#     |     +-- (1) preview       : each_str over blocks
#     |     +-- headings = map(blocks, Outline.headings)
#     |           +-- (2) outline : map2(headings, numbered) -> each_str
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
sample_document = "# Roc Signals Field Guide\n\nSignals keep the graph alive instead of rebuilding a whole view after every event.\n\n## Getting Started\n\nRun `roc check app.roc` before you build anything larger, then read the guide.\n\n- Read the guide end to end\n- Skim the gallery examples\n  - Live search covers async and cleanup\n- Write the spec first\n\n### Editor Notes\n\nSpecial characters such as * and _ and # stay literal when they are not real markup.\n\nA line that says 2 * 3 = 6 is arithmetic, not emphasis, and [not a link( either.\n\n##### Deep Dive\n\nThis heading skips from level three to level five on purpose.\n\n## Performance\n\n> Keep derived values derived.\n\n```\n# this hash lives inside a fence and is not a heading\n```\n\nUse **map2** for fan-in and `combine` for wide fan-in, and see [the guide](https://example.test/guide) for more."

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
						],
						children: [Html.text_s(label)],
					},
				),
			],
		},
	)
}

editor_panel : Ui.State(Str), Signal.Signal(Str) -> Elem
editor_panel = |source, source_signal|
	Html.section(
		"Editor",
		[Html.attr("data-panel", "editor"), Html.class_attr("grid gap-3 rounded border border-zinc-200 p-4")],
		[
			Html.heading("Editor"),
			Html.textarea_c(
				"Markdown source",
				source_signal,
				"min-h-64 w-full font-mono text-sm",
				source.on_str(|_, value| value),
			),
			Html.div_c(
				"flex flex-wrap gap-2",
				[
					Html.button_c("Load sample document", "rounded border px-2 py-1", source.on_unit(|_| sample_document)),
					Html.button_c("Load document without headings", "rounded border px-2 py-1", source.on_unit(|_| no_heading_document)),
					Html.button_c("Load heading drill", "rounded border px-2 py-1", source.on_unit(|_| heading_drill_document)),
					Html.button_c("Append a word", "rounded border px-2 py-1", source.on_unit(Edit.append_word)),
					Html.button_c("Append a section", "rounded border px-2 py-1", source.on_unit(Edit.append_section)),
					Html.button_c("Move the last section up", "rounded border px-2 py-1", source.on_unit(Edit.move_last_section_up)),
					Html.button_c("Demote the last heading", "rounded border px-2 py-1", source.on_unit(Edit.demote_last_heading)),
					Html.button_c("Remove the last section", "rounded border px-2 py-1", source.on_unit(Edit.remove_last_section)),
					Html.button_c("Clear document", "rounded border px-2 py-1", source.on_unit(|_| "")),
				],
			),
		],
	)

preview_panel : Signal.Signal(List(Markdown.Block)) -> Elem
preview_panel = |blocks| {
	empty = blocks.map(|value| value.is_empty())

	Html.section(
		"Preview",
		[Html.attr("data-panel", "preview"), Html.class_attr("grid gap-3 rounded border border-zinc-200 p-4")],
		[
			Html.heading("Preview"),
			Ui.when(
				empty,
				|| Html.paragraph("Preview is empty: type markdown to see it rendered."),
				|| Markdown.view_blocks(blocks),
			),
		],
	)
}

outline_panel : Signal.Signal(List(Outline.Row)), Ui.State(Bool), Signal.Signal(Bool) -> Elem
outline_panel = |rows, numbered, numbered_signal| {
	empty = rows.map(|value| value.is_empty())

	Html.section(
		"Table of contents",
		[Html.attr("data-panel", "outline"), Html.class_attr("grid gap-3 rounded border border-zinc-200 p-4")],
		[
			Html.heading("Table of contents"),
			Html.checkbox_c("Number the outline", numbered_signal, "mr-2", numbered.on_bool(|_, value| value)),
			Ui.when(
				empty,
				|| Html.paragraph("No headings yet: add a line that starts with a hash."),
				|| Elem.Element(
					{
						tag: "ul",
						attrs: [Html.attr("data-panel", "outline-body"), Html.class_attr("grid gap-1")],
						children: [Ui.each_str(rows, |row| row.key, render_outline_row)],
					},
				),
			),
		],
	)
}

statistics_panel : Signal.Signal(Stats.Counts), Signal.Signal(U64), Signal.Signal(U64), Ui.State(Str), Signal.Signal(Str) -> Elem
statistics_panel = |counts, heading_count, reading, speed, speed_signal| {
	words_text = counts.map(|value| "Words: ${value.words.to_str()}")
	characters_text = counts.map(|value| "Characters: ${value.characters.to_str()}")
	headings_text = heading_count.map(|value| "Headings: ${value.to_str()}")
	reading_text = reading.map(|value| "Reading time: ${value.to_str()} min")

	# Wide fan-in: the raw counts, the heading spine size, and the reading
	# estimate meet in one record-builder signal.
	summary_input : Signal.Signal({ counts : Stats.Counts, headings : U64, minutes : U64 })
	summary_input = { counts, headings: heading_count, minutes: reading }.Signal

	summary_line : Signal.Signal(Str)
	summary_line =
		summary_input.map(
			|value| {
				words = value.counts.words.to_str()
				characters = value.counts.characters.to_str()
				headings = value.headings.to_str()
				minutes = value.minutes.to_str()
				"Summary: ${words} words | ${characters} characters | ${headings} headings | ${minutes} min"
			},
		)

	Html.section(
		"Statistics",
		[Html.attr("data-panel", "statistics"), Html.class_attr("grid gap-2 rounded border border-zinc-200 p-4")],
		[
			Html.heading("Statistics"),
			Html.select_c(
				"Reading speed",
				speed_signal,
				"rounded border px-2 py-1",
				[
					Html.option("100", "Careful (100 wpm)"),
					Html.option("200", "Average (200 wpm)"),
					Html.option("300", "Fast (300 wpm)"),
				],
				speed.on_str(|_, value| value),
			),
			Html.paragraph_s(words_text),
			Html.paragraph_s(characters_text),
			Html.paragraph_s(headings_text),
			Html.paragraph_s(reading_text),
			Html.paragraph_s(summary_line),
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

							Html.section(
								"Markdown Editor",
								[Html.class_attr("grid gap-4")],
								[
									Html.heading("Markdown Editor"),
									Html.paragraph("One source string, four independently derived views."),
									editor_panel(source, source_signal),
									preview_panel(blocks),
									outline_panel(outline_rows, numbered, numbered_signal),
									statistics_panel(counts, heading_count, reading, speed, speed_signal),
								],
							)
						},
					)
				},
			)
		},
	)
