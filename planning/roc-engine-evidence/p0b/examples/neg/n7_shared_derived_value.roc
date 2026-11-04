app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

## Probe: one let-bound site value, converted once with `to_val`, used both at
## the root and inside a row. Values are not generalized, so this should fail;
## converting at each use (or keeping it a `Signal`) is the fix.
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|item| item.id),
		|model| {
			count = model.signal().map(|rows| "${rows.len().to_str()} items").to_val()
			Html.div(
				[],
				[
					Html.text_s(count),
					Ui.each(model.signal(), |row| Html.element("li", [], [Html.text_s(row.field(|value| value.name)), Html.text_s(count)])),
				],
			)
		},
	)
}
