app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
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
	label = Signal.map(item_signal, |item| item.label)
	Html.section(
		key,
		[],
		[
			Html.paragraph_s(label),
		],
	)
}

main : {} -> Elem
main = |_| {
	Ui.state(
		duplicate_items,
		|items| {
			Html.div(
				[],
				[
					Html.heading("Duplicate each key fixture"),
					Ui.each_str(items.signal(), |item| item.id, render_row),
				],
			)
		},
	)
}
