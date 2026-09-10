app [main] { pf: platform "../../platform-web/main.roc", roc: "nightly-2026-09-09-7dadc35" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Ui

main : () -> Elem
main = || Ui.state(
	{ rows: Rows.from_list([1, 2], |item| item.to_str()) ?? crash "unique" },
	|model| {
		rows = model.signal().map(|value| value.rows)
		Html.div_c(
			"rows",
			[Ui.each(rows, |row| Html.text_s(row.signal().map(|item| item.to_str())))],
		)
	},
)
