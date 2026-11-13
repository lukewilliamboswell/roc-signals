import pf.Engine exposing [Elem, Handler, Row, RowRef, Signal, State]
import pf.Html
import Cells
import Sheet
import SheetStore

## Spreadsheet Lite: a quarterly budget on an 8 by 12 sheet where every
## formula is a dependency edge.
##
## The sheet is a table in the app's store (`SheetStore`): a row of cells
## under each row number, each cell holding what was typed and what that
## computes to. The grid is a view of that table. Its listing says which
## rows it keeps (all, or those with something typed) and in which order,
## so hiding the blank rows and reversing the sheet are writes of one small
## cell of the store: the view removes, creates and moves rows, and a row
## that stays keeps its cells.
##
## An edit is one transition (`SheetStore.typed`): it computes the sheet
## again and writes the rows whose cells came out different. The view wakes
## those rows, each of which matches its eight cells by address, so only the
## cells whose value changed are written to the page.
##
## Each cell is a labelled text input showing the computed value (the
## source in formula mode). While a cell has focus the browser keeps what
## the user typed and the computed value lands on blur (the controlled-input
## rule), so the formula bar is where the source of the selected cell lives.
##
## Every part of the page reads the store's cells where it stands, at any
## depth, so nothing is handed down from one part to the next.
SheetApp := [].{

	page_class = "app-shell app-shell-wide"

	## The grid is drawn as nested flex rows rather than a `<table>`, because
	## each row has to stay a labelled `section` for the keyed-reorder specs
	## to address it. Borders are hung off the bottom/right of every cell so
	## the frame reads as one continuous ruled grid.
	grid_frame_class = "min-w-max overflow-hidden border-l border-t border-zinc-200"

	row_class = "flex items-stretch"

	header_row_class = "flex items-stretch bg-zinc-50"

	header_cell_class = "w-28 shrink-0 border-b border-r border-zinc-200 px-2 py-1.5 text-center text-xs font-semibold uppercase tracking-wide text-zinc-500"

	gutter_class = "flex w-12 shrink-0 items-center justify-center border-b border-r border-zinc-200 bg-zinc-50 px-2 py-1.5 text-xs font-semibold uppercase tracking-wide tabular-nums text-zinc-500"

	## A cell's presentation and its error state come from the same `kind`,
	## the tag the evaluator produced, so the red tint and the
	## `#REF`/`#DIV/0!` text can never disagree.
	tone_class : Sheet.CellKind, [Selected, Unselected] -> Str
	tone_class = |kind, ring| {
		base = "w-28 shrink-0 border-0 border-b border-r border-zinc-200 px-2 py-1.5 text-sm tabular-nums focus:relative focus:z-10 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-accent-600"
		tone =
			match kind {
				Error => " bg-red-50 text-right font-semibold text-red-700"
				Number => " bg-white text-right text-zinc-900"
				Empty => " bg-white text-left text-zinc-900"
				Text => " bg-white text-left text-zinc-900"
			}
		selection =
			match ring {
				Selected => " relative z-10 bg-accent-50 ring-2 ring-inset ring-accent-600"
				Unselected => ""
			}
		"${base}${tone}${selection}"
	}

	## The formula bar's value shares the grid's error tone.
	value_tone_class : Sheet.CellKind -> Str
	value_tone_class = |kind|
		match kind {
			Error => "text-sm font-semibold tabular-nums text-red-700"
			_ => "value break-words tabular-nums"
		}

	## The column header strip: an empty corner over the row-number gutter,
	## then one muted uppercase heading per column.
	column_header : {} -> Elem(ctx)
	column_header = |_| Html.div(SheetApp.header_row_class, [Html.div(SheetApp.gutter_class, [Engine.text("")])].concat(Cells.col_letters.map(|letter| Html.div(SheetApp.header_cell_class, [Engine.text(letter)]))))

	## A cell of the sheet: a text input labelled with its address. What it
	## shows follows the grid's mode, and its ring the caret. Typing in it
	## is an edit of the sheet at its own index.
	cell_input : RowRef(ctx, Sheet.Cell) -> Elem(Row(ctx, Sheet.Cell))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	cell_input = |cell| {
		address = cell.key()
		index = cell.field(|held| held.index)
		Html.text_input(
			address,
			"text",
			cell.item().map2(SheetStore.cells.mode.signal(), Sheet.shown),
			[
				Engine.test_id_s(address.map(|ref| "cell-${ref}")),
				Engine.ref_s(address.map(|ref| "cell-${ref}")),
				Engine.attr("role", "gridcell"),
				Engine.class_s(cell.item().map2(SheetStore.cells.selected.signal(), |held, caret| SheetApp.tone_class(held.out.kind, if (held.index == caret) Selected else Unselected))),
				Engine.attr_s("data-kind", cell.field(|held| Sheet.CellKind.to_str(held.out.kind))),
				Html.on_focus(Engine.handle_by({ index: index, source: cell.field(|held| held.source), keyboard: SheetStore.cells.keyboard.signal() }.Signal, |reading, _value| SheetStore.focused_source(reading.index, reading.source, reading.keyboard))),
				Html.on_blur(Engine.does(SheetStore.blurred)),
			],
			Engine.handle_by(index, |at, text| SheetStore.typed(at, text)),
		)
	}

	## A row of the sheet, drawn over the handle the grid's view hands it:
	## its number, and its cells matched by address, so a row that an edit
	## wrote touches only the cells that changed.
	row_line : Signal(Row(ctx, U64), U64), State(Row(ctx, U64), Sheet.Row) -> Elem(Row(ctx, U64))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	row_line = |number, held| {
		label = number.map(|n| (n + 1).to_str())
		Html.section_s(
			label.map(|n| "Row ${n}"),
			SheetApp.row_class,
			[
				Engine.element("div", [Engine.class(SheetApp.gutter_class)], [Engine.text_s(label)]),
				Engine.each(held.signal(), |cell| Cells.ref_of(cell.index), SheetApp.cell_input),
			],
		)
	}

	## A caption over a monospaced-figures readout. The label is drawn beside
	## the value instead of being folded into it, so the assertion targets
	## the value.
	readout : Str, Signal(ctx, Str), Str -> Elem(ctx)
	readout = |label, value, id| Html.div("grid min-w-0 gap-1", [Html.p(label, "label"), Html.p_s(value, [Engine.test_id(id), Engine.class("value break-words tabular-nums")])])

	## One metric tile in the summary strip.
	stat_tile : Str, Signal(ctx, Str), Str -> Elem(ctx)
	stat_tile = |label, value, id| Html.div("stat", [Html.p(label, "stat-label"), Html.p_s(value, [Engine.test_id(id), Engine.class("stat-value")])])

	## A button whose label says what a click will do.
	switch_button : Signal(ctx, Str), Handler(ctx) -> Elem(ctx)
	switch_button = |label, handler| Html.button_s(label, [Engine.attr("type", "button"), Engine.class("button button-sm")], handler)

	## The formula bar: the selected cell as the sheet holds it now. It
	## shows the source while that cell is being edited and the value
	## otherwise. Typing in it is an edit of the selected cell, read when
	## the input fires. What it shows is worked out once for each change of
	## the sheet or the caret, by a `derive`, and read by every part of it.
	formula_bar : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	formula_bar = |{}| Engine.derive(
		SheetStore.bar({}),
		|bar| Html.section(
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
								Html.p_s(bar.map(|shown| shown.ref), [Engine.test_id("bar-cell"), Engine.class("text-base font-semibold tabular-nums text-zinc-950")]),
							],
						),
						Html.p_s(
							bar.map(|shown| if (shown.focus != Resting) "Editing" else "Showing value"),
							[Engine.test_id("bar-mode"), Engine.class_s(bar.map(|shown| if (shown.focus != Resting) "badge badge-info" else "badge badge-neutral"))],
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
									bar.map(|shown| if (shown.focus != Resting) shown.source else shown.value),
									[
										Engine.test_id("formula-bar"),
										Engine.ref("formula-bar"),
										Html.on_blur(Engine.does(SheetStore.blurred)),
										Engine.class("input tabular-nums"),
										Engine.attr("placeholder", "=B2+C2"),
										Html.on_focus(Engine.handle_by({ index: SheetStore.cells.selected.signal(), source: bar.map(|shown| shown.source), keyboard: SheetStore.cells.keyboard.signal() }.Signal, |reading, _| SheetStore.focused_source(reading.index, reading.source, reading.keyboard))),
										Engine.on_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("Enter"), Engine.Chord.plain("Escape")])) }, SheetApp.key_handler(True)),
									],
									Engine.handle_by(SheetStore.cells.selected.signal(), |at, text| SheetStore.typed(at, text)),
								),
								Html.p("Typing here writes the selected cell. The grid keeps showing computed values.", "hint"),
							],
						),
						Html.div(
							"grid gap-3 sm:grid-cols-3",
							[
								SheetApp.readout("Source", bar.map(|shown| if (shown.source.is_empty()) "(empty)" else shown.source), "bar-source"),
								# The bar's value tone is read off the same `kind` tag
								# as the cell's, so a red cell can never sit beside a
								# black bar.
								Html.div(
									"grid min-w-0 gap-1",
									[
										Html.p("Value", "label"),
										Html.p_s(bar.map(|shown| if (shown.value.is_empty()) "(empty)" else shown.value), [Engine.test_id("bar-value"), Engine.class_s(bar.map(|shown| SheetApp.value_tone_class(shown.kind)))]),
									],
								),
								SheetApp.readout("Depends on", bar.map(|shown| shown.depends), "bar-depends"),
							],
						),
					],
				),
			],
		),
	)

	## The three switches, and the tiles that say what the sheet and the
	## grid are doing.
	controls : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	controls = |{}| {
		sheet = SheetStore.cells.sheet.signal()
		mode = SheetStore.cells.mode.signal()
		listing = SheetStore.cells.listing.signal()
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
								SheetApp.switch_button(mode.map(mode_button), Engine.does(SheetStore.mode_switched)),
								SheetApp.switch_button(listing.map(rows_button), Engine.does(SheetStore.rows_switched)),
								SheetApp.switch_button(listing.map(order_button), Engine.does(SheetStore.order_switched)),
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
								SheetApp.stat_tile("Selection", { table: sheet, index: SheetStore.cells.selected.signal(), keyboard: SheetStore.cells.keyboard.signal() }.Signal.map(|reading| SheetStore.selection(reading.table, reading.keyboard.anchor, reading.index)), "stat-selection"),
								SheetApp.stat_tile("Selected cell", SheetStore.cells.selected.signal().map(Cells.ref_of), "stat-selected"),
								SheetApp.stat_tile("Grid mode", mode.map(mode_name), "stat-mode"),
								SheetApp.stat_tile("Formula errors", sheet.map(|table| SheetStore.error_count(table).to_str()), "status-line"),
								SheetApp.stat_tile("Rows shown", sheet.map2(listing, |table, asked| SheetStore.rows_listed(table, asked).to_str()), "stat-rows"),
							],
						),
					],
				),
			],
		)
	}

	## The grid: the rows the listing keeps, in its order, as a view of the
	## sheet's table. The sheet is short, so the view draws every row it
	## keeps.
	grid : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	grid = |{}| Html.section(
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
							Engine.element(
								"div",
								[Engine.class(SheetApp.grid_frame_class), Engine.attr("role", "grid"), Engine.on_key({ keymap: SheetStore.cells.editing.signal().map(SheetStore.keymap) }, SheetApp.key_handler(False))],
								[
									SheetApp.column_header({}),
									Engine.table_view(
										SheetStore.cells.sheet,
										{ query: SheetStore.cells.listing.signal(), plan: Sheet.plan, window: Engine.const(Engine.every_row) },
										SheetApp.row_line,
									),
								],
							),
						],
					),
				],
			),
		],
	)

	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Engine.element(
		"div",
		[Engine.class(SheetApp.page_class), Engine.on_document_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("`").with_ctrl(), Engine.Chord.plain("Escape")])) }, Engine.handle_by({ index: SheetStore.cells.selected.signal(), keyboard: SheetStore.cells.keyboard.signal() }.Signal, |reading, key| if (key.heard == Engine.Chord.plain("`").with_ctrl()) SheetStore.mode_switched else [SheetStore.cells.keyboard.set({ ..reading.keyboard, anchor: reading.index })]))],
		[
			Html.section(
				"Spreadsheet Lite",
				"app-header",
				[
					Engine.element("h1", [Engine.class("app-title")], [Engine.text("Spreadsheet Lite")]),
					Html.p("A quarterly budget on an 8 by 12 sheet, where every formula is a dependency edge. Editing a cell recomputes only the cells that transitively depend on it.", "app-subtitle"),
				],
			),
			Engine.on_post(SheetStore.cells.keyboard.signal().map(|keyboard| keyboard.commands), |commands| commands.map(command_request), Engine.ignore({})),
			SheetApp.formula_bar({}),
			SheetApp.controls({}),
			SheetApp.grid({}),
		],
	)

	## Route declared chords into pure transitions over a small keyboard reading.
	key_handler : Bool -> Engine.HandlerOf(ctx, Engine.Key)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	key_handler = |formula| Engine.handle_by(
		{ index: SheetStore.cells.selected.signal(), keyboard: SheetStore.cells.keyboard.signal(), editing: SheetStore.cells.editing.signal(), rows: SheetStore.cells.sheet.signal().map2(SheetStore.cells.listing.signal(), SheetStore.listed_rows) }.Signal,
		|reading, key| {
			if key.heard == Engine.Chord.plain("Escape") {
				SheetStore.cancelled(reading.index, reading.keyboard, reading.editing, if (formula) "formula-bar" else "cell-${Cells.ref_of(reading.index)}")
			} else if key.heard == Engine.Chord.plain("F2") or (key.heard == Engine.Chord.plain("Enter") and !formula) {
				[SheetStore.cells.keyboard.set({ ..reading.keyboard, commands: reading.keyboard.commands.post([Focus("formula-bar")]) })]
			} else {
				direction = if (key.heard == Engine.Chord.plain("ArrowLeft") or key.heard == Engine.Chord.plain("ArrowLeft").with_shift()) Left
				else if (key.heard == Engine.Chord.plain("ArrowRight") or key.heard == Engine.Chord.plain("ArrowRight").with_shift()) Right
				else if (Engine.Chord.plain("ArrowUp").primary().contains(key.heard)) First
				else if (Engine.Chord.plain("ArrowDown").primary().contains(key.heard)) Last
				else if (key.heard == Engine.Chord.plain("ArrowUp") or key.heard == Engine.Chord.plain("ArrowUp").with_shift()) Up
				else Down
				next = SheetStore.next_cell(reading.index, reading.rows, direction)
				if key.shift {
					SheetStore.extended(next, reading.keyboard)
				} else {
					SheetStore.moved(next, reading.keyboard)
				}
			}
		},
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| SheetStore.store, |_boot| SheetApp.view({}))
}

## The label of the mode button: the mode a click changes to.
mode_button : Sheet.Mode -> Str
mode_button = |mode|
	match mode {
		Values => "Show formulas"
		Formulas => "Show values"
	}

## The name of the mode on its tile.
mode_name : Sheet.Mode -> Str
mode_name = |mode|
	match mode {
		Values => "Values"
		Formulas => "Formulas"
	}

rows_button : Sheet.Listing -> Str
rows_button = |listing|
	match listing.rows {
		Every => "Hide empty rows"
		Filled => "Show all rows"
	}

order_button : Sheet.Listing -> Str
order_button = |listing|
	match listing.order {
		TopDown => "Reverse row order"
		BottomUp => "Top to bottom"
	}

## An error cell is tinted from its `kind` tag, never from its rendered text.
expect SheetApp.tone_class(Error, Unselected).contains("bg-red-50")

## Numbers are right-aligned so the columns line up on the decimal point.
expect SheetApp.tone_class(Number, Unselected).contains("text-right")

## Text is left-aligned, the opposite of the number alignment.
expect SheetApp.tone_class(Text, Unselected).contains("text-left")

## The selected cell gains a ring and a tint on top of whatever tone its kind gives it, and no other cell has them.
expect {
	ring = " relative z-10 bg-accent-50 ring-2 ring-inset ring-accent-600"
	(SheetApp.tone_class(Text, Selected).ends_with(ring), SheetApp.tone_class(Text, Unselected).contains("bg-accent-50")) == (True, False)
}

## Cleanup commands and posted commands share the request channel's command tags.
command_request : Engine.Command -> Engine.Request
command_request = |command| match command {
	Push(value) => Push(value)
	Replace(value) => Replace(value)
	Title(value) => Title(value)
	ViewTransition(types) => ViewTransition(types)
	Focus(value) => Focus(value)
	Blur(value) => Blur(value)
	SelectText(value) => SelectText(value)
	ApplyValue(value) => ApplyValue(value)
	FocusInPlace(value) => FocusInPlace(value)
	ScrollIntoView(value, props) => ScrollIntoView(value, props)
	ScrollTo(value, props) => ScrollTo(value, props)
	StorageSet(key, value) => StorageSet(key, value)
	StorageRemove(value) => StorageRemove(value)
	SessionStorageSet(key, value) => SessionStorageSet(key, value)
	SessionStorageRemove(key) => SessionStorageRemove(key)
	PortCommand(value) => PortCommand(value)
	Save(value) => Save(value)
}
