app [main] { pf: platform "../../platform-gui/main.roc", roc: "nightly-2026-09-09-7dadc35" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Gui.column(
	[],
	[
		Ui.each(
			Signal.const(Rows.from_list(["a", "b"], |item| item) ?? crash "unique"),
			|_row| Gui.text("row"),
		),
	],
)
