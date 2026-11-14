## The sheet. Whole-sheet evaluation resolves every cell in dependency order,
## detecting reference cycles, and hands back display-ready output. The
## sheet's rows hold that output beside what was typed, one row of cells
## under each row number, and a listing says which rows a grid shows and in
## what order. Nothing here knows the engine.
import Cells
import Formula

Sheet := [].{

	## What kind of thing a cell computed to. Presentation is derived from this
	## tag, never from the rendered text, so the red tint and the `#DIV/0!` it
	## tints can never disagree. `to_str` is the single encode point for the
	## `data-kind` attribute the specs assert on.
	CellKind := [Empty, Number, Text, Error].{
		is_eq : _

		to_str : CellKind -> Str
		to_str = |kind|
			match kind {
				Empty => "empty"
				Number => "number"
				Text => "text"
				Error => "error"
			}
	}

	## Display-ready cell output: the text to show and a coarse kind tag.
	CellOut : { text : Str, kind : CellKind }

	source_at : List(Str), U64 -> Str
	source_at = |sources, index| sources.get(index) ?? ""

	put_slot : List(Formula.Slot), U64, Formula.Slot -> List(Formula.Slot)
	put_slot = |slots, index, slot| slots.set(index, slot) ?? slots

	## Resolve one cell, walking its dependency edges first. A dependency that is
	## still `Busy` means this cell is part of a reference cycle.
	eval_index : List(Str), List(Formula.Slot), U64 -> List(Formula.Slot)
	eval_index = |sources, slots, index|
		match slots.get(index) {
			Ok(Ready(_)) => slots
			Ok(Busy) => slots
			_ => {
				source = Sheet.source_at(sources, index).trim()
				if !source.starts_with("=") {
					Sheet.put_slot(slots, index, Ready(Formula.literal_value(source)))
				} else {
					tokens = Formula.tokenize(source.drop_prefix("="))
					deps = Formula.refs_of(tokens)
					var $slots = Sheet.put_slot(slots, index, Busy)
					var $cycle = False
					var $dep = 0

					while $dep < deps.len() {
						cell = deps.get($dep) ?? 0

						match $slots.get(cell) {
							Ok(Busy) => {
								$cycle = True
							}
							Ok(Ready(_)) => {}
							_ => {
								$slots = Sheet.eval_index(sources, $slots, cell)
							}
						}

						$dep = $dep + 1
					}

					result =
						if $cycle {
							Bad("#CYCLE!")
						} else {
							Formula.eval_tokens(tokens, $slots)
						}
					Sheet.put_slot($slots, index, Ready(result))
				}
			}
		}

	## Evaluate the whole sheet in dependency order.
	evaluate : List(Str) -> List(Formula.Value)
	evaluate = |sources| {
		var $slots = []
		var $fill = 0

		while $fill < Cells.cell_count {
			$slots = $slots.append(Pending)
			$fill = $fill + 1
		}

		var $index = 0

		while $index < Cells.cell_count {
			$slots = Sheet.eval_index(sources, $slots, $index)
			$index = $index + 1
		}

		$slots.map(
			|slot|
				match slot {
					Ready(value) => value
					_ => Empty
				},
		)
	}

	## Display text and kind for one value.
	to_out : Formula.Value -> CellOut
	to_out = |value|
		match value {
			Empty => { text: "", kind: Empty }
			Number(number) => { text: Cells.format_number(number), kind: Number }
			Text(text) => { text, kind: Text }
			Bad(message) => { text: message, kind: Error }
		}

	## Evaluate a sheet straight to display-ready outputs.
	evaluate_out : List(Str) -> List(CellOut)
	evaluate_out = |sources| Sheet.evaluate(sources).map(Sheet.to_out)

	## One cell as its row holds it: its place on the sheet (its index,
	## counting across each row in turn), the text typed into it, and what
	## that text computes to.
	Cell : { index : U64, source : Str, out : CellOut }

	## One row of the sheet: its cells from column A across. A row is found
	## by its number, counting from 0.
	Row : List(Cell)

	## The rows of the sheet whose cells hold `sources`, every cell computed.
	rows_of : List(Str) -> List({ key : U64, row : Row })
	rows_of = |sources|
		List.map2(sources, Sheet.evaluate_out(sources), |source, out| { source, out })
			.map_with_index(|{ source, out }, index| { index, source, out })
			.chunks_of(Cells.col_count)
			.map_with_index(|row, key| { key, row })

	## The sources of a sheet with nothing typed in it.
	blank_sources : List(Str)
	blank_sources = List.repeat("", Cells.cell_count)

	## `sources` with `text` in the cell at `index`. An index past the last
	## cell names no cell, so it changes nothing.
	with_source : List(Str), U64, Str -> List(Str)
	with_source = |sources, index, text| sources.set(index, text) ?? sources

	## `sources` with what was typed into each cell of `row`. Folded over a
	## sheet's rows from `blank_sources`, in any order, it gives the sources
	## `rows_of` was given.
	with_row : List(Str), Row -> List(Str)
	with_row = |sources, row| row.fold(sources, |held, cell| Sheet.with_source(held, cell.index, cell.source))

	## Whether nothing is typed anywhere in a row.
	is_blank : Row -> Bool
	is_blank = |row| row.all(|cell| cell.source.is_empty())

	## A cell at `index` with nothing typed in it.
	blank_cell : U64 -> Cell
	blank_cell = |index| { index, source: "", out: Sheet.to_out(Empty) }

	## What a grid shows in each cell: what it computes to, or what was
	## typed into it.
	Mode : [Values, Formulas]

	## The text a grid in `mode` shows for a cell.
	shown : Cell, Mode -> Str
	shown = |cell, mode|
		match mode {
			Values => cell.out.text
			Formulas => cell.source
		}

	## The mode the grid's mode button changes to.
	other_mode : Mode -> Mode
	other_mode = |mode|
		match mode {
			Values => Formulas
			Formulas => Values
		}

	## Which rows a grid lists and in what order. It is plain data, so a
	## view of the rows can tell a changed listing from the same one.
	Listing : { rows : [Every, Filled], order : [TopDown, BottomUp] }

	## The listing a grid opens with: every row, from the top down.
	whole_sheet : Listing
	whole_sheet = { rows: Every, order: TopDown }

	## The listing with its blank rows hidden if they were listed, and
	## listed if they were hidden.
	with_rows_switched : Listing -> Listing
	with_rows_switched = |listing| {
		..listing,
		rows: match listing.rows {
			Every => Filled
			Filled => Every
		},
	}

	## The listing in the opposite order.
	with_order_switched : Listing -> Listing
	with_order_switched = |listing| {
		..listing,
		order: match listing.order {
			TopDown => BottomUp
			BottomUp => TopDown
		},
	}

	## A row number with the listing's direction, independent of the platform.
	Place := { number : U64, descending : Bool }.{
		is_eq : _

		## Reverse by comparison, preserving the full unsigned row number.
		order_relative_to : Place, Place -> [Before, Same, After]
		order_relative_to = |left, right| {
			if left.descending != right.descending {
				return if (left.descending) After else Before
			}
			if (left.descending) right.number.order_relative_to(left.number) else left.number.order_relative_to(right.number)
		}
	}

	## The filtered row numbers, in the direction the listing chose.
	plan : Listing -> { keep : U64, Row -> Bool, sort : U64, Row -> Place }
	plan = |{ rows, order }| {
		keep: |_number, row| match rows {
			Every => True
			Filled => !Sheet.is_blank(row)
		},
		sort: |number, _row| { number, descending: order == BottomUp },
	}

	## The starting workbook: a small quarterly budget plus deliberate error,
	## cycle, empty-reference, and isolated-cell cases.
	initial_cells : List(Str)
	initial_cells = [
		# Row 1
		"Item",
		"Q1",
		"Q2",
		"Total",
		"",
		"Checks",
		"",
		"",
		# Row 2
		"Rent",
		"1200",
		"1300",
		"=B2+C2",
		"",
		"=2+3*4",
		"",
		"",
		# Row 3
		"Cloud",
		"400",
		"=B3*2",
		"=B3+C3",
		"",
		"=(2+3)*4",
		"",
		"",
		# Row 4
		"Travel",
		"250",
		"150",
		"=B4+C4",
		"",
		"=10/4",
		"",
		"",
		# Row 5
		"Subtotal",
		"=SUM(B2:B4)",
		"=SUM(C2:C4)",
		"=SUM(D2:D4)",
		"",
		"=SUM(B2:C4)",
		"",
		"",
		# Row 6
		"Tax",
		"",
		"",
		"=D5*0.1",
		"",
		"",
		"",
		"",
		# Row 7
		"Total due",
		"",
		"",
		"=D5+D6",
		"",
		"",
		"",
		"",
		# Row 8
		"People",
		"4",
		"",
		"=D7/B8",
		"",
		"",
		"",
		"",
		# Row 9
		"Divide by zero",
		"=1/0",
		"=B9+1",
		"",
		"",
		"",
		"",
		"",
		# Row 10
		"Cycle",
		"=C10+1",
		"=B10+1",
		"",
		"",
		"",
		"",
		"",
		# Row 11
		"",
		"",
		"",
		"",
		"",
		"",
		"",
		"",
		# Row 12
		"Spare",
		"=E12+5",
		"7",
		"",
		"",
		"",
		"",
		"",
	]
}

## The empty kind encodes as the `data-kind` value the specs read.
expect Sheet.CellKind.to_str(Empty) == "empty"

## The number kind encodes as the `data-kind` value the specs read.
expect Sheet.CellKind.to_str(Number) == "number"

## The text kind encodes as the `data-kind` value the specs read.
expect Sheet.CellKind.to_str(Text) == "text"

## The error kind encodes as the `data-kind` value the specs read.
expect Sheet.CellKind.to_str(Error) == "error"

## A one-hop sum of two literal cells computes as a number.
expect Sheet.evaluate_out(Sheet.initial_cells).get(11) == Ok({ text: "2500", kind: Number })

## A non-numeric literal stays text, so it is neither summed nor right-aligned.
expect Sheet.evaluate_out(Sheet.initial_cells).get(8) == Ok({ text: "Rent", kind: Text })

## A rectangular SUM adds every member of the range.
expect Sheet.evaluate_out(Sheet.initial_cells).get(37) == Ok({ text: "4100", kind: Number })

## A three-hop chain resolves in dependency order, not sheet order.
expect Sheet.evaluate_out(Sheet.initial_cells).get(59) == Ok({ text: "1127.5", kind: Number })

## A divide by zero reports the error at the cell that performed it.
expect Sheet.evaluate_out(Sheet.initial_cells).get(65) == Ok({ text: "#DIV/0!", kind: Error })

## An error propagates to the cells that read it, rather than being read as zero.
expect Sheet.evaluate_out(Sheet.initial_cells).get(66) == Ok({ text: "#DIV/0!", kind: Error })

## Two cells that reference each other are reported as a cycle, not left pending.
expect Sheet.evaluate_out(Sheet.initial_cells).get(73) == Ok({ text: "#CYCLE!", kind: Error })

## A formula reading an empty cell treats it as zero.
expect Sheet.evaluate_out(Sheet.initial_cells).get(89) == Ok({ text: "5", kind: Number })

## A cell with no source evaluates to the empty kind, not to text.
expect Sheet.evaluate_out(Sheet.initial_cells).get(80) == Ok({ text: "", kind: Empty })

## The sheet's rows are twelve rows of eight cells under the row numbers from 0, each cell at its index with its source and what it computes to.
expect {
	rows = Sheet.rows_of(Sheet.initial_cells)
	actual =
		\\numbers: ${Str.inspect(rows.map(|entry| entry.key))}
		\\widths: ${Str.inspect(rows.map(|entry| entry.row.len()))}
		\\D2: ${Str.inspect(rows.map(|entry| entry.row).join().get(11))}
	expected =
		\\numbers: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
		\\widths: [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]
		\\D2: Ok({ index: 11, out: { kind: Number, text: "2500" }, source: "=B2+C2" })
	actual == expected
}

## Reading the rows back, in any order, gives the sources they were built from.
expect Sheet.rows_of(Sheet.initial_cells).rev().fold(Sheet.blank_sources, |held, entry| Sheet.with_row(held, entry.row)) == Sheet.initial_cells

## Row 11 of the starting workbook is the only row with nothing typed in it.
expect Sheet.rows_of(Sheet.initial_cells).keep_if(|entry| Sheet.is_blank(entry.row)).map(|entry| entry.key) == [10]

## A listing of the filled rows from the bottom up leaves out the blank row and reverses the rest.
expect {
	asked = Sheet.plan({ rows: Filled, order: BottomUp })
	listed = Sheet.rows_of(Sheet.initial_cells)
		.keep_if(|entry| (asked.keep)(entry.key, entry.row))
		.map(|entry| (asked.sort)(entry.key, entry.row))
		.sort()
		.map(|place| place.number)
	listed == [11, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
}

## A grid showing values shows what a cell computes to; one showing formulas, what was typed.
expect {
	cell = { index: 11, source: "=B2+C2", out: { text: "2500", kind: Number } }
	(Sheet.shown(cell, Values), Sheet.shown(cell, Formulas)) == ("2500", "=B2+C2")
}
