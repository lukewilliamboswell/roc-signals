app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	billing : Str,
	changes : I64,
}

initial_state : State
initial_state = {
	billing: "monthly",
	changes: 0,
}

set_billing : State, Str -> State
set_billing = |state, value| { ..state, billing: value, changes: state.changes + 1 }

billing_label : Str -> Str
billing_label = |value| "Billing cadence: ${value}"

changes_label : I64 -> Str
changes_label = |value| "Changes: ${value.to_str()}"

main : () -> Elem
main = || {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			billing_signal = state_signal.map(|state| state.billing)
			billing_text = billing_signal.map(billing_label)
			changes_text = state_signal.map(|state| changes_label(state.changes))

			Html.section(
				"Radio Group Control",
				[Html.attr("data-fixture", "radio-group-control")],
				[
					Html.heading("Radio Group Control"),
					Html.radio("Monthly", "billing", "monthly", billing_signal, model.on_str(set_billing)),
					Html.radio("Annual", "billing", "annual", billing_signal, model.on_str(set_billing)),
					Html.paragraph_s(billing_text),
					Html.paragraph_s(changes_text),
				],
			)
		},
	)
}
