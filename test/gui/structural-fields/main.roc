app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|first| Gui.column(
		[],
		[
			Gui.button("Switch branch", first.on_unit(|value| !value)),
			Ui.when(
				first.signal(),
				|| Gui.panel(
					[
						Gui.test_id("styled-branch"),
						Gui.style({ ..Gui.style_default, padding: 12, background: Rgb(0x24323E) }),
						Gui.selected_s(Signal.const(True)),
					],
					[Gui.text("First branch")],
				),
				|| Gui.panel(
					[
						Gui.test_id("styled-branch"),
						Gui.style({ ..Gui.style_default, padding: 20, background: Rgb(0x354452) }),
						Gui.selected_s(Signal.const(False)),
					],
					[Gui.text("Second branch")],
				),
			),
		],
	),
)
