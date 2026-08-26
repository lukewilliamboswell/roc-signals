app [main] { pf: platform "../../platform/main.roc" }

import Cells
import Formula
import Sheet

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class : Str
page_class = "app-shell app-shell-wide"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

## The grid is drawn as nested flex rows rather than a `<table>`, because each
## row has to stay a labelled `section` for the keyed-reorder specs to address
## it. Borders are hung off the bottom/right of every cell so the frame reads as
## one continuous ruled grid.
grid_frame_class : Str
grid_frame_class = "min-w-max overflow-hidden rounded-md border-l border-t border-zinc-200"

row_class : Str
row_class = "flex items-stretch"

header_row_class : Str
header_row_class = "flex items-stretch bg-zinc-50"

header_cell_class : Str
header_cell_class = "w-28 shrink-0 border-b border-r border-zinc-200 px-2 py-1.5 text-center text-xs font-semibold uppercase tracking-wide text-zinc-500"

gutter_class : Str
gutter_class = "flex w-12 shrink-0 items-center justify-center border-b border-r border-zinc-200 bg-zinc-50 px-2 py-1.5 text-xs font-semibold uppercase tracking-wide tabular-nums text-zinc-500"

## Where the caret is and whether that cell is being edited. Editing is a
## property of the cursor, not of the document, so it lives here.
Cursor : { selected : U64, editing : Bool }

## One rendered cell. `value` is what the cell input shows: the raw source in
## formula mode, the computed value otherwise. While a cell has focus the host
## leaves the user's own text alone and resyncs on blur.
CellView : { key : Str, ref : Str, value : Str, kind : Sheet.CellKind, selected : Bool }

## One rendered row. The key is the row number, so a row keeps its identity (and
## its cell scopes) through hide/show and reorder.
RowView : { key : Str, cells : List(CellView) }

## The workbook as the formula bar sees it: the raw sources and the evaluated
## outputs, joined so the bar can show either without a second pass.
Book : { sources : List(Str), outs : List(Sheet.CellOut) }

## What the formula bar shows about the selected cell: its address, whether the
## caret is editing it, its raw source, its computed text, the kind tag that
## text came from, and the cells it reads.
BarView : {
	ref : Str,
	editing : Bool,
	source : Str,
	value : Str,
	kind : Sheet.CellKind,
	depends : Str,
}

## The three unrelated readouts that make up the summary strip. Joining them
## into one record keeps the fan-in visible in the signal graph.
Status : { selected : Str, mode : Str, errors : Str }

GridInput : {
	outs : List(Sheet.CellOut),
	sources : List(Str),
	selected : U64,
	formulas : Bool,
	hide_empty : Bool,
	reversed : Bool,
}

out_at : List(Sheet.CellOut), U64 -> Sheet.CellOut
out_at = |outs, index| outs.get(index).ok_or({ text: "", kind: Empty })

source_at : List(Str), U64 -> Str
source_at = |sources, index| sources.get(index).ok_or("")

cell_view : GridInput, U64 -> CellView
cell_view = |input, index| {
	source = source_at(input.sources, index)
	out = out_at(input.outs, index)
	selected = input.selected == index
	ref = Cells.ref_of(index)
	{
		key: ref,
		ref,
		value: if input.formulas { source } else { out.text },
		kind: out.kind,
		selected,
	}
}

row_is_empty : List(Str), U64 -> Bool
row_is_empty = |sources, row| {
	var $col = 0
	var $empty = True

	while $col < Cells.col_count {
		if !source_at(sources, row * Cells.col_count + $col).is_empty() {
			$empty = False
		}
		$col = $col + 1
	}

	$empty
}

build_rows : GridInput -> List(RowView)
build_rows = |input| {
	var $rows = []
	var $row = 0

	while $row < Cells.row_count {
		if input.hide_empty and row_is_empty(input.sources, $row) {
			$row = $row + 1
		} else {
			var $cells = []
			var $col = 0

			while $col < Cells.col_count {
				$cells = $cells.append(cell_view(input, $row * Cells.col_count + $col))
				$col = $col + 1
			}

			number = ($row + 1).to_str()
			$rows = $rows.append({ key: number, cells: $cells })
			$row = $row + 1
		}
	}

	if input.reversed {
		var $flipped = []
		var $take = $rows.len()

		while $take > 0 {
			$flipped =
				match $rows.get($take - 1) {
					Ok(row) => $flipped.append(row)
					Err(_) => $flipped
				}
			$take = $take - 1
		}

		$flipped
	} else {
		$rows
	}
}

## How many rows survive the "hide empty rows" filter.
visible_row_text : List(Str), Bool -> Str
visible_row_text = |sources, hide|
	if !hide {
		Cells.row_count.to_str()
	} else {
		var $row = 0
		var $shown = 0.U64

		while $row < Cells.row_count {
			if !row_is_empty(sources, $row) {
				$shown = $shown + 1
			}
			$row = $row + 1
		}

		$shown.to_str()
	}

count_errors : List(Sheet.CellOut) -> U64
count_errors = |outs| outs.keep_if(|out| out.kind == Error).len()

## A cell's presentation and its error state come from the same `CellView`, so
## the red tint and the `#REF`/`#DIV/0!` text can never disagree: both are read
## off `kind`, which is the tag the evaluator produced for that value.
tone_class : CellView -> Str
tone_class = |cell| {
	base = "w-28 shrink-0 rounded-none border-0 border-b border-r border-zinc-200 px-2 py-1.5 text-sm tabular-nums focus:relative focus:z-10 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-emerald-500"
	tone =
		match cell.kind {
			Error => " bg-red-50 text-right font-semibold text-red-700"
			Number => " bg-white text-right text-zinc-900"
			Empty => " bg-white text-left text-zinc-900"
			Text => " bg-white text-left text-zinc-900"
		}
	selection = if cell.selected { " relative z-10 bg-emerald-50 ring-2 ring-inset ring-emerald-500" } else { "" }
	"${base}${tone}${selection}"
}

## The column header strip: an empty corner over the row-number gutter, then one
## muted uppercase heading per column.
column_header : Elem
column_header = {
	Html.div_c(
		header_row_class,
		[Html.div_c(gutter_class, [Html.text("")])].concat(
			Cells.col_letters.map(|letter| Html.div_c(header_cell_class, [Html.text(letter)])),
		),
	)
}

set_source : List(Str), U64, Str -> List(Str)
set_source = |sources, index, text| sources.set(index, text).ok_or(sources)

## A cell is a labelled text input. Its index is known statically from the row
## key, so its reducer can write straight into the sheet without the sheet state
## needing to know where the caret is.
render_cell : Ui.State(List(Str)), Ui.State(Cursor), Str, Signal.Signal(CellView) -> Elem
render_cell = |sheet, cursor, key, cell| {
	index = Cells.index_of(key).ok_or(0)

	Html.text_input_attrs(
		key,
		Signal.map(cell, |view| view.value),
		[
			Html.test_id("cell-${key}"),
			Html.class_attr_s(Signal.map(cell, tone_class)),
			Html.attr_s("data-kind", Signal.map(cell, |view| Sheet.CellKind.to_str(view.kind))),
			Html.on_focus(cursor.on_unit(|current| { ..current, selected: index, editing: True })),
			Html.on_blur(cursor.on_unit(|current| { ..current, editing: False })),
		],
		sheet.on_str(|sources, text| set_source(sources, index, text)),
	)
}

## A row only re-diffs its cells when its own item changed, so an edit reaches
## exactly the rows holding dependents of the edited cell.
render_row : Ui.State(List(Str)), Ui.State(Cursor), Str, Signal.Signal(RowView) -> Elem
render_row = |sheet, cursor, key, row| {
	cells = Signal.map(row, |view| view.cells)

	Html.section_c(
		"Row ${key}",
		row_class,
		[
			Html.div_c(gutter_class, [Html.text(key)]),
			Ui.each_str(cells, |cell| cell.key, |cell_key, cell| render_cell(sheet, cursor, cell_key, cell)),
		],
	)
}

## The formula bar: a fan-in of the caret and the evaluated workbook. It shows
## the source while the selected cell is being edited and the value otherwise.
formula_bar : Ui.State(List(Str)), Ui.State(Cursor), Signal.Signal(Book) -> Elem
formula_bar = |sheet, cursor, book| {
	bar : Signal.Signal(BarView)
	bar =
		Signal.map2(
			cursor.signal(),
			book,
			|caret, values| {
				source = source_at(values.sources, caret.selected)
				out = out_at(values.outs, caret.selected)
				{
					ref: Cells.ref_of(caret.selected),
					editing: caret.editing,
					source,
					value: out.text,
					kind: out.kind,
					depends: Formula.depends_on(source),
				}
			},
		)

	Html.section_c(
		"Formula bar",
		"panel",
		[
			Html.div_c(
				"panel-head",
				[
					Html.div_c(
						"flex items-baseline gap-2",
						[
							Html.paragraph_c("Formula bar", "panel-title"),
							Html.paragraph_s_attrs(
								Signal.map(bar, |view| view.ref),
								[Html.test_id("bar-cell"), Html.class_attr("text-base font-semibold tabular-nums text-zinc-950")],
							),
						],
					),
					Html.paragraph_s_attrs(
						Signal.map(bar, |view| if view.editing { "Editing" } else { "Showing value" }),
						[
							Html.test_id("bar-mode"),
							Html.class_attr_s(Signal.map(bar, |view| if view.editing { "badge badge-info" } else { "badge badge-neutral" })),
						],
					),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.div_c(
						"field",
						[
							Html.paragraph_c("Contents of the selected cell", "field-label"),
							Html.text_input_attrs(
								"Formula",
								Signal.map(bar, |view| if view.editing { view.source } else { view.value }),
								[
									Html.test_id("formula-bar"),
									Html.class_attr("input tabular-nums"),
									Html.attr("placeholder", "=B2+C2"),
								],
								sheet.on_str_with(cursor, |sources, caret, text| set_source(sources, caret.selected, text)),
							),
							Html.paragraph_c(
								"Typing here writes the selected cell. The grid keeps showing computed values.",
								"hint",
							),
						],
					),
					Html.div_c(
						"grid gap-3 sm:grid-cols-3",
						[
							readout(
								"Source",
								Signal.map(bar, |view| if view.source.is_empty() { "(empty)" } else { view.source }),
								"bar-source",
							),
							# The bar's value tone is read off the same `kind` tag as the
							# cell's, so a red cell can never sit beside a black bar.
							Html.div_c(
								"grid min-w-0 gap-1",
								[
									Html.paragraph_c("Value", "label"),
									Html.paragraph_s_attrs(
										Signal.map(bar, |view| if view.value.is_empty() { "(empty)" } else { view.value }),
										[
											Html.test_id("bar-value"),
											Html.class_attr_s(Signal.map(bar, value_tone_class)),
										],
									),
								],
							),
							readout("Depends on", Signal.map(bar, |view| view.depends), "bar-depends"),
						],
					),
				],
			),
		],
	)
}

## The formula bar's value shares the grid's error tone.
value_tone_class : BarView -> Str
value_tone_class = |view|
	match view.kind {
		Error => "text-sm font-semibold tabular-nums text-red-700"
		Empty => "value break-words tabular-nums"
		Number => "value break-words tabular-nums"
		Text => "value break-words tabular-nums"
	}

## A caption over a monospaced-figures readout. The label is drawn beside the
## value instead of being folded into it, so the assertion targets the value.
readout : Str, Signal.Signal(Str), Str -> Elem
readout = |label, value, id|
	Html.div_c(
		"grid min-w-0 gap-1",
		[
			Html.paragraph_c(label, "label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("value break-words tabular-nums")]),
		],
	)

## One metric tile in the summary strip.
stat_tile : Str, Signal.Signal(Str), Str -> Elem
stat_tile = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value")]),
		],
	)

main : () -> Elem
main = || {
	# Five small state handles instead of one workbook record: the document, the
	# caret, and three independent view toggles.
	Ui.state(
		Sheet.initial_cells,
		|sheet|
			Ui.state(
				{ selected: 0, editing: False },
				|cursor|
					Ui.state(
						False,
						|show_formulas|
							Ui.state(
								False,
								|hide_empty|
									Ui.state(
										False,
										|reverse_rows| {
											sources = sheet.signal()

											# One evaluation pass over the whole workbook. Everything
											# below is derived from it; nothing is stored twice.
											outs = Signal.map(sources, Sheet.evaluate_out)

											cursor_signal = cursor.signal()
											selected_index = Signal.map(cursor_signal, |caret| caret.selected)
											formulas_signal = show_formulas.signal()
											hide_signal = hide_empty.signal()
											reversed_signal = reverse_rows.signal()

											# Fan-in: sources and computed values feed the formula bar.
											book : Signal.Signal(Book)
											book =
												Signal.map2(
													sources,
													outs,
													|values, computed| { sources: values, outs: computed },
												)

											# Fan-in: six independent signals feed the rendered grid.
											grid_input : Signal.Signal(GridInput)
											grid_input =
												{
													outs: outs,
													sources: sources,
													selected: selected_index,
													formulas: formulas_signal,
													hide_empty: hide_signal,
													reversed: reversed_signal,
												}.Signal

											rows = Signal.map(grid_input, build_rows)

										# Fan-in: selection, grid mode, and error count are three
										# unrelated signals joined into one status record, which then
										# drives the three tiles of the summary strip.
										selection_text = Signal.map(selected_index, |index| Cells.ref_of(index))
										mode_text =
											Signal.map(formulas_signal, |on| if on { "Formulas" } else { "Values" })
										error_text =
											Signal.map(outs, |computed| count_errors(computed).to_str())
										status : Signal.Signal(Status)
										status =
											Signal.map2(
												selection_text,
												Signal.map2(mode_text, error_text, |mode, errors| { mode, errors }),
												|selection, rest| { selected: selection, mode: rest.mode, errors: rest.errors },
											)

										# How many rows the grid is currently drawing, for the tile
										# that explains what "Hide empty rows" just did. Derived from
										# the same two inputs `build_rows` filters on rather than from
										# `rows` itself, which is already consumed as a keyed list.
										visible_rows = Signal.map2(sources, hide_signal, visible_row_text)

										Html.div_c(
											page_class,
											[
												Html.section_c(
													"Spreadsheet Lite",
													"app-header",
													[
														Html.heading_c("Spreadsheet Lite", "app-title"),
														Html.paragraph_c(
															"A quarterly budget on an 8 by 12 sheet, where every formula is a dependency edge. Editing a cell recomputes only the cells that transitively depend on it.",
															"app-subtitle",
														),
													],
												),
												formula_bar(sheet, cursor, book),
												Html.section_c(
													"Sheet controls",
													"panel",
													[
														Html.div_c(
															"panel-head",
															[
																Html.paragraph_c("Sheet controls", "panel-title"),
																Html.div_c(
																	"toolbar",
																	[
																		Html.button_s_attrs(
																			Signal.map(
																				formulas_signal,
																				|on| if on { "Show values" } else { "Show formulas" },
																			),
																			[Html.attr("type", "button"), Html.class_attr("button button-sm")],
																			show_formulas.on_unit(|on| !on),
																		),
																		Html.button_s_attrs(
																			Signal.map(
																				hide_signal,
																				|on| if on { "Show all rows" } else { "Hide empty rows" },
																			),
																			[Html.attr("type", "button"), Html.class_attr("button button-sm")],
																			hide_empty.on_unit(|on| !on),
																		),
																		Html.button_s_attrs(
																			Signal.map(
																				reversed_signal,
																				|on| if on { "Top to bottom" } else { "Reverse row order" },
																			),
																			[Html.attr("type", "button"), Html.class_attr("button button-sm")],
																			reverse_rows.on_unit(|on| !on),
																		),
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
																		stat_tile("Selected cell", Signal.map(status, |view| view.selected), "stat-selected"),
																		stat_tile("Grid mode", Signal.map(status, |view| view.mode), "stat-mode"),
																		stat_tile("Formula errors", Signal.map(status, |view| view.errors), "status-line"),
																		stat_tile("Rows shown", visible_rows, "stat-rows"),
																	],
																),
															],
														),
													],
												),
												Html.section_c(
													"Sheet grid",
													"panel",
													[
														Html.div_c(
															"panel-head",
															[
																Html.paragraph_c("Sheet grid", "panel-title"),
																Html.paragraph_c(
																	"Numbers right-aligned, text left-aligned, errors in red.",
																	"hint",
																),
															],
														),
														Html.div_c(
															"panel-body",
															[
																# The cell area scrolls sideways inside the panel; the
																# page itself never grows a horizontal scrollbar.
																Html.div_c(
																	"table-scroll",
																	[
																		Html.div_c(
																			grid_frame_class,
																			[
																				column_header,
																				Ui.each_str(
																					rows,
																					|row| row.key,
																					|key, row| render_row(sheet, cursor, key, row),
																				),
																			],
																		),
																	],
																),
															],
														),
													],
												),
											],
										)
																			},
									),
							),
					),
			),
	)
}

# The tone is read off the `kind` tag, never off the rendered text, so an error
# cell and the formula bar showing it always agree.
expect tone_class({ key: "B9", ref: "B9", value: "#DIV/0!", kind: Error, selected: False }).contains("bg-red-50")
expect tone_class({ key: "B2", ref: "B2", value: "1200", kind: Number, selected: False }).contains("text-right")
expect tone_class({ key: "A2", ref: "A2", value: "Rent", kind: Text, selected: False }).contains("text-left")
expect tone_class({ key: "A2", ref: "A2", value: "Rent", kind: Text, selected: True }).contains("ring-emerald-500")

expect value_tone_class({ ref: "B9", editing: False, source: "=1/0", value: "#DIV/0!", kind: Error, depends: "none" })
	== "text-sm font-semibold tabular-nums text-red-700"
expect value_tone_class({ ref: "B2", editing: False, source: "1200", value: "1200", kind: Number, depends: "none" })
	== "value break-words tabular-nums"

expect count_errors(Sheet.evaluate_out(Sheet.initial_cells)) == 4
expect row_is_empty(Sheet.initial_cells, 10)
expect !row_is_empty(Sheet.initial_cells, 0)
expect visible_row_text(Sheet.initial_cells, False) == "12"
expect visible_row_text(Sheet.initial_cells, True) == "11"
