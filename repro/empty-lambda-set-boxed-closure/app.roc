app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = || Ui.state(
	{ serial: 0, path: "/" },
	|st| Html.link(
		"go",
		[
			Html.attr("href", "/x"),
			Html.on_event(
				"click",
				Html.event_policy_prevent_default,
				st.on_unit(|cur| { serial: cur.serial + 1, path: "/x" }),
			),
		],
	),
)
