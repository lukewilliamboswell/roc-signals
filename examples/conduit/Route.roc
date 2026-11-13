## Conduit pages, decoded route parts, feed choices, and document titles.
## URL encoding and the static demo fragment layout belong to Locations.

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

	## The document location as encoded URL components; Locations owns its text.
	Location : { path : Str, query : Str, hash : Str }

	Feed : { page : U64, tag : [AllTags, Tagged(Str)], source : [Global, Yours] }

	## The page which a `Route` selects, with the slugs and feed parameters
	## dropped. The app's `switch` over its pages asks "am I on the article
	## page?", not "which article?", so it selects on kinds.
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

	## Two routes are equal when they name the same page with the same
	## parameters.
	is_eq : _

	default_feed : Route.Feed
	default_feed = { page: 1, tag: AllTags, source: Global }

	home : Route
	home = Home(default_feed)

	## Choose a page from decoded parts; names remain one segment even with slashes.
	from_parts : List(Str), List((Str, Str)) -> Route
	from_parts = |segments, pairs| match segments {
		[] => Home(parse_feed(pairs))
		["login"] => Login
		["register"] => Register
		["settings"] => Settings
		["editor"] => EditorNew
		["editor", name] if !name.is_empty() => EditorEdit(name)
		["article", name] if !name.is_empty() => Article(name)
		["profile", name] if !name.is_empty() => Profile(name)
		["profile", name, "favorites"] if !name.is_empty() => ProfileFavorites(name)
		_ => NotFound
	}

	## Describe a route using decoded names and ordered query pairs.
	to_parts : Route -> { segments : List(Str), pairs : List((Str, Str)) }
	to_parts = |route| match route {
		Home(feed) => { segments: [], pairs: feed_pairs(feed) }
		Login => { segments: ["login"], pairs: [] }
		Register => { segments: ["register"], pairs: [] }
		Settings => { segments: ["settings"], pairs: [] }
		EditorNew => { segments: ["editor"], pairs: [] }
		EditorEdit(name) => { segments: ["editor", name], pairs: [] }
		Article(name) => { segments: ["article", name], pairs: [] }
		Profile(name) => { segments: ["profile", name], pairs: [] }
		ProfileFavorites(name) => { segments: ["profile", name, "favorites"], pairs: [] }
		NotFound => { segments: ["not-found"], pairs: [] }
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

	## Read recognized feed fields in order, retaining the last valid value.
	parse_feed : List((Str, Str)) -> Route.Feed
	parse_feed = |pairs| pairs.fold(
		default_feed,
		|feed, (name, value)|
			match name {
				"page" => match U64.from_str(value) {
					Ok(page) if page >= 1 => { ..feed, page }
					_ => feed
				}
				"feed" if value == "yours" => { ..feed, source: Yours }
				"tag" if !value.is_empty() => { ..feed, tag: Tagged(value) }
				_ => feed
			},
	)

	## Write only nondefault feed fields, in the app's stable order.
	feed_pairs : Route.Feed -> List((Str, Str))
	feed_pairs = |feed| {
		source = if feed.source == Yours {
			[("feed", "yours")]
		} else {
			[]
		}
		page = if feed.page > 1 {
			[("page", feed.page.to_str())]
		} else {
			[]
		}
		tag = match feed.tag {
			Tagged(value) => [("tag", value)]
			AllTags => []
		}
		source.concat(page).concat(tag)
	}
}

## Reserved text stays one decoded profile segment in the route model.
expect ["a/b", "anna?x", "c#", "c&c", "%41", ".", ".."].all(
	|name| {
		parts = Route.to_parts(Profile(name))
		Route.from_parts(parts.segments, parts.pairs) == Profile(name)
	},
)

## Page, tag, and source survive decoded pairs together.
expect {
	feed = { page: 3, tag: Tagged("café & c++"), source: Yours }
	Route.parse_feed(Route.feed_pairs(feed)) == feed
}

## Default feed fields are omitted and invalid page numbers leave the last valid one.
expect Route.feed_pairs(Route.default_feed) == [] and Route.parse_feed([("page", "2"), ("page", "0"), ("page", "bad")]).page == 2

## Profile favorites and unknown trailing parts stay distinct routes.
expect Route.from_parts(["profile", "alice", "favorites"], []) == ProfileFavorites("alice") and Route.from_parts(["profile", "alice", "extra"], []) == NotFound

## Equality separates payloads and page kinds.
expect !Route.is_eq(Profile("alice"), Profile("bob")) and !Route.is_eq(NotFound, Route.home)

## An article's parts preserve its full slug independently of URL syntax.
expect Route.from_parts(Route.to_parts(Article("how-to-train-your-dragon")).segments, []) == Article("how-to-train-your-dragon")

## The authenticated feed has one source pair while default page and tag are omitted.
expect Route.feed_pairs({ page: 1, tag: AllTags, source: Yours }) == [("feed", "yours")]

## A nondefault page precedes its tag in the app's stable pair order.
expect Route.feed_pairs({ page: 2, tag: Tagged("roc"), source: Global }) == [("page", "2"), ("tag", "roc")]
