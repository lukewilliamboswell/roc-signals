app [main] { pf: platform "../../platform/main.roc" }

import Cells
import Formula
import Sheet

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

grid_class = "grid gap-1"

row_class = "flex gap-1 items-center"

header_row_class = "flex gap-1 items-center font-semibold"

header_cell_class = "w-24 text-center text-xs uppercase text-zinc-600"

row_label_class = "w-16 text-xs font-semibold text-zinc-600"

## Where the caret is and whether that cell is being edited. Editing is a
## property of the cursor, not of the document, so it lives here.
Cursor : { selected : U64, editing : Bool }

## One rendered cell. `value` is what the cell input shows: the raw source in
## formula mode, the computed value otherwise. While a cell has focus the host
## leaves the user's own text alone and resyncs on blur.
CellView : { key : Str, ref : Str, value : Str, kind : Str, selected : Bool }

## One rendered row. The key is the row number, so a row keeps its identity (and
## its cell scopes) through hide/show and reorder.
RowView : { key : Str, cells : List(CellView) }

GridInput : {
	outs : List(Sheet.CellOut),
	sources : List(Str),
	selected : U64,
	formulas : Bool,
	hide_empty : Bool,
	reversed : Bool,
}

out_at : List(Sheet.CellOut), U64 -> Sheet.CellOut
out_at = |outs, index|
	match outs.get(index) {
		Ok(value) => value
		Err(_) => { text: "", kind: "empty" }
	}

source_at : List(Str), U64 -> Str
source_at = |sources, index|
	match sources.get(index) {
		Ok(value) => value
		Err(_) => ""
	}

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

count_errors : List(Sheet.CellOut) -> U64
count_errors = |outs| outs.keep_if(|out| out.kind == "error").len()

tone_class : CellView -> Str
tone_class = |cell| {
	base = "w-24 rounded border px-1 py-1 text-sm"
	tone =
		if cell.kind == "error" {
			" border-red-400 bg-red-50 text-red-900"
		} else if cell.kind == "number" {
			" border-zinc-300 bg-white text-right"
		} else {
			" border-zinc-300 bg-white"
		}
	selection = if cell.selected { " ring-2 ring-blue-500" } else { "" }
	"${base}${tone}${selection}"
}

column_header : Elem
column_header = {
	Html.div_c(
		header_row_class,
		[Html.div_c(row_label_class, [Html.text("")])].concat(
			Cells.col_letters.map(|letter| Html.div_c(header_cell_class, [Html.text(letter)])),
		),
	)
}

set_source : List(Str), U64, Str -> List(Str)
set_source = |sources, index, text|
	match sources.set(index, text) {
		Ok(updated) => updated
		Err(_) => sources
	}

## A cell is a labelled text input. Its index is known statically from the row
## key, so its reducer can write straight into the sheet without the sheet state
## needing to know where the caret is.
render_cell : Ui.State(List(Str)), Ui.State(Cursor), Str, Signal.Signal(CellView) -> Elem
render_cell = |sheet, cursor, key, cell| {
	index =
		match Cells.index_of(key) {
			Ok(value) => value
			Err(_) => 0
		}

	Html.text_input_attrs(
		key,
		Signal.map(cell, |view| view.value),
		[
			Html.test_id("cell-${key}"),
			Html.class_attr_s(Signal.map(cell, tone_class)),
			Html.attr_s("data-kind", Signal.map(cell, |view| view.kind)),
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
			Html.div_c(row_label_class, [Html.text("Row ${key}")]),
			Ui.each_str(cells, |cell| cell.key, |cell_key, cell| render_cell(sheet, cursor, cell_key, cell)),
		],
	)
}

## The formula bar: a fan-in of the caret and the evaluated workbook. It shows
## the source while the selected cell is being edited and the value otherwise.
formula_bar : Ui.State(List(Str)), Ui.State(Cursor), Signal.Signal({ sources : List(Str), outs : List(Sheet.CellOut) }) -> Elem
formula_bar = |sheet, cursor, book| {
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
					depends: Formula.depends_on(source),
				}
			},
		)

	Html.section_c(
		"Formula bar",
		panel_class,
		[
			Html.heading_c("Formula bar", "text-lg font-semibold"),
			Html.text_input_attrs(
				"Formula",
				Signal.map(bar, |view| if view.editing { view.source } else { view.value }),
				[Html.test_id("formula-bar")],
				sheet.on_str_with(cursor, |sources, caret, text| set_source(sources, caret.selected, text)),
			),
			Html.paragraph_s_attrs(Signal.map(bar, |view| "Cell: ${view.ref}"), [Html.test_id("bar-cell")]),
			Html.paragraph_s_attrs(
				Signal.map(
					bar,
					|view| if view.source.is_empty() { "Source: (empty)" } else { "Source: ${view.source}" },
				),
				[Html.test_id("bar-source")],
			),
			Html.paragraph_s_attrs(
				Signal.map(bar, |view| if view.value.is_empty() { "Value: (empty)" } else { "Value: ${view.value}" }),
				[Html.test_id("bar-value")],
			),
			Html.paragraph_s_attrs(Signal.map(bar, |view| "Depends on: ${view.depends}"), [Html.test_id("bar-depends")]),
			Html.paragraph_s_attrs(
				Signal.map(bar, |view| if view.editing { "Mode: editing" } else { "Mode: showing value" }),
				[Html.test_id("bar-mode")],
			),
		],
	)
}

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
											# unrelated signals joined into one status line.
											selection_text =
												Signal.map(selected_index, |index| "Selected: ${Cells.ref_of(index)}")
											mode_text =
												Signal.map(
													formulas_signal,
													|on| if on { "Grid mode: formulas" } else { "Grid mode: values" },
												)
											error_text =
												Signal.map(outs, |computed| "Errors: ${count_errors(computed).to_str()}")
											status =
												Signal.map2(
													selection_text,
													Signal.map2(mode_text, error_text, |mode, errors| "${mode} | ${errors}"),
													|selection, rest| "${selection} | ${rest}",
												)

											Html.div_c(
												page_class,
												[
													Html.section_c(
														"Spreadsheet Lite",
														hero_class,
														[
															Html.heading_c("Spreadsheet Lite", "text-3xl font-semibold"),
															Html.paragraph_c(
																"An 8 by 12 sheet where every formula is a dependency edge. Editing a cell recomputes only the cells that transitively depend on it.",
																"max-w-3xl text-sm text-zinc-700",
															),
														],
													),
													formula_bar(sheet, cursor, book),
													Html.section_c(
														"Sheet controls",
														panel_class,
														[
															Html.button_s(
																Signal.map(
																	formulas_signal,
																	|on| if on { "Show values" } else { "Show formulas" },
																),
																show_formulas.on_unit(|on| !on),
															),
															Html.button_s(
																Signal.map(
																	hide_signal,
																	|on| if on { "Show all rows" } else { "Hide empty rows" },
																),
																hide_empty.on_unit(|on| !on),
															),
															Html.button_s(
																Signal.map(
																	reversed_signal,
																	|on| if on { "Top to bottom" } else { "Reverse row order" },
																),
																reverse_rows.on_unit(|on| !on),
															),
															Html.paragraph_s_attrs(status, [Html.test_id("status-line")]),
														],
													),
													Html.section_c(
														"Sheet grid",
														"${panel_class} ${grid_class}",
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
											)
										},
									),
							),
					),
			),
	)
}
