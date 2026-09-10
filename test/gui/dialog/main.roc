app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	False,
	|visible| Gui.column(
		Gui.ColumnProps.{},
		[
			Gui.heading("Scoped dialog"),
			Gui.button("Open dialog", visible.on_unit(|_| True)),
			Ui.when(
				visible.signal(),
				|| Ui.state(
					"",
					|draft| Gui.dialog(
						{
							label: "Confirm changes",
							on_dismiss: visible.on_unit(|_| False),
							test_id: "confirmation",
						},
						[
							Gui.heading("Confirm changes"),
							Gui.textarea({ label: "Reason", value: draft.signal() }, draft.on_str(|_, value| value)),
							Gui.button("Keep editing", visible.on_unit(|_| False)),
						],
					),
				),
				|| Gui.text("Dialog closed"),
			),
		],
	),
)
