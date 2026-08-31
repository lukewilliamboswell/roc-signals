app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal exposing [Signal]
import pf.Ui

import GridData

# ---------------------------------------------------------------------------
# Classes
# ---------------------------------------------------------------------------

page_class : Str
page_class = "app-shell app-shell-wide"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

## The platform has no `table`/`tr`/`td` helpers, so the grid is a CSS grid that
## borrows the `data-table` treatment: one shared column template keeps the
## header strip and every row on the same tracks.
grid_cols_class : Str
grid_cols_class = "grid grid-cols-[2.5rem_minmax(0,1.2fr)_minmax(0,0.8fr)_minmax(0,0.6fr)_minmax(0,1.6fr)] items-center gap-3"

header_row_class : Str
header_row_class = "${grid_cols_class} border-b border-zinc-200 bg-zinc-50 px-3 py-2"

header_cell_class : Str
header_cell_class = "text-xs font-semibold uppercase tracking-wide text-zinc-500"

row_class : Str
row_class = "${grid_cols_class} border-b border-zinc-100 px-3 py-2"

cell_class : Str
cell_class = "text-sm text-zinc-800"

numeric_cell_class : Str
numeric_cell_class = "text-sm text-zinc-800 numeric text-right"

input_class : Str
input_class = "input"

sort_button_class : Str
sort_button_class = "button button-sm"

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

## The column headings of the grid. Static, so it renders once and is never
## touched by a signal update.
grid_header : Elem
grid_header =
	Html.div_c(
		header_row_class,
		[
			Html.paragraph_c("Select", header_cell_class),
			Html.paragraph_c("Name", header_cell_class),
			Html.paragraph_c("Team", header_cell_class),
			Html.paragraph_c("Score", "${header_cell_class} text-right"),
			Html.paragraph_c("Note", header_cell_class),
		],
	)

## One row. The selection reducer writes only the `selected` handle now that it
## no longer has to carry the query along.
render_row : Ui.State(List(U64)), Ui.State(List(GridData.Note)), Str, Signal(GridData.ViewRow) -> Elem
render_row = |selected, notes, _, row| {
	Ui.switch(
		row.map(|current| current.id),
		|row_id| {
			key = row_id.to_str()
			name = "Node-${GridData.pad4(row_id)}"

			Html.div_c(
				row_class,
				[
					Html.checkbox_c(
						"Select ${name}",
						row.map(|r| r.selected),
						"checkbox",
						selected.on_bool(|current, on| GridData.toggle_selected(current, row_id, on)),
					),
					Html.paragraph_s_attrs(row.map(|r| r.name), [Html.class_attr("${cell_class} font-medium numeric"), Html.test_id("row-name-${key}")]),
					Html.paragraph_s_attrs(row.map(|r| r.team), [Html.class_attr(cell_class), Html.test_id("row-team-${key}")]),
					Html.paragraph_s_attrs(row.map(|r| r.score.to_str()), [Html.class_attr(numeric_cell_class), Html.test_id("row-score-${key}")]),
					Html.text_input_attrs(
						"Note for ${name}",
						row.map(|r| r.note),
						[Html.class_attr(input_class), Html.attr("placeholder", "e.g. needs review")],
						notes.on_str(|current, value| GridData.set_note(current, row_id, value)),
					),
				],
			)
		},
	)
}

## A metric tile: a static caption over the live figure. The `test_id` rides on
## the number, so a spec asserts the number and never the caption.
stat_tile : Str, Signal(Str), Str -> Elem
stat_tile = |label, figure, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(figure, [Html.class_attr("stat-value numeric"), Html.test_id(id)]),
		],
	)

## Select-all needs the current query as well as the current selection. It reads
## `query` atomically through `on_bool_with`, so the two stay separate handles.
## It lives in the Rows panel head, next to the rows it acts on.
select_all_row : Signal(Bool), Ui.State(List(U64)), Ui.State(Str) -> Elem
select_all_row = |all_checked, selected, query|
	Html.div_c(
		"check-row",
		[
			Html.checkbox_c(
				"Select all matching rows",
				all_checked,
				"checkbox",
				selected.on_bool_with(query, |current, query_value, on| GridData.set_all_matching(current, query_value, on)),
			),
			Html.paragraph_c("Select all matching rows", "text-sm text-zinc-700"),
		],
	)

summary_panel : Signal(GridData.Summary) -> Elem
summary_panel = |summary|
	Html.section_c(
		"Summary",
		panel_class,
		[
			Html.heading_c("Summary", "panel-title"),
			Html.div_c(
				"stat-grid",
				[
					stat_tile("Matching rows", summary.map(|s| s.matching.to_str()), "summary-matching"),
					stat_tile("Total score", summary.map(|s| s.total.to_str()), "summary-total"),
					stat_tile("Average score", summary.map(|s| s.average.to_str()), "summary-average"),
					stat_tile("Highest score", summary.map(|s| s.highest.to_str()), "summary-highest"),
					stat_tile("Lowest score", summary.map(|s| s.lowest.to_str()), "summary-lowest"),
					stat_tile("Selected in filter", summary.map(|s| s.selected_here.to_str()), "summary-selected-here"),
					stat_tile("Selected overall", summary.map(|s| s.selected_all.to_str()), "summary-selected-all"),
				],
			),
		],
	)

# ---------------------------------------------------------------------------
# Tests
#
# These cover the pure grid logic in `GridData`: the comparator, the caption,
# and the sort-button reducer. They are the proof that swapping the stringly
# typed sort key for a tag union left the rendered output alone.
# ---------------------------------------------------------------------------

by_id : GridData.Sort
by_id = { key: ById, desc: False }

by_score : GridData.Sort
by_score = { key: ByScore, desc: False }

## A single-digit row id is padded to the full four columns of the name.
expect GridData.pad4(7) == "0007"

## A two-digit row id keeps two leading zeros, so names stay the same width.
expect GridData.pad4(42) == "0042"

## A four-digit row id is already full width and gains no padding.
expect GridData.pad4(1199) == "1199"

## Team names order alphabetically by their first differing byte.
expect GridData.str_compare("Atlas", "Borealis") == LT

## Two identical row names compare equal, which is what lets the id break the tie.
expect GridData.str_compare("Node-0009", "Node-0009") == EQ

## Zero padding makes the byte order agree with the numeric order of the ids.
expect GridData.str_compare("Node-0010", "Node-0009") == GT

## A prefix sorts before the string that extends it.
expect GridData.str_compare("Node", "Node-0000") == LT

## The caption names the column and spells an unset descending flag "ascending".
expect GridData.sort_caption(by_id) == "Sorted by id ascending"

## The caption names the column and spells a set descending flag "descending".
expect GridData.sort_caption({ key: ByTeam, desc: True }) == "Sorted by team descending"

## Clicking the column already sorted by reverses its direction.
expect GridData.apply_sort_click(by_score, ByScore) == { key: ByScore, desc: True }

## Clicking a different column starts that column ascending, dropping the old flag.
expect GridData.apply_sort_click({ key: ByScore, desc: True }, ByName) == { key: ByName, desc: False }

## The first page of a score-ascending sort, as the sorting spec asserts it.
expect {
	page = GridData.window_of(GridData.sort_rows(GridData.filter_rows(""), by_score), 0)
	page.map(|row| row.id) == [0, 621, 296, 1133, 52, 837, 79, 647, 782, 1108]
}

## Descending reverses the id tiebreak too, so 702 leads 592 on a shared 999.
expect {
	page = GridData.window_of(GridData.sort_rows(GridData.filter_rows(""), { key: ByScore, desc: True }), 0)
	page.take_first(2).map(|row| row.id) == [702, 592]
}

## An empty result set still has a page zero to show the empty state on.
expect GridData.last_page_of(0) == 0

## The full dataset fills 120 pages, numbered from zero.
expect GridData.last_page_of(1200) == 119

## A count of exactly one page worth of rows does not spill onto a second page.
expect GridData.last_page_of(10) == 0

## A stored note is found by the row id it was filed under.
expect GridData.note_for([{ id: 3, note: "check" }], 3) == "check"

## A row with no stored note reads as empty rather than borrowing another row's.
expect GridData.note_for([{ id: 3, note: "check" }], 4) == ""

## Writing a note for a row makes it readable back for that row.
expect GridData.note_for(GridData.set_note([], 9, "later"), 9) == "later"

main : () -> Elem
main = || {
	initial_sort : GridData.Sort
	initial_sort = { key: ById, desc: False }

	initial_notes : List(GridData.Note)
	initial_notes = []

	initial_query : Str
	initial_query = ""

	initial_selected : List(U64)
	initial_selected = []

	initial_page : U64
	initial_page = 0

	Ui.state(
		initial_sort,
		|sort| {
			Ui.state(
				initial_page,
				|page| {
					Ui.state(
						initial_notes,
						|notes| {
							Ui.state(
								initial_query,
								|query_state| {
									Ui.state(
										initial_selected,
										|selected_state| {
											# --- derived graph -------------------------------------
											query : Signal(Str)
											query = query_state.signal()

											selected : Signal(List(U64))
											selected = selected_state.signal()

											sort_sig : Signal(GridData.Sort)
											sort_sig = sort.signal()

											# chain: filter -> query -> filtered
											filtered : Signal(List(GridData.Row))
											filtered = query.map(GridData.filter_rows)

											# fan-in: filtered rows + sort spec
											sorted : Signal(List(GridData.Row))
											sorted = Signal.map2(filtered, sort_sig, GridData.sort_rows)

											last_page : Signal(U64)
											last_page = filtered.map(|rows| GridData.last_page_of(rows.len()))

											# fan-in: requested page + real last page (clamps past-the-end)
											current_page : Signal(U64)
											current_page =
												Signal.map2(
													page.signal(),
													last_page,
													|requested, last| if requested > last {
														last
													} else {
														requested
													},
												)

											# fan-in: sorted rows + clamped page -> only the window
											page_rows : Signal(List(GridData.Row))
											page_rows = Signal.map2(sorted, current_page, GridData.window_of)

											# fan-in: selection + notes
											row_ctx : Signal({ selected : List(U64), notes : List(GridData.Note) })
											row_ctx =
												Signal.map2(
													selected,
													notes.signal(),
													|sel, note_list| { selected: sel, notes: note_list },
												)

											# fan-in: windowed rows + row context -> rendered rows
											view_rows : Signal(List(GridData.ViewRow))
											view_rows = Signal.map2(page_rows, row_ctx, GridData.decorate)

											# fan-in over the FULL filtered dataset, not the page
											summary : Signal(GridData.Summary)
											summary = Signal.map2(filtered, selected, GridData.summarize)

											all_checked : Signal(Bool)
											all_checked =
												summary.map(
													|s| s.matching > 0 and s.selected_here == s.matching,
												)

											page_label : Signal(Str)
											page_label =
												Signal.map2(
													current_page,
													last_page,
													|current, last| "Page ${(current + 1).to_str()} of ${(last + 1).to_str()}",
												)

											prev_disabled : Signal(Bool)
											prev_disabled = current_page.map(|current| current == 0)

											next_disabled : Signal(Bool)
											next_disabled =
												Signal.map2(current_page, last_page, |current, last| current >= last)

											showing_label : Signal(Str)
											showing_label =
												Signal.map2(
													page_rows,
													summary,
													|rows, s| "Showing ${rows.len().to_str()} of ${s.matching.to_str()} rows",
												)

											has_rows : Signal(Bool)
											has_rows = summary.map(|s| s.matching > 0)

											Html.div_c(
												page_class,
												[
													Html.section_c(
														"Data Grid",
														"app-header",
														[
															Html.heading_c("Data Grid", "app-title"),
															Html.paragraph_c(
																"Sort, filter, select, and edit a generated ${GridData.row_count.to_str()}-row dataset while rendering only ${GridData.page_size.to_str()} rows at a time.",
																"app-subtitle",
															),
															Html.paragraph_c("Dataset rows: ${GridData.row_count.to_str()}", "badge badge-neutral numeric w-fit"),
														],
													),
													Html.section_c(
														"Grid controls",
														panel_class,
														[
															Html.heading_c("Filter and sort", "panel-title"),
															Html.div_c(
																"toolbar",
																[
																	Html.div_c(
																		"field min-w-64 grow",
																		[
																			Html.paragraph_c("Filter rows", "field-label"),
																			Html.text_input_attrs(
																				"Filter",
																				query,
																				[Html.class_attr(input_class), Html.attr("placeholder", "Node-0042 or Atlas")],
																				query_state.on_str(|_, value| value),
																			),
																			Html.paragraph_c("Matches on name or team across all ${GridData.row_count.to_str()} rows.", "hint"),
																		],
																	),
																	Html.div_c(
																		"field",
																		[
																			Html.paragraph_c("Sort by", "field-label"),
																			Html.div_c(
																				"flex flex-wrap items-center gap-2",
																				[
																					Html.button_c("Sort by id", sort_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, ById))),
																					Html.button_c("Sort by name", sort_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, ByName))),
																					Html.button_c("Sort by team", sort_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, ByTeam))),
																					Html.button_c("Sort by score", sort_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, ByScore))),
																				],
																			),
																			Html.paragraph_s_attrs(
																				sort_sig.map(GridData.sort_caption),
																				[Html.class_attr("badge badge-info w-fit"), Html.test_id("sort-caption")],
																			),
																		],
																	),
																],
															),
														],
													),
													summary_panel(summary),
													Html.section_c(
														"Rows",
														"panel",
														[
															Html.div_c(
																"panel-head",
																[
																	Html.heading_c("Rows", "panel-title"),
																	select_all_row(all_checked, selected_state, query_state),
																	Html.paragraph_s_attrs(showing_label, [Html.class_attr("hint numeric"), Html.test_id("rows-showing")]),
																],
															),
															Html.div_c(
																"panel-body",
																[
																	Html.div_c(
																		"table-scroll",
																		[
																			Html.div_c(
																				"min-w-[46rem]",
																				[
																					grid_header,
																			Ui.each(Signal.map(view_rows, |rows_items| Rows.from_list(rows_items, |row| row.id.to_str()) ?? crash "duplicate row key"), |each_row| render_row(selected_state, notes, each_row.key(), each_row.signal())),
																				],
																			),
																		],
																	),
																	# The empty branch is the `empty-state`; the populated branch
																	# is a caption, so the empty text is the only one on screen.
																	Ui.when(
																		has_rows,
																		|| Html.paragraph_c("Notes are per row and survive sorting and paging.", "hint"),
																		|| Html.div_c("empty-state", [Html.paragraph("No rows match the filter")]),
																	),
																],
															),
														],
													),
													Html.section_c(
														"Paging",
														"panel flex flex-wrap items-center justify-between gap-3 p-4",
														[
															Html.paragraph_s_attrs(page_label, [Html.class_attr("value numeric"), Html.test_id("page-label")]),
															Html.div_c(
																"flex flex-wrap items-center gap-2",
																[
																	Html.button_c("First page", "button-ghost", page.on_unit(|_| 0)),
																	Html.action_button_c(
																		Signal.const("Previous page"),
																		prev_disabled,
																		"button",
																		page.on_unit(
																			|current| if current == 0 {
																				0
																			} else {
																				current - 1
																			},
																		),
																	),
																	Html.action_button_c(
																		Signal.const("Next page"),
																		next_disabled,
																		"button-primary",
																		page.on_unit(|current| current + 1),
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
		},
	)
}
