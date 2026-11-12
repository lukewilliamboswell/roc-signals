import pf.Engine exposing [Val]
import pf.Table
import Cells
import Formula
import Sheet

## Spreadsheet Lite's store: the state the formula bar, the controls and the
## grid share, held at the root and reached from any of them with no `lift`.
## (A cell of the store is one piece of this state; a cell of the sheet is
## `Sheet.Cell`.)
##
## - `sheet` is a table: the sheet's rows by row number. A row holds, for
##   each of its cells, what was typed and what that computes to, so an
##   edit is a write of the rows whose cells changed: the row typed into
##   and the rows that hold its dependents.
## - `selected` is the index of the cell the caret is in, and `editing`
##   whether that cell has the focus. A focus writes both; a blur writes
##   only `editing`, which the grid does not read.
## - `mode` is whether the grid shows values or formulas, and `listing`
##   which rows it lists and in what order.
##
## Every change to them is one of the transitions below: a pure function
## from what the event carries to the writes it makes.
SheetStore := [Workbook].{

	## Whether the selected cell has the focus.
	Focus : [Editing, Resting]

	## What the formula bar shows of the selected cell: its address, whether
	## it is being edited, what was typed into it, what that computes to
	## (with the kind that text came from), and the cells it reads.
	Bar : { ref : Str, focus : Focus, source : Str, value : Str, kind : Sheet.CellKind, depends : Str }

	store = Engine.store(
		SheetStore.Workbook,
		{
			sheet: Engine.table(Sheet.rows_of(Sheet.initial_cells)),
			selected: Engine.cell(0.U64),
			editing: Engine.cell(Resting),
			mode: Engine.cell(Values),
			listing: Engine.cell(Sheet.whole_sheet),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = SheetStore.store.handles()

	## Typing `text` into the cell at `index`, in the grid or in the formula
	## bar.
	typed : U64, Str -> List(Engine.Write(_))
	typed = |index, text| [SheetStore.h.sheet.change(|table| SheetStore.retyped(table, index, text))]

	## The cell at `index` taking the focus: the caret moves there and
	## editing starts, as one transition.
	focused : U64 -> List(Engine.Write(_))
	focused = |index| [SheetStore.h.selected.put(index), SheetStore.h.editing.put(Editing)]

	## The selected cell losing the focus. The caret stays where it is.
	blurred : List(Engine.Write(_))
	blurred = [SheetStore.h.editing.put(Resting)]

	## A click on the button that changes what the grid's cells show.
	mode_switched : List(Engine.Write(_))
	mode_switched = [SheetStore.h.mode.change(Sheet.other_mode)]

	## A click on the button that hides or lists the blank rows.
	rows_switched : List(Engine.Write(_))
	rows_switched = [SheetStore.h.listing.change(Sheet.with_rows_switched)]

	## A click on the button that reverses the rows.
	order_switched : List(Engine.Write(_))
	order_switched = [SheetStore.h.listing.change(Sheet.with_order_switched)]

	## `table` with `text` typed into the cell at `index` and the whole sheet
	## computed again. Only the rows that came out different are written,
	## each by its number, so a view of the table hears of the row typed
	## into and of the rows holding its dependents, and of no others. The
	## writes are a fold over the rows rather than a `while` loop over a
	## `var` holding the table, which copies the table on every iteration
	## in optimised builds (roc-lang/roc#12971).
	retyped : Table(U64, Sheet.Row), U64, Str -> Table(U64, Sheet.Row)
	retyped = |table, index, text| {
		sources = Sheet.with_source(SheetStore.sources_of(table), index, text)
		Sheet.rows_of(sources).fold(table, |written, { key, row }| if (written.get(key) == Ok(row)) written else written.put(key, row))
	}

	## What is typed into every cell of the sheet `table` holds.
	sources_of : Table(U64, Sheet.Row) -> List(Str)
	sources_of = |table| table.fold(Sheet.blank_sources, |sources, _number, row| Sheet.with_row(sources, row))

	## The cell at `index`: a blank one if the table holds no such cell.
	cell_at : Table(U64, Sheet.Row), U64 -> Sheet.Cell
	cell_at = |table, index|
		match table.get(index // Cells.col_count) {
			Ok(row) => row.get(index % Cells.col_count) ?? Sheet.blank_cell(index)
			Err(Missing) => Sheet.blank_cell(index)
		}

	## How many cells of the sheet compute to an error.
	error_count : Table(U64, Sheet.Row) -> U64
	error_count = |table| table.fold(0, |count, _number, row| count + row.count_if(|cell| cell.out.kind == Error))

	## How many rows `listing` lists.
	rows_listed : Table(U64, Sheet.Row), Sheet.Listing -> U64
	rows_listed = |table, listing| {
		asked = Sheet.plan(listing)
		table.fold(0, |count, number, row| if ((asked.keep)(number, row)) count + 1 else count)
	}

	bar_of : Sheet.Cell, Focus -> Bar
	bar_of = |cell, focus| { ref: Cells.ref_of(cell.index), focus, source: cell.source, value: cell.out.text, kind: cell.out.kind, depends: Formula.depends_on(cell.source) }

	## What the formula bar shows: the selected cell as the sheet holds it
	## now, and whether it is being edited.
	bar : {} -> Val(ctx, Bar)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	bar = |{}| {
		table: SheetStore.h.sheet.val(),
		index: SheetStore.h.selected.val(),
		focus: SheetStore.h.editing.val(),
	}.Val.map(|{ table, index, focus }| SheetStore.bar_of(SheetStore.cell_at(table, index), focus))
}

## The values the cells named show in the sheet a store holds.
values_at : Engine.Store(_, _), List(Str) -> List(Str)
values_at = |held, refs| {
	table = held.read(SheetStore.h.sheet)
	refs.map(
		|ref| match Cells.index_of(ref) {
			Ok(index) => SheetStore.cell_at(table, index).out.text
			Err(NotARef) => "not a cell: ${ref}"
		},
	)
}

## Where the caret is in a store, and whether that cell is being edited.
## Annotated, as `switches_of` is, because it uses `read` at two types,
## which a function cannot do on a parameter whose type is unknown.
caret_of : Engine.Store(_, _) -> Str
caret_of = |held| "${Cells.ref_of(held.read(SheetStore.h.selected))} ${Str.inspect(held.read(SheetStore.h.editing))}"

## What a store's grid shows and lists.
switches_of : Engine.Store(_, _) -> Str
switches_of = |held| "${Str.inspect(held.read(SheetStore.h.mode))} ${Str.inspect(held.read(SheetStore.h.listing))}"

## The store opens on the starting workbook, computed, with the caret resting in A1.
expect {
	opened = SheetStore.store
	actual =
		\\sources: ${Str.inspect(SheetStore.sources_of(opened.read(SheetStore.h.sheet)) == Sheet.initial_cells)}
		\\D2, D8, B9: ${Str.inspect(values_at(opened, ["D2", "D8", "B9"]))}
		\\errors: ${SheetStore.error_count(opened.read(SheetStore.h.sheet)).to_str()}
		\\caret: ${caret_of(opened)}
	expected =
		\\sources: True
		\\D2, D8, B9: ["2500", "1127.5", "#DIV/0!"]
		\\errors: 4
		\\caret: A1 Resting
	actual == expected
}

## Typing into B2 recomputes every cell that reads it, however far down the chain, and leaves the rest alone.
expect {
	typed = SheetStore.store.after(SheetStore.typed(9, "1500"))
	values_at(typed, ["B2", "D2", "B5", "D5", "F5", "D6", "D7", "D8", "C2", "D3"]) == ["1500", "2800", "2150", "4400", "4400", "440", "4840", "1210", "1300", "1200"]
}

## An edit writes the row typed into and the rows holding its dependents, and no others: rows 2, 5, 6, 7 and 8 for B2, and row 12 alone for C12.
expect {
	opened = Table.from_list(Sheet.rows_of(Sheet.initial_cells))
	written = |table| table.inverse().map_ok(|undo| undo.len())
	(written(SheetStore.retyped(opened, 9, "1500")), written(SheetStore.retyped(opened, 90, "9")), written(SheetStore.retyped(opened, 9, "1200"))) == (Ok(5), Ok(1), Ok(0))
}

## After any edits the table holds exactly the rows its own sources compute: nothing is left over from an earlier edit.
expect {
	edited = SheetStore.store.after(SheetStore.typed(9, "1500").concat(SheetStore.typed(26, "oops")).concat(SheetStore.typed(84, "=G4+1")))
	table = edited.read(SheetStore.h.sheet)
	Sheet.rows_of(SheetStore.sources_of(table)).all(|{ key, row }| table.get(key) == Ok(row))
}

## A focus moves the caret and starts editing as one transition, and a blur ends the editing where the caret is.
expect {
	focused = SheetStore.store.after(SheetStore.focused(11))
	blurred = focused.after(SheetStore.blurred)
	(caret_of(focused), caret_of(blurred)) == ("D2 Editing", "D2 Resting")
}

## The formula bar shows the selected cell's source, value and the cells it reads.
expect {
	bar = SheetStore.bar_of(SheetStore.cell_at(SheetStore.store.read(SheetStore.h.sheet), 35), Editing)
	bar == { ref: "D5", focus: Editing, source: "=SUM(D2:D4)", value: "4100", kind: Number, depends: "D2, D3, D4" }
}

## Each switch changes one thing, and a second click changes it back.
expect {
	once = SheetStore.store.after(SheetStore.mode_switched.concat(SheetStore.rows_switched).concat(SheetStore.order_switched))
	twice = once.after(SheetStore.mode_switched.concat(SheetStore.rows_switched).concat(SheetStore.order_switched))
	actual =
		\\opened: ${switches_of(SheetStore.store)}
		\\once: ${switches_of(once)}
		\\twice: ${switches_of(twice)}
	expected =
		\\opened: Values { order: TopDown, rows: Every }
		\\once: Formulas { order: BottomUp, rows: Filled }
		\\twice: Values { order: TopDown, rows: Every }
	actual == expected
}

## Hiding the blank rows lists eleven of the starting workbook's twelve.
expect {
	table = SheetStore.store.read(SheetStore.h.sheet)
	(SheetStore.rows_listed(table, Sheet.whole_sheet), SheetStore.rows_listed(table, Sheet.with_rows_switched(Sheet.whole_sheet))) == (12, 11)
}
