app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

## A static helper annotated for the root, as an author would write today.
badge : Str -> Elem(Ui.Root)
badge = |label| Html.element("span", [Html.class_attr("badge")], [Html.text(label)])

## Negative: reusing that root-annotated helper inside a row template.
main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		Rows.empty(|item| item.id),
		|model|
			Ui.each(
				model.signal(),
				|row| Html.element("li", [], [Html.text_s(row.field(|value| value.name)), badge("new")]),
			),
	)
}
