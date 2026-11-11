import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Cells
import Formula
import Sheet

## Spreadsheet Lite on the Roc-owned engine, ported from the previous engine:
## a quarterly budget on an 8 by 12 sheet where every formula is a dependency
## edge.
##
## Five sources, each its own state layer: the sheet's sources, the cursor
## (where the caret is and whether that cell is being edited) and three view
## toggles. One memoised `derive` evaluates the whole workbook; a second
## builds the grid's rows from it and the sources, cursor and toggles. Rows
## and their cells are keyed lists (row number, cell address), so an edit
## re-evaluates only the cells of the rows whose item changed, and a row
## keeps its cells through hide/show and reorder.
##
## Each cell is a labelled text input showing the computed value (the
## source in formula mode). While a cell has focus the browser keeps what the
## user typed and the computed value lands on blur (the controlled-input
## rule), so the formula bar is where the source of the selected cell lives.
SheetApp := [].{

	## Where the caret is and whether that cell is being edited. Editing is a
	## property of the cursor, not of the document, so it lives here.
	Cursor : { selected : U64, editing : Bool }

	## One rendered cell. `value` is what the cell input shows: the raw source
	## in formula mode, the computed value otherwise.
	CellView : { key : Str, value : Str, kind : Sheet.CellKind, selected : Bool }

	## One rendered row. The key is the row number, so a row keeps its
	## identity (and its cells) through hide/show and reorder.
	RowView : { key : Str, cells : List(CellView) }

	## What the formula bar shows about the selected cell: its address,
	## whether the caret is editing it, its raw source, its computed text,
	## the kind tag that text came from, and the cells it reads.
	BarView : { ref : Str, editing : Bool, source : Str, value : Str, kind : Sheet.CellKind, depends : Str }

	GridInput : { outs : List(Sheet.CellOut), sources : List(Str), selected : U64, formulas : Bool, hide_empty : Bool, reversed : Bool }

	C1 : In(Root, List(Str))
	C2 : In(C1, Cursor)
	C3 : In(C2, Bool)
	C4 : In(C3, Bool)
	C5 : In(C4, Bool)
	C6 : In(C5, List(Sheet.CellOut))
	C7 : In(C6, List(RowView))

	page_class = "app-shell app-shell-wide"

	## The grid is drawn as nested flex rows rather than a `<table>`, because
	## each row has to stay a labelled `section` for the keyed-reorder specs
	## to address it. Borders are hung off the bottom/right of every cell so
	## the frame reads as one continuous ruled grid.
	grid_frame_class = "min-w-max overflow-hidden rounded-md border-l border-t border-zinc-200"

	row_class = "flex items-stretch"

	header_row_class = "flex items-stretch bg-zinc-50"

	header_cell_class = "w-28 shrink-0 border-b border-r border-zinc-200 px-2 py-1.5 text-center text-xs font-semibold uppercase tracking-wide text-zinc-500"

	gutter_class = "flex w-12 shrink-0 items-center justify-center border-b border-r border-zinc-200 bg-zinc-50 px-2 py-1.5 text-xs font-semibold uppercase tracking-wide tabular-nums text-zinc-500"

	out_at : List(Sheet.CellOut), U64 -> Sheet.CellOut
	out_at = |outs, index| outs.get(index) ?? { text: "", kind: Empty }

	source_at : List(Str), U64 -> Str
	source_at = |sources, index| sources.get(index) ?? ""

	cell_view : GridInput, U64 -> CellView
	cell_view = |input, index| {
		out = SheetApp.out_at(input.outs, index)
		{
			key: Cells.ref_of(index),
			value: if (input.formulas) SheetApp.source_at(input.sources, index) else out.text,
			kind: out.kind,
			selected: input.selected == index,
		}
	}

	row_is_empty : List(Str), U64 -> Bool
	row_is_empty = |sources, row| {
		var $col = 0
		var $empty = True
		while $col < Cells.col_count {
			if !SheetApp.source_at(sources, row * Cells.col_count + $col).is_empty() {
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
			if !(input.hide_empty and SheetApp.row_is_empty(input.sources, $row)) {
				var $cells = []
				var $col = 0
				while $col < Cells.col_count {
					$cells = $cells.append(SheetApp.cell_view(input, $row * Cells.col_count + $col))
					$col = $col + 1
				}
				$rows = $rows.append({ key: ($row + 1).to_str(), cells: $cells })
			}
			$row = $row + 1
		}
		if input.reversed {
			var $flipped = []
			var $take = $rows.len()
			while $take > 0 {
				$flipped = match $rows.get($take - 1) {
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
				if !SheetApp.row_is_empty(sources, $row) {
					$shown = $shown + 1
				}
				$row = $row + 1
			}
			$shown.to_str()
		}

	count_errors : List(Sheet.CellOut) -> U64
	count_errors = |outs| outs.keep_if(|out| out.kind == Error).len()

	## A cell's presentation and its error state come from the same
	## `CellView`, so the red tint and the `#REF`/`#DIV/0!` text can never
	## disagree: both are read off `kind`, the tag the evaluator produced.
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
		selection = if (cell.selected) " relative z-10 bg-emerald-50 ring-2 ring-inset ring-emerald-500" else ""
		"${base}${tone}${selection}"
	}

	## The formula bar's value shares the grid's error tone.
	value_tone_class : BarView -> Str
	value_tone_class = |view|
		match view.kind {
			Error => "text-sm font-semibold tabular-nums text-red-700"
			_ => "value break-words tabular-nums"
		}

	set_source : List(Str), U64, Str -> List(Str)
	set_source = |sources, index, text| sources.set(index, text) ?? sources

	index_of : Str -> U64
	index_of = |key| Cells.index_of(key) ?? 0

	## The column header strip: an empty corner over the row-number gutter,
	## then one muted uppercase heading per column.
	column_header : {} -> Elem(ctx)
	column_header = |_| Html.div(SheetApp.header_row_class, [Html.div(SheetApp.gutter_class, [Engine.text("")])].concat(Cells.col_letters.map(|letter| Html.div(SheetApp.header_cell_class, [Engine.text(letter)]))))

	## A cell is a labelled text input. Its index is its key's address, so its
	## reducer writes straight into the sheet.
	render_cell : State(C7, List(Str)), State(C7, Cursor), RowRef(Row(C7, RowView), CellView) -> Elem(Row(Row(C7, RowView), CellView))
	render_cell = |sheet0, cursor0, cell| {
		sheet = sheet0.lift_row().lift_row()
		cursor = cursor0.lift_row().lift_row()
		key = cell.key()
		view = cell.field(|c| c)
		Html.text_input(
			key,
			"text",
			cell.field(|c| c.value),
			[
				Engine.test_id_v(key.map(|k| "cell-${k}")),
				Engine.class_v(view.map(SheetApp.tone_class)),
				Engine.attr_v("data-kind", cell.field(|c| Sheet.CellKind.to_str(c.kind))),
				Html.on_focus(cursor.update_by(key, |_, k| { selected: SheetApp.index_of(k), editing: True })),
				Html.on_blur(cursor.update(|c| { ..c, editing: False })),
			],
			sheet.set_value_by(key, |sources, k, text| SheetApp.set_source(sources, SheetApp.index_of(k), text)),
		)
	}

	## A row only re-diffs its cells when its own item changed, so an edit
	## reaches exactly the rows holding dependents of the edited cell.
	render_row : State(C7, List(Str)), State(C7, Cursor), RowRef(C7, RowView) -> Elem(Row(C7, RowView))
	render_row = |sheet, cursor, row| {
		key = row.key()
		Html.section_v(
			key.map(|k| "Row ${k}"),
			SheetApp.row_class,
			[
				Engine.element("div", [Engine.class(SheetApp.gutter_class)], [Engine.text_v(key)]),
				Engine.each(row.field(|r| r.cells), |c| c.key, |cell| SheetApp.render_cell(sheet, cursor, cell)),
			],
		)
	}

	## A caption over a monospaced-figures readout. The label is drawn beside
	## the value instead of being folded into it, so the assertion targets
	## the value.
	readout : Str, Val(ctx, Str), Str -> Elem(ctx)
	readout = |label, value, id| Html.div("grid min-w-0 gap-1", [Html.p(label, "label"), Html.p_v(value, [Engine.test_id(id), Engine.class("value break-words tabular-nums")])])

	## One metric tile in the summary strip.
	stat_tile : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat_tile = |label, value, id| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.test_id(id), Engine.class("stat-value")])])

	## The formula bar: a fan-in of the caret and the evaluated workbook. It
	## shows the source while the selected cell is being edited and the value
	## otherwise. Typing in it writes the selected cell, reading the cursor
	## when the input fires.
	formula_bar : State(C7, List(Str)), State(C7, Cursor), Val(C7, List(Sheet.CellOut)) -> Elem(C7)
	formula_bar = |sheet, cursor, outs| {
		bar = Val.map2(
			cursor.val(),
			sheet.val().map2(outs, |sources, computed| (sources, computed)),
			|caret, (sources, computed)| {
				source = SheetApp.source_at(sources, caret.selected)
				out = SheetApp.out_at(computed, caret.selected)
				{ ref: Cells.ref_of(caret.selected), editing: caret.editing, source, value: out.text, kind: out.kind, depends: Formula.depends_on(source) }
			},
		)
		Html.section(
			"Formula bar",
			"panel",
			[
				Html.div(
					"panel-head",
					[
						Html.div(
							"flex items-baseline gap-2",
							[
								Html.p("Formula bar", "panel-title"),
								Html.p_v(bar.map(|v| v.ref), [Engine.test_id("bar-cell"), Engine.class("text-base font-semibold tabular-nums text-zinc-950")]),
							],
						),
						Html.p_v(
							bar.map(|v| if (v.editing) "Editing" else "Showing value"),
							[Engine.test_id("bar-mode"), Engine.class_v(bar.map(|v| if (v.editing) "badge badge-info" else "badge badge-neutral"))],
						),
					],
				),
				Html.div(
					"panel-body",
					[
						Html.div(
							"field",
							[
								Html.p("Contents of the selected cell", "field-label"),
								Html.text_input(
									Engine.const("Formula"),
									"text",
									bar.map(|v| if (v.editing) v.source else v.value),
									[Engine.test_id("formula-bar"), Engine.class("input tabular-nums"), Engine.attr("placeholder", "=B2+C2")],
									sheet.set_value_by(cursor.val(), |sources, caret, text| SheetApp.set_source(sources, caret.selected, text)),
								),
								Html.p("Typing here writes the selected cell. The grid keeps showing computed values.", "hint"),
							],
						),
						Html.div(
							"grid gap-3 sm:grid-cols-3",
							[
								SheetApp.readout("Source", bar.map(|v| if (v.source.is_empty()) "(empty)" else v.source), "bar-source"),
								# The bar's value tone is read off the same `kind` tag
								# as the cell's, so a red cell can never sit beside a
								# black bar.
								Html.div(
									"grid min-w-0 gap-1",
									[
										Html.p("Value", "label"),
										Html.p_v(bar.map(|v| if (v.value.is_empty()) "(empty)" else v.value), [Engine.test_id("bar-value"), Engine.class_v(bar.map(SheetApp.value_tone_class))]),
									],
								),
								SheetApp.readout("Depends on", bar.map(|v| v.depends), "bar-depends"),
							],
						),
					],
				),
			],
		)
	}

	toggle : State(C7, Bool), Str, Str -> Elem(C7)
	toggle = |st, on_label, off_label| Html.button_v(st.val().map(|on| if (on) on_label else off_label), [Engine.attr("type", "button"), Engine.class("button button-sm")], st.update(|on| !on))

	page : { sheet : State(C7, List(Str)), cursor : State(C7, Cursor), formulas : State(C7, Bool), hide_empty : State(C7, Bool), reversed : State(C7, Bool) }, Val(C7, List(Sheet.CellOut)), Val(C7, List(RowView)) -> Elem(C7)
	page = |{ sheet, cursor, formulas, hide_empty, reversed }, outs, rows| {
		selected = cursor.val().map(|c| c.selected)
		Html.div(
			SheetApp.page_class,
			[
				Html.section(
					"Spreadsheet Lite",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Spreadsheet Lite")]),
						Html.p("A quarterly budget on an 8 by 12 sheet, where every formula is a dependency edge. Editing a cell recomputes only the cells that transitively depend on it.", "app-subtitle"),
					],
				),
				SheetApp.formula_bar(sheet, cursor, outs),
				Html.section(
					"Sheet controls",
					"panel",
					[
						Html.div(
							"panel-head",
							[
								Html.p("Sheet controls", "panel-title"),
								Html.div(
									"toolbar",
									[
										SheetApp.toggle(formulas, "Show values", "Show formulas"),
										SheetApp.toggle(hide_empty, "Show all rows", "Hide empty rows"),
										SheetApp.toggle(reversed, "Top to bottom", "Reverse row order"),
									],
								),
							],
						),
						Html.div(
							"panel-body",
							[
								Html.div(
									"stat-grid",
									[
										SheetApp.stat_tile("Selected cell", selected.map(Cells.ref_of), "stat-selected"),
										SheetApp.stat_tile("Grid mode", formulas.val().map(|on| if (on) "Formulas" else "Values"), "stat-mode"),
										SheetApp.stat_tile("Formula errors", outs.map(|o| SheetApp.count_errors(o).to_str()), "status-line"),
										SheetApp.stat_tile("Rows shown", sheet.val().map2(hide_empty.val(), SheetApp.visible_row_text), "stat-rows"),
									],
								),
							],
						),
					],
				),
				Html.section(
					"Sheet grid",
					"panel",
					[
						Html.div("panel-head", [Html.p("Sheet grid", "panel-title"), Html.p("Numbers right-aligned, text left-aligned, errors in red.", "hint")]),
						Html.div(
							"panel-body",
							[
								# The cell area scrolls sideways inside the panel; the
								# page itself never grows a horizontal scrollbar.
								Html.div(
									"table-scroll",
									[
										Html.div(
											SheetApp.grid_frame_class,
											[
												SheetApp.column_header({}),
												Engine.each(rows, |r| r.key, |row| SheetApp.render_row(sheet, cursor, row)),
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
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program(|| SheetApp.main(Sheet.initial_cells))

	main : List(Str) -> Elem(Root)
	main = |cells| Engine.state(
		cells,
		|sheet1| Engine.state(
			{ selected: 0, editing: False },
			|cursor2| Engine.state(
				False,
				|formulas3| Engine.state(
					False,
					|hide4| Engine.state(
						False,
						|reversed5| {
							sheet5 = sheet1.lift().lift().lift().lift()
							cursor5 = cursor2.lift().lift().lift()
							formulas5 = formulas3.lift().lift()
							hide5 = hide4.lift()
							# One evaluation pass over the whole workbook; everything
							# below is derived from it.
							Engine.derive(
								sheet5.val().map(Sheet.evaluate_out),
								|outs6| {
									grid = {
										outs: outs6,
										sources: sheet5.lift().val(),
										selected: cursor5.lift().val().map(|c| c.selected),
										formulas: formulas5.lift().val(),
										hide_empty: hide5.lift().val(),
										reversed: reversed5.lift().val(),
									}
									Engine.derive(
										SheetApp.grid_val(grid),
										|rows7| SheetApp.page(
											{
												sheet: sheet5.lift().lift(),
												cursor: cursor5.lift().lift(),
												formulas: formulas5.lift().lift(),
												hide_empty: hide5.lift().lift(),
												reversed: reversed5.lift().lift(),
											},
											outs6.lift(),
											rows7,
										),
									)
								},
							)
						},
					),
				),
			),
		),
	)

	## The grid's rows: a fan-in of six independent values.
	grid_val : { outs : Val(C6, List(Sheet.CellOut)), sources : Val(C6, List(Str)), selected : Val(C6, U64), formulas : Val(C6, Bool), hide_empty : Val(C6, Bool), reversed : Val(C6, Bool) } -> Val(C6, List(RowView))
	grid_val = |{ outs, sources, selected, formulas, hide_empty, reversed }|
		Val.map2(
			outs.map2(sources, |o, s| (o, s)),
			selected.map2(formulas, |sel, f| (sel, f)).map2(hide_empty.map2(reversed, |h, r| (h, r)), |a, b| (a, b)),
			|(o, s), ((sel, f), (h, r))| SheetApp.build_rows({ outs: o, sources: s, selected: sel, formulas: f, hide_empty: h, reversed: r }),
		)
}

## An error cell is tinted from its `kind` tag, never from its rendered text.
expect SheetApp.tone_class({ key: "B9", value: "#DIV/0!", kind: Error, selected: False }).contains("bg-red-50")

## Numbers are right-aligned so the columns line up on the decimal point.
expect SheetApp.tone_class({ key: "B2", value: "1200", kind: Number, selected: False }).contains("text-right")

## Text is left-aligned, the opposite of the number alignment.
expect SheetApp.tone_class({ key: "A2", value: "Rent", kind: Text, selected: False }).contains("text-left")

## The selected cell gains a focus ring on top of whatever tone its kind gives it.
expect SheetApp.tone_class({ key: "A2", value: "Rent", kind: Text, selected: True }).contains("ring-emerald-500")

## The starting workbook contains exactly four error cells for the summary tile.
expect SheetApp.count_errors(Sheet.evaluate_out(Sheet.initial_cells)) == 4

## Row 11 of the starting workbook has no sources, so it is hideable.
expect SheetApp.row_is_empty(Sheet.initial_cells, 10)

## The header row has sources, so it survives the "hide empty rows" filter.
expect !SheetApp.row_is_empty(Sheet.initial_cells, 0)

## With hiding off, every row of the sheet is counted.
expect SheetApp.visible_row_text(Sheet.initial_cells, False) == "12"

## With hiding on, the one empty row drops out of the count.
expect SheetApp.visible_row_text(Sheet.initial_cells, True) == "11"
