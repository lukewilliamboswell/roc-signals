app [main] { pf: platform "../../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

visible_piece : Str -> Str
visible_piece = |value|
	if Str.is_empty(value) {
		"<empty>"
	} else {
		value
	}

location_path : Browser.Location -> Str
location_path = |location| concat3("Path: ", visible_piece(location.path), "")

location_query : Browser.Location -> Str
location_query = |location| concat3("Query: ", visible_piece(location.query), "")

location_hash : Browser.Location -> Str
location_hash = |location| concat3("Hash: ", visible_piece(location.hash), "")

main : {} -> Elem
main = |_| {
	location = Browser.location

	Html.div_c(
		"",
		[
			Html.heading("Location Source"),
			Html.text_s(Signal.map(location, location_path)),
			Html.text_s(Signal.map(location, location_query)),
			Html.text_s(Signal.map(location, location_hash)),
		],
	)
}
