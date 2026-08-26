app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal exposing [Signal]
import pf.Ui

import GridData

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

row_class = "grid grid-cols-5 items-center gap-3 border-b border-zinc-200 py-2"

cell_class = "text-sm text-zinc-800"

input_class = "w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm"

header_button_class = "button text-sm font-semibold"

render_row : Ui.State(GridData.Filter), Ui.State(List(GridData.Note)), Str, Signal(GridData.ViewRow) -> Elem
render_row = |filter, notes, key, row| {
	row_id = GridData.parse_u64(key)
	name = "Node-${GridData.pad4(row_id)}"

	Html.div_c(
		row_class,
		[
			Html.checkbox_c(
				"Select ${name}",
				row.map(|r| r.selected),
				cell_class,
				filter.on_bool(|current, on| { query: current.query, selected: GridData.toggle_selected(current.selected, row_id, on) }),
			),
			Html.paragraph_s_c(row.map(|r| r.name), cell_class),
			Html.paragraph_s_c(row.map(|r| "${r.name} team: ${r.team}"), cell_class),
			Html.paragraph_s_c(row.map(|r| "${r.name} score: ${r.score.to_str()}"), cell_class),
			Html.text_input_c(
				"Note for ${name}",
				row.map(|r| r.note),
				input_class,
				notes.on_str(|current, value| GridData.set_note(current, row_id, value)),
			),
		],
	)
}

summary_panel : Signal(GridData.Summary), Signal(Bool), Ui.State(GridData.Filter) -> Elem
summary_panel = |summary, all_checked, filter| {
	Html.section_c(
		"Summary",
		panel_class,
		[
			Html.heading_c("Summary", "text-lg font-semibold text-zinc-950"),
			Html.checkbox_c(
				"Select all matching rows",
				all_checked,
				"text-sm",
				filter.on_bool(|current, on| { query: current.query, selected: GridData.set_all_matching(current.selected, current.query, on) }),
			),
			Html.paragraph_s_c(summary.map(|s| "Matching rows: ${s.matching.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Total score: ${s.total.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Average score: ${s.average.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Highest score: ${s.highest.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Lowest score: ${s.lowest.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Selected in filter: ${s.selected_here.to_str()}"), cell_class),
			Html.paragraph_s_c(summary.map(|s| "Selected overall: ${s.selected_all.to_str()}"), cell_class),
		],
	)
}

main : () -> Elem
main = || {
	initial_sort : GridData.Sort
	initial_sort = { key: "id", desc: False }

	initial_notes : List(GridData.Note)
	initial_notes = []

	initial_filter : GridData.Filter
	initial_filter = { query: "", selected: [] }

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
								initial_filter,
								|filter| {
									# --- derived graph -------------------------------------
									filter_sig : Signal(GridData.Filter)
									filter_sig = filter.signal()

									query : Signal(Str)
									query = filter_sig.map(|f| f.query)

									selected : Signal(List(U64))
									selected = filter_sig.map(|f| f.selected)

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
												hero_class,
												[
													Html.heading_c("Data Grid", "text-3xl font-semibold text-zinc-950"),
													Html.paragraph_c(
														"Sort, filter, select, and edit a generated ${GridData.row_count.to_str()}-row dataset while rendering only ${GridData.page_size.to_str()} rows at a time.",
														"max-w-3xl text-sm text-zinc-700",
													),
													Html.paragraph_c("Dataset rows: ${GridData.row_count.to_str()}", cell_class),
												],
											),
											Html.section_c(
												"Grid controls",
												panel_class,
												[
													Html.text_input_c(
														"Filter",
														query,
														input_class,
														filter.on_str(|current, value| { query: value, selected: current.selected }),
													),
													Html.div_c(
														toolbar_class,
														[
															Html.button_c("Sort by id", header_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, "id"))),
															Html.button_c("Sort by name", header_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, "name"))),
															Html.button_c("Sort by team", header_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, "team"))),
															Html.button_c("Sort by score", header_button_class, sort.on_unit(|current| GridData.apply_sort_click(current, "score"))),
														],
													),
													Html.paragraph_s_c(sort_sig.map(GridData.sort_caption), cell_class),
												],
											),
											summary_panel(summary, all_checked, filter),
											Html.section_c(
												"Rows",
												panel_class,
												[
													Html.heading_c("Rows", "text-lg font-semibold text-zinc-950"),
													Html.paragraph_s_c(showing_label, cell_class),
													Ui.each_str(view_rows, |row| row.id.to_str(), |key, row| render_row(filter, notes, key, row)),
													Ui.when(
														has_rows,
														|| Html.paragraph_c("Filter matches rows", cell_class),
														|| Html.paragraph_c("No rows match the filter", cell_class),
													),
												],
											),
											Html.section_c(
												"Paging",
												panel_class,
												[
													Html.paragraph_s_c(page_label, cell_class),
													Html.div_c(
														toolbar_class,
														[
															Html.action_button_c(
																Signal.const("Previous page"),
																prev_disabled,
																"button",
																page.on_unit(|current| if current == 0 {
																	0
																} else {
																	current - 1
																}),
															),
															Html.action_button_c(
																Signal.const("Next page"),
																next_disabled,
																"button",
																page.on_unit(|current| current + 1),
															),
															Html.button_c("First page", "button", page.on_unit(|_| 0)),
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
