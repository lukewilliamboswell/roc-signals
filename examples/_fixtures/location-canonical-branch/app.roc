app [main] { pf: platform "../../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

overview : Browser.Location
overview = { path: "/", query: "", hash: "" }

is_detail : Browser.Location -> Bool
is_detail = |location| location.path == "/services/workers"

canonical_location : Browser.Location -> Browser.Location
canonical_location = |location|
	if location.path == "/" or is_detail(location) {
		location
	} else {
		overview
	}

main : () -> Elem
main = || {
	location = Browser.location()
	show_detail = location.map(is_detail)
	canonical = location.map(canonical_location)

	Html.div_c(
		"",
		[
			Html.text_s(location.map(|value| "Path: ${value.path}")),
			Ui.when(
				show_detail,
				|| Html.paragraph("Detail branch"),
				|| Html.paragraph("Overview branch"),
			),
			Ui.on_change(canonical, Browser.replace_state),
		],
	)
}
