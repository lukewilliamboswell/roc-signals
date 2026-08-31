app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

Row : { id : Str, label : Str }

## The condition and the row list reach Ui.when by two DIFFERENT derived chains
## off the same source, so they are recomputed independently in one batch. That
## is the shape two gallery apps hit; a single shared chain does not reproduce.
rows_of : Bool -> List(Row)
rows_of = |full|
	if full {
		[
			{ id: "r1", label: "one" },
			{ id: "r2", label: "two" },
			{ id: "r3", label: "three" },
		]
	} else {
		[]
	}

decorate : List(Row), Str -> List(Row)
decorate = |rows, suffix| rows.map(|row| { id: row.id, label: "${row.label}${suffix}" })

count_of : Bool -> U64
count_of = |full| if full { 3 } else { 0 }

positive : U64 -> Bool
positive = |n| n > 0

label_of : Row -> Str
label_of = |row| "Row: ${row.label}"

row_key : Row -> Str
row_key = |row| row.id

keep : Str, Str -> Str
keep = |current, _value| current

toggle : Bool -> Bool
toggle = |value| !value

main : () -> Elem
main = || {
	Ui.state(
		True,
		|full| {
			Ui.state(
				"!",
				|suffix| {
					# chain A: source -> rows -> map2 with a second source -> Ui.each
					rows : Signal.Signal(List(Row))
					rows = Signal.map2(Signal.map(full.signal(), rows_of), suffix.signal(), decorate)
					# chain B: source -> count -> bool -> Ui.when condition
					any : Signal.Signal(Bool)
					any = Signal.map(Signal.map(full.signal(), count_of), positive)

					Html.section(
						"When Each",
						[],
						[
							Html.heading("When Each"),
							Ui.when(
								any,
								|| Ui.each(Signal.map(rows, |rows_items| Rows.from_list(rows_items, row_key) ?? crash "duplicate row key"), |each_row| Html.div_c(
										"",
										[
											Html.paragraph_s_attrs(
												each_row.map(label_of),
												[Html.test_id("row-${each_row.key()}")],
											),
											Html.text_input(
												"Note for ${each_row.key()}",
												each_row.map(label_of),
												suffix.on_str(keep),
											),
										],
									)),
								|| Html.paragraph_s_attrs(Signal.const("No rows"), [Html.test_id("empty")]),
							),
							Html.button("Toggle", full.on_unit(toggle)),
						],
					)
				},
			)
		},
	)
}
