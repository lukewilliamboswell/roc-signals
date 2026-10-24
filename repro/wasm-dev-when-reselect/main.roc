app [main] { pf: platform "../../platform-web/main.roc" }

import pf.Elem
import pf.Html
import pf.Ui

main : () -> Elem
main = || Ui.state(
	True,
	|visible| Html.div_c(
		"",
		[
			Html.button("T", visible.update(|value| !value)),
			Html.div([Html.test_id("s")], [Ui.when(visible.signal(), || Html.text("on"), || Html.text("off"))]),
		],
	),
)
