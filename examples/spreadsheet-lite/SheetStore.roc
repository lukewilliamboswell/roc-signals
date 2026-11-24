import pf.Clipboard
import pf.Engine exposing [Signal, Table]
import Cells
import Formula
import RangeText
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
	Focus : [Editing, Typing, Resting]

	## What the formula bar shows of the selected cell: its address, whether
	## it is being edited, what was typed into it, what that computes to
	## (with the kind that text came from), and the cells it reads.
	Bar : { ref : Str, focus : Focus, source : Str, value : Str, kind : Sheet.CellKind, depends : Str }

	Keyboard : { anchor : U64, saved : Str, pending : Bool, commands : Engine.Outbox(List(Engine.Command)) }

	keyboard_start : Keyboard
	keyboard_start = { anchor: 0, saved: "", pending: False, commands: Engine.outbox({}) }

	Selection : { anchor : U64, active : U64 }

	## The sheet a visit opens with. A top-level constant is evaluated while
	## compiling, so a row key `Sheet.rows_of` gave twice would be a compile
	## error naming it.
	opening : Table(U64, Sheet.Row)
	opening = match Table.from_list(Sheet.rows_of(Sheet.initial_cells)) {
		Ok(table) => table
		Err(DuplicateKey(key)) => crash "SheetStore.opening: the sheet's row ${key.to_str()} is listed twice"
	}

	store = Engine.store(
		SheetStore.Workbook,
		{
			sheet: Engine.table(SheetStore.opening),
			selected: Engine.cell(0.U64),
			editing: Engine.cell(Resting),
			keyboard: Engine.cell(SheetStore.keyboard_start),
			copies: Engine.cell(Engine.outbox({})),
			range_status: Engine.cell(""),
			mode: Engine.cell(Values),
			listing: Engine.cell(Sheet.whole_sheet),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = SheetStore.store.cells()

	## Both ends of the selection, independent of which rows the view lists.
	selected_range : {} -> Signal(ctx, Selection)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	selected_range = |{}| { anchor: SheetStore.cells.keyboard.signal().map(|held| held.anchor), active: SheetStore.cells.selected.signal() }.Signal

	## Copy the selected cell sources as a rectangle, including blank cells.
	copy_requested : Selection -> List(Engine.Write(_))
	copy_requested = |range| [SheetStore.cells.copies.update(|outbox| outbox.post(range))]

	copy_asks : Table(U64, Sheet.Row), Selection -> List(Engine.Ask({}, [NotAllowed, Unavailable, Refused, InvalidField, TooLarge]))
	copy_asks = |table, { anchor, active }| {
		bounds = Cells.bounds(anchor, active)
		sources = Cells.expand_range(anchor, active).map(|index| SheetStore.cell_at(table, index).source)
		match RangeText.copied(sources, bounds.right - bounds.left + 1) {
			Ok(text) => [Clipboard.text(text).map_err(|reason| reason)]
			Err(InvalidField) => [Engine.again({}).map(|_| Err(InvalidField))]
			Err(TooLarge) => [Engine.again({}).map(|_| Err(TooLarge))]
		}
	}

	copy_answered : Try({}, [NotAllowed, Unavailable, Refused, InvalidField, TooLarge]) -> List(Engine.Write(_))
	copy_answered = |result| [
		SheetStore.cells.range_status.set(
			match result {
				Ok({}) => "Copied selected cells"
				Err(NotAllowed) => "Clipboard permission was denied"
				Err(Unavailable) => "Clipboard is unavailable"
				Err(Refused) => "Clipboard is busy. Try again."
				Err(InvalidField) => "Selection contains a line break inside a cell"
				Err(TooLarge) => "Selection is too large to copy"
			},
		),
	]

	RangeEdit : { range : Selection, keyboard : Keyboard, focus : Focus }

	edit_selection : {} -> Signal(ctx, RangeEdit)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	edit_selection = |{}| { range: SheetStore.selected_range({}), keyboard: SheetStore.cells.keyboard.signal(), focus: SheetStore.cells.editing.signal() }.Signal

	## Clear cell sources in one table write and recompute dependents.
	cleared : RangeEdit -> List(Engine.Write(_))
	cleared = |at| range_written(
		at,
		{
			edits: Cells.expand_range(at.range.anchor, at.range.active).map(|index| { index, source: "" }),
			status: "Cleared selected cells",
		},
	)

	## Place a pasted rectangle at the selection's top-left address.
	pasted : RangeEdit, Engine.Paste -> List(Engine.Write(_))
	pasted = |at, paste| {
		bounds = Cells.bounds(at.range.anchor, at.range.active)
		parsed = match paste {
			Text(text) => RangeText.pasted(text, bounds.top * Cells.col_count + bounds.left)
			TooLarge => Err(TooLarge)
		}
		match parsed {
			Ok(edits) => range_written(at, { edits, status: "Pasted cells" })
			Err(problem) => [
				SheetStore.cells.range_status.set(
					match problem {
						TooLarge => "Pasted text is too large to import"
						Ragged => "Pasted rows must have the same number of cells"
						OutsideSheet => "Pasted cells would extend past the sheet"
						InvalidField => "Pasted cells contain invalid quotes or a line break"
					},
				),
			]
		}
	}

	## Typing `text` into the cell at `index`, in the grid or in the formula
	## bar.
	typed : U64, Str -> List(Engine.Write(_))
	typed = |index, text| [SheetStore.cells.sheet.update(|table| SheetStore.retyped(table, index, text)), SheetStore.cells.editing.update(|_| Typing)]

	## The cell at `index` taking the focus: the caret moves there and
	## editing starts, as one transition.
	focused : U64 -> List(Engine.Write(_))
	focused = |index| [SheetStore.cells.selected.set(index), SheetStore.cells.editing.set(Editing)]

	## Capture a small source snapshot on focus; keyboard navigation preserves
	## the range anchor already chosen by its initiating turn.
	focused_source : U64, Str, Keyboard -> List(Engine.Write(_))
	focused_source = |index, source, keyboard| SheetStore.focused(index).concat([
		SheetStore.cells.keyboard.set({ ..keyboard, anchor: if (keyboard.pending) keyboard.anchor else index, saved: source, pending: False }),
	])

	## Listed row numbers in exactly the view's declared order.
	listed_rows : Table(U64, Sheet.Row), Sheet.Listing -> List(U64)
	listed_rows = |table, listing| {
		plan = Sheet.plan(listing)
		numbers = table.fold([], |rows, number, row| if ((plan.keep)(number, row)) rows.append(number) else rows)
		numbers.sort_with(|a, b| if (a == b) Same else if ((a < b) == (listing.order == TopDown)) Before else After)
	}

	## Move within the listed rows, clamping at an edge rather than leaving it.
	next_cell : U64, List(U64), [Left, Right, Up, Down, First, Last] -> U64
	next_cell = |index, rows, direction| {
		row = index // Cells.col_count
		col = index % Cells.col_count
		(position, _) = rows.fold((0.U64, False), |(offset, found), number| if (found or number == row) (offset, True) else (offset + 1, False))
		match direction {
			Left => if (col > 0) index - 1 else index
			Right => if (col + 1 < Cells.col_count) index + 1 else index
			Up => (rows.get(if (position > 0) position - 1 else 0) ?? row) * Cells.col_count + col
			Down => (rows.get(position + 1) ?? row) * Cells.col_count + col
			First => (rows.first() ?? row) * Cells.col_count + col
			Last => (rows.last() ?? row) * Cells.col_count + col
		}
	}

	## A move selects one cell and posts focus in the same transition.
	moved : U64, Keyboard -> List(Engine.Write(_))
	moved = |index, keyboard| [SheetStore.cells.selected.set(index), SheetStore.cells.keyboard.set({ ..keyboard, anchor: index, pending: True, commands: keyboard.commands.post([Focus("cell-${Cells.ref_of(index)}")]) })]

	## Extending moves the active end while retaining the range's anchor.
	extended : U64, Keyboard -> List(Engine.Write(_))
	extended = |index, keyboard| [SheetStore.cells.selected.set(index), SheetStore.cells.keyboard.set({ ..keyboard, pending: True, commands: keyboard.commands.post([Focus("cell-${Cells.ref_of(index)}")]) })]

	## Escape restores a typed source in place; otherwise it collapses a range.
	cancelled : U64, Keyboard, Focus, Str -> List(Engine.Write(_))
	cancelled = |index, keyboard, editing, reference| {
		restore = if (editing == Typing) [SheetStore.cells.sheet.update(|table| SheetStore.retyped(table, index, keyboard.saved))] else []
		restore.concat([SheetStore.cells.editing.set(Editing), SheetStore.cells.keyboard.set({ ..keyboard, anchor: index, commands: keyboard.commands.post([ApplyValue(reference)]) })])
	}

	## A small rendered map controls whether left/right move the selection or
	## remain the text control's ordinary caret keys after typing starts.
	keymap : Focus -> Engine.Keymap
	keymap = |editing| {
		arrows = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]
		Engine.Keymap.prevent(
			[Engine.Chord.plain("Enter"), Engine.Chord.plain("F2"), Engine.Chord.plain("Escape")]
				.concat(arrows.map(|key| Engine.Chord.plain(key).with_shift()))
				.concat([Engine.Chord.plain("ArrowUp"), Engine.Chord.plain("ArrowDown")])
				.concat(
					if (editing == Typing) [] else
						[Engine.Chord.plain("ArrowLeft"), Engine.Chord.plain("ArrowRight"), Engine.Chord.plain("Delete")]
							.concat(Engine.Chord.plain("c").primary()),
				)
				.concat(Engine.Chord.plain("ArrowUp").primary()).concat(Engine.Chord.plain("ArrowDown").primary()),
		)
	}

	## The rectangle's address and numeric sum, computed from its two ends.
	selection : Table(U64, Sheet.Row), U64, U64 -> Str
	selection = |table, anchor, selected| {
		indices = Cells.expand_range(anchor, selected)
		first = indices.first() ?? selected
		last = indices.last() ?? selected
		sum = indices.fold(
			0.I128,
			|total, index| match Cells.read_number(SheetStore.cell_at(table, index).out.text) {
				Ok(number) => total + number.to_i128()
				Err(_) => total
			},
		)
		"${Cells.ref_of(first)}${if (first == last) "" else ":${Cells.ref_of(last)}"} · ${Cells.format_total(sum)}"
	}

	## The selected cell losing the focus. The caret stays where it is.
	blurred : List(Engine.Write(_))
	blurred = [SheetStore.cells.editing.set(Resting)]

	## A click on the button that changes what the grid's cells show.
	mode_switched : List(Engine.Write(_))
	mode_switched = [SheetStore.cells.mode.update(Sheet.other_mode)]

	## A click on the button that hides or lists the blank rows.
	rows_switched : List(Engine.Write(_))
	rows_switched = [SheetStore.cells.listing.update(Sheet.with_rows_switched)]

	## A click on the button that reverses the rows.
	order_switched : List(Engine.Write(_))
	order_switched = [SheetStore.cells.listing.update(Sheet.with_order_switched)]

	## `table` with `text` typed into the cell at `index` and the whole sheet
	## computed again. Only the rows that came out different are written,
	## each by its number, so a view of the table hears of the row typed
	## into and of the rows holding its dependents, and of no others. The
	## writes are a fold over the rows rather than a `while` loop over a
	## `var` holding the table, which copies the table on every iteration
	## in optimised builds (roc-lang/roc#12971).
	retyped : Table(U64, Sheet.Row), U64, Str -> Table(U64, Sheet.Row)
	retyped = |table, index, text| rewritten(table, [{ index, source: text }])

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
	bar : {} -> Signal(ctx, Bar)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	bar = |{}| {
		table: SheetStore.cells.sheet.signal(),
		index: SheetStore.cells.selected.signal(),
		focus: SheetStore.cells.editing.signal(),
	}.Signal.map(|{ table, index, focus }| SheetStore.bar_of(SheetStore.cell_at(table, index), focus))
}

## Apply the edits to the sources before running the dependency evaluator.
## Only changed rows are written, as for a single edit.
rewritten : Table(U64, Sheet.Row), List(RangeText.Edit) -> Table(U64, Sheet.Row)
rewritten = |table, edits| {
	sources = edits.fold(SheetStore.sources_of(table), |held, edit| Sheet.with_source(held, edit.index, edit.source))
	Sheet.rows_of(sources).fold(table, |written, { key, row }| if (written.get(key) == Ok(row)) written else written.put(key, row))
}

## A range edit commits immediately. If it edits the focused cell, land its
## new rendered value there and replace the snapshot Escape restores.
range_written : SheetStore.RangeEdit, { edits : List(RangeText.Edit), status : Str } -> List(Engine.Write(_))
range_written = |{ range, keyboard, focus }, { edits, status }| {
	writes = [SheetStore.cells.sheet.update(|table| rewritten(table, edits)), SheetStore.cells.range_status.set(status)]
	match edits.find_first(|edit| edit.index == range.active) {
		Ok(edit) if focus != Resting => writes.concat([
			SheetStore.cells.editing.set(Editing),
			SheetStore.cells.keyboard.set({
				..keyboard,
				saved: edit.source,
				commands: keyboard.commands.post([ApplyValue("cell-${Cells.ref_of(range.active)}")]),
			}),
		])
		_ => writes
	}
}

## The values the cells named show in the sheet a store holds.
values_at : Engine.Store(_, _), List(Str) -> List(Str)
values_at = |held, refs| {
	table = held.read(SheetStore.cells.sheet)
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
caret_of = |held| "${Cells.ref_of(held.read(SheetStore.cells.selected))} ${Str.inspect(held.read(SheetStore.cells.editing))}"

## What a store's grid shows and lists.
switches_of : Engine.Store(_, _) -> Str
switches_of = |held| "${Str.inspect(held.read(SheetStore.cells.mode))} ${Str.inspect(held.read(SheetStore.cells.listing))}"

## The store opens on the starting workbook, computed, with the caret resting in A1.
expect {
	opened = SheetStore.store
	actual =
		\\sources: ${Str.inspect(SheetStore.sources_of(opened.read(SheetStore.cells.sheet)) == Sheet.initial_cells)}
		\\D2, D8, B9: ${Str.inspect(values_at(opened, ["D2", "D8", "B9"]))}
		\\errors: ${SheetStore.error_count(opened.read(SheetStore.cells.sheet)).to_str()}
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
	opened = SheetStore.opening
	written = |table| table.inverse().map_ok(|undo| undo.len())
	(written(SheetStore.retyped(opened, 9, "1500")), written(SheetStore.retyped(opened, 90, "9")), written(SheetStore.retyped(opened, 9, "1200"))) == (Ok(5), Ok(1), Ok(0))
}

## After any edits the table holds exactly the rows its own sources compute: nothing is left over from an earlier edit.
expect {
	edited = SheetStore.store.after(SheetStore.typed(9, "1500").concat(SheetStore.typed(26, "oops")).concat(SheetStore.typed(84, "=G4+1")))
	table = edited.read(SheetStore.cells.sheet)
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
	bar = SheetStore.bar_of(SheetStore.cell_at(SheetStore.store.read(SheetStore.cells.sheet), 35), Editing)
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
	table = SheetStore.store.read(SheetStore.cells.sheet)
	(SheetStore.rows_listed(table, Sheet.whole_sheet), SheetStore.rows_listed(table, Sheet.with_rows_switched(Sheet.whole_sheet))) == (12, 11)
}

## A move selects and focuses one cell without leaving the old range anchored.
expect {
	moved = SheetStore.store.after(SheetStore.moved(9, SheetStore.keyboard_start))
	(moved.read(SheetStore.cells.selected), moved.read(SheetStore.cells.keyboard).anchor, moved.read(SheetStore.cells.keyboard).commands.last()) == (9, 9, Posted([Focus("cell-B2")]))
}

## Extending retains its anchor while changing the active end.
expect {
	keyboard = { ..SheetStore.keyboard_start, anchor: 9 }
	extended = SheetStore.store.after(SheetStore.extended(27, keyboard))
	(extended.read(SheetStore.cells.selected), extended.read(SheetStore.cells.keyboard).anchor) == (27, 9)
}

## Cancelling restores the captured source and asks to land it without moving focus.
expect {
	keyboard = { ..SheetStore.keyboard_start, anchor: 9, saved: "1200" }
	typed = SheetStore.store.after(SheetStore.typed(9, "999"))
	cancelled = typed.after(SheetStore.cancelled(9, keyboard, Typing, "cell-B2"))
	(values_at(cancelled, ["B2"]), cancelled.read(SheetStore.cells.keyboard).commands.last()) == (["1200"], Posted([ApplyValue("cell-B2")]))
}

## Bulk edits recompute in one table write and update the active cell's
## Escape snapshot. The total includes the pasted negative cell.
expect {
	at = { range: { anchor: 95, active: 94 }, keyboard: SheetStore.keyboard_start, focus: Editing }
	pasted = SheetStore.store.after(SheetStore.pasted(at, Text("-3\t2")))
	clipped = pasted.read(SheetStore.cells.sheet)
	cleared = pasted.after(SheetStore.cleared(at))
	{
		changed: clipped.inverse().map_ok(|changes| changes.len()),
		selection: SheetStore.selection(clipped, 95, 94),
		saved: pasted.read(SheetStore.cells.keyboard).saved,
		blank: values_at(cleared, ["G12", "H12"]),
	} == { changed: Ok(1), selection: "G12:H12 · -1", saved: "-3", blank: ["", ""] }
}
