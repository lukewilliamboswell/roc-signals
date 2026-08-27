## Conduit route model: `Browser.Location` <-> `Route` parsing and formatting
## plus per-route document titles. Routing stays app code by design: no router
## DSL and no platform route table.
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

	## The page which a `Route` selects, with the slugs and feed parameters
	## dropped. Signal branching (`Ui.when`) asks "am I on the article page?",
	## not "which article?", so the branch predicates compare kinds.
	Kind : [
		Home,
		Login,
		Register,
		Settings,
		EditorNew,
		EditorEdit,
		Article,
		Profile,
		ProfileFavorites,
		NotFound,
	]

	## Structural equality. Signals compare their previous and next values on
	## every invalidation, so this stays on the hot path: it must not build
	## the location strings just to throw them away.
	is_eq : Route, Route -> Bool
	is_eq = |left, right|
		match left {
			Home(left_feed) => match right {
				Home(right_feed) => feed_is_eq(left_feed, right_feed)
				_ => False
			}
			Login => match right {
				Login => True
				_ => False
			}
			Register => match right {
				Register => True
				_ => False
			}
			Settings => match right {
				Settings => True
				_ => False
			}
			EditorNew => match right {
				EditorNew => True
				_ => False
			}
			EditorEdit(left_slug) => match right {
				EditorEdit(right_slug) => left_slug == right_slug
				_ => False
			}
			Article(left_slug) => match right {
				Article(right_slug) => left_slug == right_slug
				_ => False
			}
			Profile(left_name) => match right {
				Profile(right_name) => left_name == right_name
				_ => False
			}
			ProfileFavorites(left_name) => match right {
				ProfileFavorites(right_name) => left_name == right_name
				_ => False
			}
			NotFound => match right {
				NotFound => True
				_ => False
			}
		}

	feed_is_eq : Route.Feed, Route.Feed -> Bool
	feed_is_eq = |left, right|
		left.page == right.page and tag_is_eq(left.tag, right.tag) and source_is_eq(left.source, right.source)

	tag_is_eq : [AllTags, Tagged(Str)], [AllTags, Tagged(Str)] -> Bool
	tag_is_eq = |left, right|
		match left {
			AllTags => match right {
				AllTags => True
				Tagged(_) => False
			}
			Tagged(left_tag) => match right {
				AllTags => False
				Tagged(right_tag) => left_tag == right_tag
			}
		}

	source_is_eq : [Global, Yours], [Global, Yours] -> Bool
	source_is_eq = |left, right|
		match left {
			Global => match right {
				Global => True
				Yours => False
			}
			Yours => match right {
				Global => False
				Yours => True
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
			Try.ok_or(
				hash.split_first("?").map_ok(|split| { path: split.before, query: split.after }),
				{ path: hash, query: "" },
			)
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

	kind : Route -> Route.Kind
	kind = |route|
		match route {
			Home(_) => Home
			Login => Login
			Register => Register
			Settings => Settings
			EditorNew => EditorNew
			EditorEdit(_) => EditorEdit
			Article(_) => Article
			Profile(_) => Profile
			ProfileFavorites(_) => ProfileFavorites
			NotFound => NotFound
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
		!segment.is_empty() and segment.split_first("/").is_err()

	parse_feed : Str -> Route.Feed
	parse_feed = |query|
		query.split_on("&").fold(
			default_feed,
			|feed, pair|
				if pair.starts_with("page=") {
					# 0 stands in for "unparseable", and is rejected by the same
					# guard that rejects an explicit page=0.
					page = Try.ok_or(U64.from_str(pair.drop_prefix("page=")), 0)
					if page >= 1 {
						{ ..feed, page: page }
					} else {
						feed
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
		parts = [source_part, page_part, tag_part].keep_if(|part| !part.is_empty())
		Str.join_with(parts, "&")
	}
}

expect {
	# Deep links survive the hash round trip, slugs and all.
	route = Route.from_location(Route.article_location("how-to-train-your-dragon"))
	route.is_eq(Article("how-to-train-your-dragon"))
}

expect {
	# Feed parameters round trip through the query string.
	feed = { page: 3, tag: Tagged("dragons"), source: Global }
	Route.from_location(Route.feed_location(feed)).is_eq(Home(feed))
}

expect Route.feed_query({ page: 1, tag: AllTags, source: Yours }) == "feed=yours"

expect Route.feed_query({ page: 2, tag: Tagged("roc"), source: Global }) == "page=2&tag=roc"

expect {
	# `is_eq` must separate routes that share a kind, and routes that share a
	# location: NotFound and Home both point at the demo base path.
	!Route.is_eq(Profile("alice"), Profile("bob")) and !Route.is_eq(NotFound, Route.home)
}

expect Route.from_location({ path: "/", query: "", hash: "/profile/alice/favorites" }).is_eq(ProfileFavorites("alice"))

expect Route.from_location({ path: "/", query: "", hash: "/profile/alice/extra" }).is_eq(NotFound)
