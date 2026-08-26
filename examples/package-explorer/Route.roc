## Route model for Package Explorer.
##
## Two real routes plus a not-found sink. Routing is app code: `Browser.location`
## is the single source of truth, and every in-app link publishes a navigation
## intent that `app.roc` turns into exactly one `Browser.push_state`.
import pf.Browser

Route := [Search, Package(Str), Unknown].{
	is_eq : Route, Route -> Bool
	is_eq = |left, right| Route.key(left) == Route.key(right)

	key : Route -> Str
	key = |route|
		match route {
			Search => "search"
			Package(id) => "package:${id}"
			Unknown => "unknown"
		}

	search_location : Browser.Location
	search_location = { path: "/", query: "", hash: "" }

	package_location : Str -> Browser.Location
	package_location = |id| { path: "/packages/${id}", query: "", hash: "" }

	to_location : Route -> Browser.Location
	to_location = |route|
		match route {
			Search => Route.search_location
			Package(id) => Route.package_location(id)
			Unknown => Route.search_location
		}

	from_location : Browser.Location -> Route
	from_location = |location|
		if location.path == "/" {
			Search
		} else if location.path.starts_with("/packages/") {
			Route.package_route(location.path.drop_prefix("/packages/"))
		} else {
			Unknown
		}

	package_route : Str -> Route
	package_route = |segment|
		if segment.is_empty() {
			Unknown
		} else {
			match segment.split_first("/") {
				Ok(_) => Unknown
				Err(_) => Package(segment)
			}
		}

	package_id : Route -> Str
	package_id = |route|
		match route {
			Package(id) => id
			_ => ""
		}

	is_package : Route -> Bool
	is_package = |route|
		match route {
			Package(_) => True
			_ => False
		}

	title : Route -> Str
	title = |route|
		match route {
			Search => "Package Explorer"
			Package(id) => "${id} - Package Explorer"
			Unknown => "Package Explorer"
		}
}
