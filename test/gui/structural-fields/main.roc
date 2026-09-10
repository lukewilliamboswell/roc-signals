app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|first| Gui.column(
		Gui.ColumnProps.{},
		[
			Gui.button("Switch branch", first.on_unit(|value| !value)),
			Ui.when(
				first.signal(),
				|| Gui.panel(
					{
						test_id: "styled-branch",
						selected: Signal.const(True),
						padding: 12,
						background: Rgb(0x24323E),
						border_color: Default,
						border_width: 0,
						radius: 0,
					},
					[Gui.text("First branch")],
				),
				|| Gui.panel(
					{
						test_id: "styled-branch",
						selected: Signal.const(False),
						padding: 20,
						background: Rgb(0x354452),
						border_color: Default,
						border_width: 0,
						radius: 0,
					},
					[Gui.text("Second branch")],
				),
			),
		],
	),
)
