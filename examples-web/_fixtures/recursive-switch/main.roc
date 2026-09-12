app [main] { roc: "nightly-2026-09-11-793f9d8", pf: platform "../../../platform-web/main.roc" }

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
					Html.button("Grow", depth.update(|current| current + 1)),
					Html.button("Reset", depth.update(|_| 1)),
				],
			),
	)
