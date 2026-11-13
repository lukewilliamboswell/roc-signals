app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Route

## Conduit's routes, as the URLs the app writes and reads back. Every link
## the app renders is a route's location, and every load and back or
## forward reads a location as a route, so a route that does not survive
## the trip is a link that lands somewhere else.
##
## Each input decodes into a route (a feed with any page, tag and source,
## an article, an editor, a profile or its favourites, or a fixed page)
## whose slugs, usernames and tags are made of pieces a server may send.
## Its properties:
##
## - a route's location reads back as the route;
## - the location's URL parses back as the location, and reads back as
##   the route;
## - an article's title names its slug, and a profile's its username;
## - a location the app did not write, made of the same pieces, reads as
##   a route whose own location reads back as that route.
##
## Slugs, usernames and tags here hold no `/`, `?`, `#` or `&`: the app
## writes them into its URLs as they are, without percent-encoding, so such
## a name does not survive (a tag `c&c` reads back as the tag `c`).
Input : { kind : U8, name : List(U8), page : U8, odd : List(U8) }

## The pieces a name is made of; an input byte picks one.
pieces : List(Str)
pieces = ["a", "dragon", "-", "_", "é", "1", "=", "%20", "+", " ", "tag", "page"]

## The pieces of a location the app did not write.
odd_pieces : List(Str)
odd_pieces = ["/", "article", "profile", "favorites", "editor", "?", "&", "page=", "tag=", "feed=yours", "0", "2", "x", "#"]

## A name from its pieces, never empty.
name_of : List(U8) -> Str
name_of = |picks| {
	text = Str.join_with(picks.map(|b| pieces.get(b.to_u64() % pieces.len()) ?? ""), "")
	if (text.is_empty()) "a" else text
}

## The route an input describes.
route_of : Input -> Route
route_of = |{ kind, name: picks, page, odd: _ }| {
	name = name_of(picks)
	match kind % 10 {
		0 => {
			tag = if (kind / 10 % 2 == 0) AllTags else Tagged(name)
			source = if (kind / 20 % 2 == 0) Global else Yours
			Home({ page: page.to_u64() + 1, tag, source })
		}
		1 => Login
		2 => Register
		3 => Settings
		4 => EditorNew
		5 => EditorEdit(name)
		6 => Article(name)
		7 => Profile(name)
		8 => ProfileFavorites(name)
		_ => Route.home
	}
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |input| {
	route = route_of(input)
	location = Route.to_location(route)
	back = Route.from_location(location)
	if !back.is_eq(route) {
		return Err("${Str.inspect(route)} is written as ${Str.inspect(location)}, which reads as ${Str.inspect(back)}")
	}
	url = Route.to_url(location)
	if Route.parse_url(url) != location or !Route.of_url(url).is_eq(route) {
		return Err("${Str.inspect(route)} is the URL ${Str.inspect(url)}, which parses as ${Str.inspect(Route.parse_url(url))}")
	}
	named = match route {
		Article(slug) => slug
		_ => Route.profile_username(route)
	}
	if !Route.title(route).contains(named) {
		return Err("the title ${Str.inspect(Route.title(route))} of ${Str.inspect(route)} does not name ${Str.inspect(named)}")
	}
	odd = Str.join_with(input.odd.map(|b| odd_pieces.get(b.to_u64() % odd_pieces.len()) ?? ""), "")
	read = Route.from_location({ path: Route.demo_base_path, query: "", hash: odd })
	again = Route.from_location(Route.to_location(read))
	if !again.is_eq(read) and !read.is_eq(NotFound) {
		return Err("the hash ${Str.inspect(odd)} reads as ${Str.inspect(read)}, whose own location reads as ${Str.inspect(again)}")
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "conduit",
	examples: [
		# Page 3 of the "dragon" tag in the followed feed.
		ex("tagged-feed", { kind: 30, name: [1], page: 2, odd: [] }),
		ex("article", { kind: 6, name: [1, 2, 4, 6, 7], page: 0, odd: [1, 0, 1] }),
		ex("favorites", { kind: 8, name: [9, 10], page: 0, odd: [0, 2, 0, 12, 0, 3] }),
		ex("odd-feed", { kind: 1, name: [], page: 0, odd: [0, 5, 7, 10, 6, 8, 6, 9] }),
	],
	generator: { kind: Fuzz.u8, name: Fuzz.list(Fuzz.u8, 12), page: Fuzz.u8, odd: Fuzz.list(Fuzz.u8, 12) }.Fuzz,
	test!,
	show: Str.inspect,
})
