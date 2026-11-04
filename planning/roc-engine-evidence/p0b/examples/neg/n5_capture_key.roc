app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

remove : Rows(Item), Str -> Rows(Item)
remove = |rows, key| Rows.apply(rows, [RemoveKey(key)]) ?? rows

## Negative: the old habit of capturing the key in a per-row closure.
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|item| item.id),
		|model|
			Ui.each(
				model.signal(),
				|row| {
					key = row.key()
					Html.button("Remove", model.update(|rows| remove(rows, key)))
				},
			),
	)
}
