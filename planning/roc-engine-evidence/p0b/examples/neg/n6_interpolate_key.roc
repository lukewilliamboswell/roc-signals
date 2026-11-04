app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

## Negative: the old habit of interpolating the key into a static attribute.
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|item| item.id),
		|model|
			Ui.each(
				model.signal(),
				|row| Html.element("li", [Html.test_id("row-${row.key()}")], [Html.text_s(row.field(|value| value.name))]),
			),
	)
}
