app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

## Negative: root-only `Ui.state` used inside a row template (old style).
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|item| item.id),
		|model|
			Ui.each(
				model.signal(),
				|row|
					Ui.state(
						False,
						|open| Html.element("li", [], [Html.text_s(row.field(|value| value.name)), Html.button("Toggle", open.update(|o| !o))]),
					),
			),
	)
}
