app [main] { pf: platform "../../../platform/main.roc" }

import JsonProbe
import pf.Elem exposing [Elem]
import pf.Html

main : () -> Elem
main = || {
	Html.div(
		[],
		[Html.heading("Json decode fixture")].concat(JsonProbe.rows.map(Html.paragraph)),
	)
}
