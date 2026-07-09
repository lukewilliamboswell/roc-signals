app [main] { pf: platform "../../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

visible_piece : Str -> Str
visible_piece = |value|
	if value.is_empty() {
		"<empty>"
	} else {
		value
	}

location_path : Browser.Location -> Str
location_path = |location| "Path: ${visible_piece(location.path)}"

location_query : Browser.Location -> Str
location_query = |location| "Query: ${visible_piece(location.query)}"

location_hash : Browser.Location -> Str
location_hash = |location| "Hash: ${visible_piece(location.hash)}"

main : {} -> Elem
main = |_| {
	location = Browser.location

	Html.div_c(
		"",
		[
			Html.heading("Location Navigation"),
			Ui.on_mount(
				|_|
					Browser.replace_state(
						{
							path: "/services/web",
							query: "tab=deploys",
							hash: "events",
						},
					),
			),
			Html.text_s(location.map(location_path)),
			Html.text_s(location.map(location_query)),
			Html.text_s(location.map(location_hash)),
		],
	)
}
