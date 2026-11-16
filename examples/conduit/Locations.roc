## Conduit's encoded document locations and its root-relative fragment routes.
## Route owns decoded page meaning; Url validates text without inventing an origin.
import pf.Url
import Route

Locations := {}.{

	## The static demo keeps its document path while the fragment selects a page.
	demo_base_path : Str
	demo_base_path = "/roc-signals/examples/conduit/"

	## Split a validated document URL without decoding its fragment a second time.
	parse_url : Str -> Try(Route.Location, Url.ParseErr)
	parse_url = |text| {
		url = Url.parse(text)?
		Ok({
			path: url.path(),
			query: match url.query() {
				None => ""
				Some(value) => value
			},
			hash: match url.fragment() {
				None => ""
				Some(value) => value
			},
		})
	}

	## Write the encoded components the app already validated or built.
	to_url : Route.Location -> Str
	to_url = |location| {
		query = if location.query.is_empty() {
			""
		} else {
			"?${location.query}"
		}
		hash = if location.hash.is_empty() {
			""
		} else {
			"#${location.hash}"
		}
		"${location.path}${query}${hash}"
	}

	## Invalid document or fragment text selects not-found and starts no page load.
	of_url : Str -> Route
	of_url = |text| match parse_url(text) {
		Ok(location) => from_location(location)
		Err(_) => NotFound
	}

	## A fragment is a root-relative URL of its own, decoded only by Url's readers.
	from_location : Route.Location -> Route
	from_location = |location|
		if location.hash.is_empty() {
			Route.home
		} else {
			match Url.parse(location.hash) {
				Ok(url) if url.origin() == Relative => Route.from_parts(url.path_segments(), url.query_pairs())
				_ => NotFound
			}
		}

	## Refused names link to a real not-found route, never a neighboring resource.
	to_location : Route -> Route.Location
	to_location = |route| {
		root : Url
		root = "/"
		parts = Route.to_parts(route)
		hash = match root.append_path_segments(parts.segments) {
			Ok(path) => parts.pairs.fold(path, |url, (name, value)| url.append_query_param(name, value)).to_str()
			Err(_) => "/not-found"
		}
		{ path: demo_base_path, query: "", hash }
	}

	home_location : Route.Location
	home_location = to_location(Route.home)

	login_location : Route.Location
	login_location = to_location(Login)

	register_location : Route.Location
	register_location = to_location(Register)

	feed_location : Route.Feed -> Route.Location
	feed_location = |feed| to_location(Home(feed))

	article_location : Str -> Route.Location
	article_location = |name| to_location(Article(name))

	profile_location : Str -> Route.Location
	profile_location = |name| to_location(Profile(name))

	profile_favorites_location : Str -> Route.Location
	profile_favorites_location = |name| to_location(ProfileFavorites(name))
}

## Encoded fragments recover reserved names exactly once.
expect Locations.of_url("/demo/#/profile/%2541") == Profile("%41") and Locations.of_url("/demo/#/?tag=caf%C3%A9+au+lait") == Home({ page: 1, tag: Tagged("café au lait"), source: Global })

## Malformed escapes, invalid UTF-8 and raw spaces are not-found without recovery.
expect ["/?tag=100%", "/?tag=%FF", "/article/100%", "/article/%FF", "/?tag=a b"].all(|hash| Locations.from_location({ path: "/demo/", query: "", hash }) == NotFound)

## A refused authored name cannot navigate to the neighboring profile page.
expect [".", "..", ""].all(|name| Locations.to_location(Profile(name)).hash == "/not-found")

## Parsed dot segments select the same profile as ordinary URL normalization.
expect Locations.of_url("/demo/#/profile/anna/../kim") == Profile("kim")

## Every encoded route field survives browser fragment escaping without decoding twice.
expect ["a/b", "anna?x", "c#", "c&c", "%41", "café au lait"].all(|name| Locations.of_url(Locations.to_url(Locations.to_location(Profile(name)))) == Profile(name))
