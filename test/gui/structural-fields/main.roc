app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|first| Gui.col(
		Gui.ColProps.{},
		[
			Gui.button("Switch branch", first.update(|value| !value)),
			Ui.when(
				first.signal(),
				|| Gui.panel(
					{
						test_id: "styled-branch",
						selected: Signal.const(True),
						padding: 12,
						bg: Rgb(0x24323E),
					},
					["First branch"],
				),
				|| Gui.panel(
					{
						test_id: "styled-branch",
						selected: Signal.const(False),
						padding: 20,
						bg: Rgb(0x354452),
					},
					["Second branch"],
				),
			),
		],
	),
)
