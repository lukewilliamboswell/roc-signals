app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	name : Str,
	accepted : Bool,
	reset_clicks : I64,
	resets : I64,
}

initial_state : State
initial_state = {
	name: "",
	accepted: False,
	reset_clicks: 0,
	resets: 0,
}

set_name : State, Str -> State
set_name = |state, name| { ..state, name }

set_accepted : State, Bool -> State
set_accepted = |state, accepted| { ..state, accepted }

record_reset_click : State -> State
record_reset_click = |state| { ..state, reset_clicks: state.reset_clicks + 1 }

record_reset : State -> State
record_reset = |state| { ..initial_state, reset_clicks: state.reset_clicks, resets: state.resets + 1 }

count_label : Str, I64 -> Str
count_label = |label, value| "${label}${value.to_str()}"

main : () -> Elem
main = || {
	Ui.state(
		initial_state,
		|model| {
			state_signal : Signal.Signal(State)
			state_signal = model.signal()
			name_signal : Signal.Signal(Str)
			name_signal = state_signal.map(|state| state.name)
			accepted_signal : Signal.Signal(Bool)
			accepted_signal = state_signal.map(|state| state.accepted)
			reset_clicks_text : Signal.Signal(Str)
			reset_clicks_text = state_signal.map(|state| count_label("Reset clicks: ", state.reset_clicks))
			resets_text : Signal.Signal(Str)
			resets_text = state_signal.map(|state| count_label("Resets: ", state.resets))

			Html.section(
				"Form Reset Default",
				[Html.attr("data-fixture", "form-reset-default")],
				[
					Html.heading("Form Reset Default"),
					Html.form_label(
						"Reset default form",
						[
							Html.attr("id", "reset-default-form"),
							Html.on_event("reset", Html.event_policy_prevent_default, model.on_unit(record_reset)),
						],
						[
							Html.text_input("Name", name_signal, model.on_str(set_name)),
							Html.checkbox("Accept reset terms", accepted_signal, model.on_bool(set_accepted)),
							Html.button_attrs(
								"Reset form",
								[Html.attr("type", "reset")],
								model.on_unit(record_reset_click),
							),
							Html.paragraph_s(reset_clicks_text),
							Html.paragraph_s(resets_text),
						],
					),
				],
			)
		},
	)
}
