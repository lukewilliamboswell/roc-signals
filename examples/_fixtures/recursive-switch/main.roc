app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

recursive_tree : U64 -> Elem
recursive_tree = |depth|
	Ui.switch(
		Signal.const(depth),
		|selected|
			if selected == 0 {
				Html.paragraph_s_attrs(Signal.const("leaf"), [Html.test_id("recursive-leaf")])
			} else {
				Html.div_c("recursive-level", [Html.text("level ${selected.to_str()}"), recursive_tree(selected - 1)])
			},
	)

main : () -> Elem
main = ||
	Ui.state(
		3,
		|depth|
			Html.section(
				"Recursive switch",
				[],
				[
					Html.heading("Recursive switch"),
					Ui.switch(depth.signal(), recursive_tree),
					Html.button("Grow", depth.on_unit(|current| current + 1)),
					Html.button("Reset", depth.on_unit(|_| 1)),
				],
			),
	)
