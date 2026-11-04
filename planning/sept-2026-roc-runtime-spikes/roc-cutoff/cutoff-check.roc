app [main] { pf: platform "platform/cutoff-check.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## A conservative non-reflexive comparison must still cause source propagation.
Count := [Count(U64)].{
	is_eq : Count, Count -> Bool
	is_eq = |_left, _right| False
}

main : () -> Elem
main = || {
	initial : Count
	initial = Count.Count(0.U64)
	Ui.state(initial, view)
}

view : Ui.State(Count) -> Elem
view = |state| Html.div([], [
	Html.text_s(Signal.map(state.signal(), |Count.Count(n)| n.to_str())),
	Html.button("Same", state.update(|value| value)),
	Html.button("Increment", state.update(|Count.Count(n)| Count.Count(n + 1))),
])
