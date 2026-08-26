## Route model for Package Explorer.
##
## Two real routes plus a not-found sink. Routing is app code: `Browser.location`
## is the single source of truth, and every in-app link publishes a navigation
## intent that `main.roc` turns into exactly one `Browser.push_state`.
import pf.Browser

Route := [Search, Package(Str), Unknown].{
	## Structural equality. A route is compared on the signal-invalidation hot
	## path, so it matches on the tags directly rather than encoding each side
	## to a string first.
	is_eq : Route, Route -> Bool
	is_eq = |left, right|
		match left {
			Search => match right {
				Search => True
				_ => False
			}
			Package(left_id) => match right {
				Package(right_id) => left_id == right_id
				_ => False
			}
			Unknown => match right {
				Unknown => True
				_ => False
			}
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

expect Route.from_location({ path: "/", query: "", hash: "" }) == Search
expect Route.from_location({ path: "/packages/roc-json", query: "", hash: "" }) == Package("roc-json")
expect Route.from_location({ path: "/packages/", query: "", hash: "" }) == Unknown
expect Route.from_location({ path: "/packages/roc-json/versions", query: "", hash: "" }) == Unknown
expect Route.from_location({ path: "/nope", query: "", hash: "" }) == Unknown
expect Route.to_location(Package("roc-http")).path == "/packages/roc-http"
expect Route.from_location(Route.to_location(Package("roc-http"))) == Package("roc-http")
expect Package("roc-json") != Package("roc-http")
expect Route.title(Package("roc-json")) == "roc-json - Package Explorer"
