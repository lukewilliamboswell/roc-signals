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
	Feed : { page : U64, tag : [AllTags, Tagged(Str)], source : [Global, Yours] }

	is_eq : Route, Route -> Bool
	is_eq = |left, right| {
		left_kind = Route.kind(left)
		right_kind = Route.kind(right)
		if left_kind != right_kind {
			False
		} else {
			Route.to_location(left) == Route.to_location(right)
		}
	}

	default_feed : Route.Feed
	default_feed = { page: 1, tag: AllTags, source: Global }

	home : Route
	home = Home(default_feed)

	home_location : Browser.Location
	home_location = { path: "/", query: "", hash: "" }

	login_location : Browser.Location
	login_location = { path: "/login", query: "", hash: "" }

	register_location : Browser.Location
	register_location = { path: "/register", query: "", hash: "" }

	feed_location : Route.Feed -> Browser.Location
	feed_location = |feed| { path: "/", query: feed_query(feed), hash: "" }

	article_location : Str -> Browser.Location
	article_location = |slug| { path: "/article/${slug}", query: "", hash: "" }

	profile_location : Str -> Browser.Location
	profile_location = |username| { path: "/profile/${username}", query: "", hash: "" }

	profile_favorites_location : Str -> Browser.Location
	profile_favorites_location = |username| { path: "/profile/${username}/favorites", query: "", hash: "" }

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
		} else if path.starts_with("/editor/") {
			slug_route(path.drop_prefix("/editor/"), |slug| EditorEdit(slug))
		} else if path.starts_with("/article/") {
			slug_route(path.drop_prefix("/article/"), |slug| Article(slug))
		} else if path.starts_with("/profile/") {
			profile_route(path.drop_prefix("/profile/"))
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
		match rest.find_first("/") {
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
		if segment.is_empty() {
			False
		} else {
			match segment.find_first("/") {
				Ok(_) => False
				Err(_) => True
			}
		}

	parse_feed : Str -> Route.Feed
	parse_feed = |query|
		query.split_on("&").fold(
			default_feed,
			|feed, pair|
				if pair.starts_with("page=") {
					match U64.from_str(pair.drop_prefix("page=")) {
						Ok(page) =>
							if page >= 1 {
								{ ..feed, page: page }
							} else {
								feed
							}
						Err(_) => feed
					}
				} else if pair == "feed=yours" {
					{ ..feed, source: Yours }
				} else if pair.starts_with("tag=") {
					tag_value = pair.drop_prefix("tag=")
					if tag_value.is_empty() {
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
		source_part =
			match feed.source {
				Yours => "feed=yours"
				Global => ""
			}
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
		parts = [source_part, page_part, tag_part].fold(
			[],
			|acc, part|
				if part.is_empty() {
					acc
				} else {
					acc.append(part)
				},
		)
		Str.join_with(parts, "&")
	}
}
