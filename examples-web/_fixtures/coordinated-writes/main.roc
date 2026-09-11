app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-04-c125b82" }

import pf.Action
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	[],
	|history| {
		Ui.state(
			"A",
			|first|
				Ui.state(
					"B",
					|second| {
						pair = { first: first.signal(), second: second.signal() }.Signal
						reset_writes : List(Ui.StateWrite)
						reset_writes = [first.set("A"), second.set("B")]
						reset = Ui.update_states(reset_writes)
						reset_first = first.set_cmd("A")
						Html.div_c(
							"",
							[
								Html.paragraph_s_attrs(Signal.map(pair, |value| "${value.first}:${value.second}"), [Html.test_id("pair")]),
								Html.paragraph_s_attrs(history.signal().map(|items| Str.join_with(items, ";")), [Html.test_id("observed")]),
								Action.on_change(pair, |_| Action.then([], |snapshot| record!(history, snapshot))),
								Html.button("Swap", Ui.action(pair, |value|
									Ui.update_states([first.set(value.second), second.set(value.first)]))),
								Html.button("Swap reversed", Ui.action(pair, |value|
									Ui.update_states([second.set(value.first), first.set(value.second)]))),
								Html.button("Cached reset", Ui.action(pair, |_value| reset)),
								Html.button("Cached single", Ui.action(pair, |_value| reset_first)),
								Ui.when(
									Signal.map(first.signal(), |value| value == "B"),
									|| Html.paragraph_s_attrs(second.signal(), [Html.test_id("branch-value")]),
									|| Html.text("Branch hidden"),
								),
							],
						)
					},
				),
		)
	},
)

Pair : { first : Str, second : Str }

record! : Ui.State(List(Str)), Pair => Action(Pair)
record! = |history, snapshot| Action.update([
	history.write(|items| items.append("${snapshot.first}:${snapshot.second}")),
])
