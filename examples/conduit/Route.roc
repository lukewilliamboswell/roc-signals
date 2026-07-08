## Conduit route model: `Browser.Location` <-> `Route` parsing and formatting
## plus per-route document titles. Routing stays app code by design
## (wip/REALWORLD_DEMO_PLAN.md): no router DSL, no platform route table.
import pf.Browser

Route := [
	Home(Route.Feed),
	Login,
	Register,
	Settings,
	EditorNew,
	EditorEdit(Str),
	Article(Str),
	Profile(Str),
	ProfileFavorites(Str),
	NotFound,
].{
	Feed : { page : U64, tag : [AllTags, Tagged(Str)] }

	default_feed : Route.Feed
	default_feed = { page: 1, tag: AllTags }

	home : Route
	home = Home(default_feed)

	home_location : Browser.Location
	home_location = { path: "/", query: "", hash: "" }

	login_location : Browser.Location
	login_location = { path: "/login", query: "", hash: "" }

	register_location : Browser.Location
	register_location = { path: "/register", query: "", hash: "" }

	from_location : Browser.Location -> Route
	from_location = |location| {
		path = location.path
		if path == "/" {
			Home(parse_feed(location.query))
		} else if path == "/login" {
			Login
		} else if path == "/register" {
			Register
		} else if path == "/settings" {
			Settings
		} else if path == "/editor" {
			EditorNew
		} else if Str.starts_with(path, "/editor/") {
			slug_route(Str.drop_prefix(path, "/editor/"), |slug| EditorEdit(slug))
		} else if Str.starts_with(path, "/article/") {
			slug_route(Str.drop_prefix(path, "/article/"), |slug| Article(slug))
		} else if Str.starts_with(path, "/profile/") {
			profile_route(Str.drop_prefix(path, "/profile/"))
		} else {
			NotFound
		}
	}

	to_location : Route -> Browser.Location
	to_location = |route|
		match route {
			Home(feed) => { path: "/", query: feed_query(feed), hash: "" }
			Login => login_location
			Register => register_location
			Settings => { path: "/settings", query: "", hash: "" }
			EditorNew => { path: "/editor", query: "", hash: "" }
			EditorEdit(slug) => { path: "/editor/${slug}", query: "", hash: "" }
			Article(slug) => { path: "/article/${slug}", query: "", hash: "" }
			Profile(username) => { path: "/profile/${username}", query: "", hash: "" }
			ProfileFavorites(username) => { path: "/profile/${username}/favorites", query: "", hash: "" }
			NotFound => home_location
		}

	title : Route -> Str
	title = |route|
		match route {
			Home(_) => "Conduit"
			Login => "Sign in - Conduit"
			Register => "Sign up - Conduit"
			Settings => "Settings - Conduit"
			EditorNew => "New article - Conduit"
			EditorEdit(_) => "Edit article - Conduit"
			Article(slug) => "${slug} - Conduit"
			Profile(username) => "@${username} - Conduit"
			ProfileFavorites(username) => "@${username} favorites - Conduit"
			NotFound => "Page not found - Conduit"
		}

	kind : Route -> Str
	kind = |route|
		match route {
			Home(_) => "home"
			Login => "login"
			Register => "register"
			Settings => "settings"
			EditorNew => "editor-new"
			EditorEdit(_) => "editor-edit"
			Article(_) => "article"
			Profile(_) => "profile"
			ProfileFavorites(_) => "profile-favorites"
			NotFound => "not-found"
		}

	feed_of : Route -> Route.Feed
	feed_of = |route|
		match route {
			Home(feed) => feed
			_ => default_feed
		}

	article_slug : Route -> Str
	article_slug = |route|
		match route {
			EditorEdit(slug) => slug
			Article(slug) => slug
			_ => ""
		}

	profile_username : Route -> Str
	profile_username = |route|
		match route {
			Profile(username) => username
			ProfileFavorites(username) => username
			_ => ""
		}

	slug_route : Str, (Str -> Route) -> Route
	slug_route = |slug, make|
		if valid_segment(slug) {
			make(slug)
		} else {
			NotFound
		}

	profile_route : Str -> Route
	profile_route = |rest|
		match Str.find_first(rest, "/") {
			Ok(split) =>
				if split.after == "favorites" and valid_segment(split.before) {
					ProfileFavorites(split.before)
				} else {
					NotFound
				}
			Err(_) =>
				if valid_segment(rest) {
					Profile(rest)
				} else {
					NotFound
				}
		}

	valid_segment : Str -> Bool
	valid_segment = |segment|
		if Str.is_empty(segment) {
			False
		} else {
			match Str.find_first(segment, "/") {
				Ok(_) => False
				Err(_) => True
			}
		}

	parse_feed : Str -> Route.Feed
	parse_feed = |query|
		Str.split_on(query, "&").fold(
			default_feed,
			|feed, pair|
				if Str.starts_with(pair, "page=") {
					match U64.from_str(Str.drop_prefix(pair, "page=")) {
						Ok(page) =>
							if page >= 1 {
								{ ..feed, page: page }
							} else {
								feed
							}
						Err(_) => feed
					}
				} else if Str.starts_with(pair, "tag=") {
					tag_value = Str.drop_prefix(pair, "tag=")
					if Str.is_empty(tag_value) {
						feed
					} else {
						{ ..feed, tag: Tagged(tag_value) }
					}
				} else {
					feed
				},
		)

	feed_query : Route.Feed -> Str
	feed_query = |feed| {
		page_part =
			if feed.page > 1 {
				"page=${feed.page.to_str()}"
			} else {
				""
			}
		tag_part =
			match feed.tag {
				Tagged(tag) => "tag=${tag}"
				AllTags => ""
			}
		if Str.is_empty(page_part) {
			tag_part
		} else if Str.is_empty(tag_part) {
			page_part
		} else {
			"${page_part}&${tag_part}"
		}
	}
}
