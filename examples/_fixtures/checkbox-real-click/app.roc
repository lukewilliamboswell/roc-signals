app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	accepted : Bool,
	changes : I64,
}

initial_state : State
initial_state = {
	accepted: False,
	changes: 0,
}

record_checked : State, Bool -> State
record_checked = |state, accepted| { ..state, accepted, changes: state.changes + 1 }

status_label : Bool -> Str
status_label = |accepted|
	if accepted {
		"Accepted: true"
	} else {
		"Accepted: false"
	}

changes_label : I64 -> Str
changes_label = |changes| "Changes: ${changes.to_str()}"

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal : Signal.Signal(State)
			state_signal = model.signal()
			accepted_signal : Signal.Signal(Bool)
			accepted_signal = state_signal.map(|state| state.accepted)
			status_text : Signal.Signal(Str)
			status_text = accepted_signal.map(status_label)
			changes_text : Signal.Signal(Str)
			changes_text = state_signal.map(|state| changes_label(state.changes))

			Html.section(
				"Checkbox Real Click",
				[Html.attr("data-fixture", "checkbox-real-click")],
				[
					Html.heading("Checkbox Real Click"),
					Html.checkbox("Accept terms", accepted_signal, model.on_bool(record_checked)),
					Html.paragraph_s(status_text),
					Html.paragraph_s(changes_text),
				],
			)
		},
	)
}
