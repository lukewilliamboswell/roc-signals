app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	False,
	|visible| Gui.col(
		Gui.ColProps.{},
		[
			Gui.heading("Scoped dialog"),
			Gui.button("Open dialog", visible.update(|_| True)),
			Ui.when(
				visible.signal(),
				|| Ui.state(
					"",
					|draft| Gui.dialog(
						{
							label: "Confirm changes",
							on_dismiss: visible.update(|_| False),
							test_id: "confirmation",
						},
						[
							Gui.heading("Confirm changes"),
							Gui.textarea({ label: "Reason", value: draft.signal() }, draft.update_str(|_, value| value)),
							Gui.button("Keep editing", visible.update(|_| False)),
						],
					),
				),
				|| Gui.text("Dialog closed"),
			),
		],
	),
)
