app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	clicks : I64,
	submits : I64,
}

initial_state : State
initial_state = {
	clicks: 0,
	submits: 0,
}

record_click : State -> State
record_click = |state| { ..state, clicks: state.clicks + 1 }

record_submit : State -> State
record_submit = |state| { ..state, submits: state.submits + 1 }

label_i64 : Str, I64 -> Str
label_i64 = |label, value| Str.concat(label, value.to_str())

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			clicks_text = Signal.map(state_signal, |state| label_i64("Clicks: ", state.clicks))
			submits_text = Signal.map(state_signal, |state| label_i64("Submits: ", state.submits))

			Html.section(
				"Submit Button Default",
				[Html.attr("data-fixture", "submit-button-default")],
				[
					Html.heading("Submit Button Default"),
					Html.form_label(
						"Default submit form",
						[
							Html.attr("id", "default-submit-form"),
							Html.on_submit_prevent_default(model.on_unit(record_submit)),
						],
						[
							Html.button_attrs(
								"Send via implicit submit",
								[],
								model.on_unit(record_click),
							),
							Html.button_attrs(
								"Send via explicit submit",
								[Html.attr("type", "submit")],
								model.on_unit(record_click),
							),
							Html.button_attrs(
								"Click without submit",
								[Html.attr("type", "button")],
								model.on_unit(record_click),
							),
							Html.paragraph_s(clicks_text),
							Html.paragraph_s(submits_text),
						],
					),
				],
			)
		},
	)
}
