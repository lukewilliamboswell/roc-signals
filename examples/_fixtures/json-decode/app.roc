app [main] { pf: platform "../../../platform/main.roc" }

import JsonProbe
import pf.Elem exposing [Elem]
import pf.Html

main : {} -> Elem
main = |_| {
	Html.div(
		[],
		List.concat(
			[Html.heading("Json decode fixture")],
			List.map(JsonProbe.rows, Html.paragraph),
		),
	)
}
