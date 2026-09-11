app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|visible| {
		Elem.col(
			Elem.ColProps.{},
			[
				Elem.heading("Scoped shortcuts"),
				Elem.button("Toggle editor", visible.update(|value| !value)),
				Ui.when(
					visible.signal(),
					|| Ui.state(
						0.U64,
						|count| {
							Ui.state(
								"",
								|draft| {
									Elem.col(
										{
											test_id: "keyboard-region",
											shortcuts: [{ chord: { key: "s", control: True, shift: False, alt: False, meta: False }, msg: count.update(|value| value + 1) }, { chord: { key: "s", control: True, shift: True, alt: False, meta: False }, msg: count.update(|value| value + 10) }],
										},
										[
											"Control+S adds one; Control+Shift+S adds ten.",
											Elem.textarea({ label: "Draft", value: draft.signal() }, draft.update_str(|_, value| value)),
											Elem.button("Add one", count.update(|value| value + 1)),
											Elem.panel({ test_id: "shortcut-count" }, [Elem.text_s(count.read(|value| "Count: ${value.to_str()}"))]),
										],
									)
								},
							)
						},
					),
					|| Elem.text("Editor closed"),
				),
			],
		)
	},
)
