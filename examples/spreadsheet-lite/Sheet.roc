## Whole-sheet evaluation: resolve every cell in dependency order, detecting
## reference cycles, and hand back display-ready output.
import Cells
import Formula

Sheet := [].{

	## Display-ready cell output: the text to show and a coarse kind tag.
	CellOut : { text : Str, kind : Str }

	source_at : List(Str), U64 -> Str
	source_at = |sources, index|
		match sources.get(index) {
			Ok(value) => value
			Err(_) => ""
		}

	put_slot : List(Formula.Slot), U64, Formula.Slot -> List(Formula.Slot)
	put_slot = |slots, index, slot|
		match slots.set(index, slot) {
			Ok(updated) => updated
			Err(_) => slots
		}

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
					var $cycle = Cells.no
					var $dep = 0

					while $dep < deps.len() {
						cell =
							match deps.get($dep) {
								Ok(value) => value
								Err(_) => 0
							}

						match $slots.get(cell) {
							Ok(Busy) => {
								$cycle = Cells.yes
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
			Empty => { text: "", kind: "empty" }
			Number(number) => { text: Cells.format_number(number), kind: "number" }
			Text(text) => { text, kind: "text" }
			Bad(message) => { text: message, kind: "error" }
		}

	## Evaluate a sheet straight to display-ready outputs.
	evaluate_out : List(Str) -> List(CellOut)
	evaluate_out = |sources| Sheet.evaluate(sources).map(Sheet.to_out)

	## The starting workbook: a small quarterly budget plus deliberate error,
	## cycle, empty-reference, and isolated-cell cases.
	initial_cells : List(Str)
	initial_cells = [
		# Row 1
		"Item", "Q1", "Q2", "Total", "", "Checks", "", "",
		# Row 2
		"Rent", "1200", "1300", "=B2+C2", "", "=2+3*4", "", "",
		# Row 3
		"Cloud", "400", "=B3*2", "=B3+C3", "", "=(2+3)*4", "", "",
		# Row 4
		"Travel", "250", "150", "=B4+C4", "", "=10/4", "", "",
		# Row 5
		"Subtotal", "=SUM(B2:B4)", "=SUM(C2:C4)", "=SUM(D2:D4)", "", "=SUM(B2:C4)", "", "",
		# Row 6
		"Tax", "", "", "=D5*0.1", "", "", "", "",
		# Row 7
		"Total due", "", "", "=D5+D6", "", "", "", "",
		# Row 8
		"People", "4", "", "=D7/B8", "", "", "", "",
		# Row 9
		"Divide by zero", "=1/0", "=B9+1", "", "", "", "", "",
		# Row 10
		"Cycle", "=C10+1", "=B10+1", "", "", "", "", "",
		# Row 11
		"", "", "", "", "", "", "", "",
		# Row 12
		"Spare", "=E12+5", "7", "", "", "", "", "",
	]
}
