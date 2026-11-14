app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
}

import fz.Fuzz
import Route

## Conduit's decoded route model, independent of URL encoding and the platform.
## Generated routes read back from their parts; arbitrary parts canonicalize to
## a route whose parts are stable. Names include reserved URL characters because
## they are ordinary decoded text here. Locations' glue is covered by paired specs.
Input : { kind : U8, name : List(U8), page : U8, odd : List(U8) }

## The pieces a name is made of; an input byte picks one.
pieces : List(Str)
pieces = ["a", "dragon", "-", "_", "é", "1", "=", "%20", "+", " ", "tag", "page", "/", "?", "#", "&", "%", ".", ".."]

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
	parts = Route.to_parts(route)
	back = Route.from_parts(parts.segments, parts.pairs)
	if !back.is_eq(route) {
		return Err("${Str.inspect(route)} has parts ${Str.inspect(parts)}, which read as ${Str.inspect(back)}")
	}
	named = match route {
		Article(slug) => slug
		_ => Route.profile_username(route)
	}
	if !Route.title(route).contains(named) {
		return Err("the title ${Str.inspect(Route.title(route))} of ${Str.inspect(route)} does not name ${Str.inspect(named)}")
	}
	odd = input.odd.map(|b| odd_pieces.get(b.to_u64() % odd_pieces.len()) ?? "")
	pairs = [("tag", name_of(input.name)), ("page", (input.page.to_u64() + 1).to_str()), ("feed", "yours")]
	read = Route.from_parts(odd, pairs)
	canonical = Route.to_parts(read)
	again = Route.from_parts(canonical.segments, canonical.pairs)
	if !again.is_eq(read) {
		return Err("parts ${Str.inspect(odd)} read as ${Str.inspect(read)}, whose parts read as ${Str.inspect(again)}")
	}
	feed = Route.parse_feed(pairs)
	if feed.page != input.page.to_u64() + 1 or feed.tag != Tagged(name_of(input.name)) or feed.source != Yours {
		return Err("feed fields did not survive decoded pairs: ${Str.inspect(feed)}")
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "2", make: || input })

target = Fuzz.target_with!({
	name: "conduit",
	examples: [
		# Page 3 of the "dragon" tag in the followed feed.
		ex("tagged-feed", { kind: 30, name: [1], page: 2, odd: [] }),
		ex("article", { kind: 6, name: [1, 2, 4, 6, 7], page: 0, odd: [1, 0, 1] }),
		ex("favorites", { kind: 8, name: [9, 10], page: 0, odd: [0, 2, 0, 12, 0, 3] }),
		ex("reserved-name", { kind: 8, name: [12, 13, 14, 15, 16, 17, 18], page: 0, odd: [] }),
		ex("odd-feed", { kind: 1, name: [], page: 0, odd: [0, 5, 7, 10, 6, 8, 6, 9] }),
	],
	generator: { kind: Fuzz.u8, name: Fuzz.list(Fuzz.u8, 12), page: Fuzz.u8, odd: Fuzz.list(Fuzz.u8, 12) }.Fuzz,
	test!,
	show: Str.inspect,
})
