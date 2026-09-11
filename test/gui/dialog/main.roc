app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Ui

main : () -> Elem
main = || Ui.state(
	False,
	|visible| Elem.col(
		Elem.ColProps.{},
		[
			Elem.heading("Scoped dialog"),
			Elem.button("Open dialog", visible.update(|_| True)),
			Ui.when(
				visible.signal(),
				|| Ui.state(
					"",
					|draft| Elem.dialog(
						{
							label: "Confirm changes",
							on_dismiss: visible.update(|_| False),
							test_id: "confirmation",
						},
						[
							Elem.heading("Confirm changes"),
							Elem.textarea({ label: "Reason", value: draft.signal() }, draft.update_str(|_, value| value)),
							Elem.button("Keep editing", visible.update(|_| False)),
						],
					),
				),
				|| Elem.text("Dialog closed"),
			),
		],
	),
)
