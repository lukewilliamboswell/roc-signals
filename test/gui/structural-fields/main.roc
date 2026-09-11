app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|first| Elem.col(
		Elem.ColProps.{},
		[
			Elem.button("Switch branch", first.update(|value| !value)),
			Ui.when(
				first.signal(),
				|| Elem.panel(
					{
						test_id: "styled-branch",
						selected: Signal.const(True),
						padding: 12,
						bg: Rgb(0x24323E),
					},
					["First branch"],
				),
				|| Elem.panel(
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
