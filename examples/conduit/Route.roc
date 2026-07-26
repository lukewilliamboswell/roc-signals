## Conduit route model: `Browser.Location` <-> `Route` parsing and formatting
## plus per-route document titles. Routing stays app code by design
## (wip/REALWORLD_DEMO_PLAN.md): no router DSL, no platform route table.
## The published static demo keeps one real document URL and encodes logical
## routes in its hash, so every deep link survives a GitHub Pages refresh.
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

	demo_base_path : Str
	demo_base_path = "/roc-signals/examples/conduit/"

	home : Route
	home = Home(default_feed)

	home_location : Browser.Location
	home_location = location_for("/", "")

	login_location : Browser.Location
	login_location = location_for("/login", "")

	register_location : Browser.Location
	register_location = location_for("/register", "")

	feed_location : Route.Feed -> Browser.Location
	feed_location = |feed| location_for("/", feed_query(feed))

	article_location : Str -> Browser.Location
	article_location = |slug| location_for("/article/${slug}", "")

	profile_location : Str -> Browser.Location
	profile_location = |username| location_for("/profile/${username}", "")

	profile_favorites_location : Str -> Browser.Location
	profile_favorites_location = |username| location_for("/profile/${username}/favorites", "")

	from_location : Browser.Location -> Route
	from_location = |location| {
		logical = logical_location(location.hash)
		path = logical.path
		if path == "/" {
			Home(parse_feed(logical.query))
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
			Home(feed) => feed_location(feed)
			Login => login_location
			Register => register_location
			Settings => location_for("/settings", "")
			EditorNew => location_for("/editor", "")
			EditorEdit(slug) => location_for("/editor/${slug}", "")
			Article(slug) => article_location(slug)
			Profile(username) => profile_location(username)
			ProfileFavorites(username) => profile_favorites_location(username)
			NotFound => home_location
		}

	location_for : Str, Str -> Browser.Location
	location_for = |path, query| {
		hash =
			if query.is_empty() {
				path
			} else {
				"${path}?${query}"
			}
		{ path: demo_base_path, query: "", hash }
	}

	logical_location : Str -> { path : Str, query : Str }
	logical_location = |hash|
		if hash.is_empty() {
			{ path: "/", query: "" }
		} else {
			match hash.split_first("?") {
				Ok(split) => { path: split.before, query: split.after }
				Err(_) => { path: hash, query: "" }
			}
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
		match rest.split_first("/") {
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
			match segment.split_first("/") {
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
