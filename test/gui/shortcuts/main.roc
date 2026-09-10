app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|visible| {
		Gui.col(
			Gui.ColProps.{},
			[
				Gui.heading("Scoped shortcuts"),
				Gui.button("Toggle editor", visible.update(|value| !value)),
				Ui.when(
					visible.signal(),
					|| Ui.state(
						0.U64,
						|count| {
							Ui.state(
								"",
								|draft| {
									Gui.col(
										{
											test_id: "keyboard-region",
											shortcuts: [{ chord: { key: "s", control: True, shift: False, alt: False, meta: False }, msg: count.update(|value| value + 1) }, { chord: { key: "s", control: True, shift: True, alt: False, meta: False }, msg: count.update(|value| value + 10) }],
										},
										[
											"Control+S adds one; Control+Shift+S adds ten.",
											Gui.textarea({ label: "Draft", value: draft.signal() }, draft.update_str(|_, value| value)),
											Gui.button("Add one", count.update(|value| value + 1)),
											Gui.panel({ test_id: "shortcut-count" }, [Gui.text_s(count.signal().map(|value| "Count: ${value.to_str()}"))]),
										],
									)
								},
							)
						},
					),
					|| Gui.text("Editor closed"),
				),
			],
		)
	},
)
