app [main] { pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Gui.column(
			[Gui.style({ ..Gui.style_default, padding: 24 })],
			[
				Gui.heading("Counter"),
				Gui.text_s(count.signal().map(|value| "Count: ${value.to_str()}")),
				Gui.button("Increment", count.on_unit(|value| value + 1)),
				Gui.button("Decrement", count.on_unit(|value| value - 1)),
				Gui.button("Reset", count.on_unit(|_| 0)),
			],
		)
	},
)
