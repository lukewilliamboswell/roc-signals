app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

Item : {
	id : Str,
	label : Str,
}

duplicate_items : List(Item)
duplicate_items = [
	{ id: "alert-42", label: "Primary alert" },
	{ id: "alert-42", label: "Duplicate alert" },
]

render_row : Str, Signal.Signal(Item) -> Elem
render_row = |key, item_signal| {
	label = item_signal.map(|item| item.label)
	Html.section(
		key,
		[],
		[
			Html.paragraph_s(label),
		],
	)
}

main : () -> Elem
main = || {
	Ui.state(
		duplicate_items,
		|items| {
			Html.div(
				[],
				[
					Html.heading("Duplicate each key fixture"),
					Ui.each(Signal.map(items.signal(), |rows_items| Rows.from_list(rows_items, |item| item.id) ?? crash "duplicate row key"), |each_row| render_row(each_row.key(), each_row.signal())),
				],
			)
		},
	)
}
