app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = ||
	Ui.state(
		"A",
		|first|
			Ui.state(
				"B",
				|second| {
					pair = { first: first.signal(), second: second.signal() }.Signal
					observed = Signal.fake_task("write-observer", |value| value, |err| err)
					invalid = Signal.fake_task("partial-write", |value| value, |err| err)
					reset_writes : List(Ui.StateWrite)
					reset_writes = [first.set("A"), second.set("B")]
					reset = Ui.update_states(reset_writes)
					reset_first = first.set_cmd("A")
					Html.div_c(
						"",
						[
							Html.paragraph_s_attrs(Signal.map(pair, |value| "${value.first}:${value.second}"), [Html.test_id("pair")]),
							Html.paragraph_s(Signal.fold_task(observed, "waiting", |value| value, |err| err)),
							Html.paragraph_s(Signal.fold_task(invalid, "valid", |value| value, |err| err)),
							Ui.on_change(
								pair,
								|value|
									if value.first == value.second {
										Signal.start_str(invalid, "partial write observed")
									} else {
										Signal.start_str(observed, "${value.first}:${value.second}")
									},
							),
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
