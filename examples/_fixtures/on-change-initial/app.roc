app [main] { pf: platform "../../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Model : { initial : Str, regular : Str }

initial_title : Str -> Str
initial_title = |value| "initial:${value}"

regular_title : Str -> Str
regular_title = |value| "regular:${value}"

main : {} -> Elem
main = |_| {
	Ui.state(
		{ initial: "mounted", regular: "mounted" },
		|model| {
			state = model.signal()
			initial = state.map(|value| value.initial)
			regular = state.map(|value| value.regular)

			Html.div_c(
				"",
				[
					Html.heading("On Change Initial"),
					Html.text_s(initial.map(|value| "Initial value: ${value}")),
					Html.text_s(regular.map(|value| "Regular value: ${value}")),
					Html.button("Change initial", model.on_unit(|value| { ..value, initial: "updated" })),
					Html.button("Change regular", model.on_unit(|value| { ..value, regular: "updated" })),
					Ui.on_change_initial(initial, |value| Browser.set_title(initial_title(value))),
					Ui.on_change(regular, |value| Browser.set_title(regular_title(value))),
				],
			)
		},
	)
}
