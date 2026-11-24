import pf.Order
import Api
import "public-seed.json" as seed_json : Str

## The immutable public data shared with the demo backend. The initial feed
## uses the same order and page size as the backend's anonymous response.
PublicSeed := [].{
	home : { feed : Api.FeedPage, tags : List(Str) }
	home = match read_home(seed_json) {
		Ok(parsed) => parsed
		Err(problem) => crash "PublicSeed.home: invalid public demo seed: ${Str.inspect(problem)}"
	}
}

Profile : { username : Str, bio : Str, image : Str }

Article : { slug : Str, title : Str, description : Str, tag_list : List(Str), created_at : Str, favorites_count : U64, author : Str }

read_home : Str -> Try({ feed : Api.FeedPage, tags : List(Str) }, _)
read_home = |text| {
	parse : Str -> Try({ profiles : List(Profile), articles : List(Article) }, [InvalidJson(Str)])
	parse = Json.parser_camel()
	seed = parse(text)?
	match (Api.repeated(seed.profiles, |profile| profile.username), Api.repeated(seed.articles, |article| article.slug)) {
		(Ok(username), _) => return Err(DuplicateProfile(username))
		(_, Ok(slug)) => return Err(DuplicateArticle(slug))
		_ => {}
	}
	profiles = seed.profiles.map(|profile| (profile.username, profile)).fold(Dict.empty(), |dict, (name, profile)| dict.insert(name, profile))
	var $articles = []
	var $counts = Dict.empty()
	for article in seed.articles {
		profile = profiles.get(article.author) ? |_| UnknownAuthor(article.author)
		tags = Api.distinct(article.tag_list)
		for tag in tags {
			$counts = $counts.insert(tag, ($counts.get(tag) ?? 0.U64) + 1)
		}
		$articles = $articles.append({
			slug: article.slug,
			title: article.title,
			description: article.description,
			tag_list: tags,
			created_at: article.created_at,
			favorited: False,
			favorites_count: article.favorites_count,
			author: { username: profile.username, bio: profile.bio, image: profile.image, following: False },
		})
	}
	articles = $articles
		.sort_with(|left, right| Order.compare(Order.pair(Order.desc(Order.utf8(left.created_at)), Order.desc(Order.utf8(left.slug))), Order.pair(Order.desc(Order.utf8(right.created_at)), Order.desc(Order.utf8(right.slug)))))
		.take_first(Api.page_size)
	tags = $counts
		.to_list()
		.sort_with(|(left, left_count), (right, right_count)| Order.compare(Order.pair(Order.desc(left_count), Order.utf8(left)), Order.pair(Order.desc(right_count), Order.utf8(right))))
		.map(|(tag, _)| tag)
	Ok({ feed: { articles, articles_count: seed.articles.len() }, tags })
}

## The public home is a complete first page of the demo's anonymous feed.
expect {
	home = PublicSeed.home
	{
		first: home.feed.articles.first().map_ok(|article| article.slug),
		total: home.feed.articles_count,
		drawn: home.feed.articles.len(),
		tags: home.tags,
	} == {
		first: Ok("error-envelopes-worth-rendering-23"),
		total: 23,
		drawn: Api.page_size,
		tags: ["signals", "release", "webdev", "roc", "performance", "testing"],
	}
}
