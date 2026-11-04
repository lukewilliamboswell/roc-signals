app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

Group : { id : Str, title : Str, items : Rows(Item) }

## Negative: an inner row reads the enclosing row's field without `item.outer`.
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|group| group.id),
		|model|
			Ui.each(
				model.signal(),
				|group|
					Ui.each(
						group.field(|value| value.items),
						|item| Html.element("li", [], [Html.text_s(item.field(|value| value.name)), Html.text_s(group.field(|value| value.title))]),
					),
			),
	)
}
