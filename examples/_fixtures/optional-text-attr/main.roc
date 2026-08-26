app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	query : Str,
	active : Bool,
}

initial_state : State
initial_state = {
	query: "",
	active: False,
}

set_query : State, Str -> State
set_query = |state, query| { ..state, query }

toggle_active : State -> State
toggle_active = |state| { ..state, active: !state.active }

active_descendant : State -> [None, Some(Str)]
active_descendant = |state|
	if state.active {
		Some("option-alpha")
	} else {
		None
	}

toggle_label : State -> Str
toggle_label = |state|
	if state.active {
		"Close options"
	} else {
		"Open options"
	}

main : () -> Elem
main = || {
	Ui.state(
		initial_state,
		|model| {
			state_signal : Signal.Signal(State)
			state_signal = model.signal()
			query_signal : Signal.Signal(Str)
			query_signal = state_signal.map(|state| state.query)
			active_descendant_signal : Signal.Signal([None, Some(Str)])
			active_descendant_signal = state_signal.map(active_descendant)
			button_label : Signal.Signal(Str)
			button_label = state_signal.map(toggle_label)

			Html.section(
				"Optional Text Attr",
				[Html.attr("data-fixture", "optional-text-attr")],
				[
					Html.heading("Optional Text Attr"),
					Html.text_input_attrs(
						"Assignee",
						query_signal,
						[
							Html.attr("id", "assignee-input"),
							Html.aria_activedescendant_s(active_descendant_signal),
						],
						model.on_str(set_query),
					),
					Html.div(
						[
							Html.attr("id", "option-alpha"),
							Html.attr("role", "option"),
						],
						[Html.text("Alpha teammate")],
					),
					Html.button_s(button_label, model.on_unit(toggle_active)),
				],
			)
		},
	)
}
