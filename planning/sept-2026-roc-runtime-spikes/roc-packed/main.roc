app [main] { pf: platform "platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui
import TaskPanel

## Acceptance input: no graph model, node IDs, registration or update loop.
main : () -> Elem
main = || Ui.state(True, |visible| Html.div([], [
	Ui.state(0.U64, |state| Html.div([], [
		Html.text_s(Signal.map(state.signal(), |n| "Count: ${n.to_str()}")),
		Html.button("Increment", state.update(|n| n + 1)),
		Html.button("Keep count", state.update(|n| n)),
	])),
	Html.button("Show/hide First", visible.update(|v| !v)),
	Ui.when(visible.signal(), || TaskPanel.view("First"), || Html.text("First hidden")),
	TaskPanel.view("Second"),
]))
