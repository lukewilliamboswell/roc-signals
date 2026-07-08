## RealWorld API surface: DTO records, camelCase JSON decoding through the
## builtin Json (single wide-enough parses; roc#9964 no longer reproduces on
## the current nightly, see wip/research/realworld_demo_findings.md), URI
## builders, and the Remote loading/ready/failed shape every fetch surface
## renders from. Auth headers land with sessions (Phase 3).
import Route

Api := {}.{
	Remote(a) : [Loading, Ready(a), Failed(Str)]

	Author : { username : Str, bio : Str, image : Str, following : Bool }

	ArticleSummary : {
		slug : Str,
		title : Str,
		description : Str,
		tag_list : List(Str),
		created_at : Str,
		favorited : Bool,
		favorites_count : U64,
		author : Api.Author,
	}

	Article : {
		slug : Str,
		title : Str,
		description : Str,
		body : Str,
		tag_list : List(Str),
		created_at : Str,
		favorited : Bool,
		favorites_count : U64,
		author : Api.Author,
	}

	FeedPage : { articles : List(Api.ArticleSummary), articles_count : U64 }

	Profile : { username : Str, bio : Str, image : Str, following : Bool }

	page_size : U64
	page_size = 20

	page_count : U64 -> U64
	page_count = |total| (total + page_size - 1) // page_size

	feed_uri : Route.Feed -> Str
	feed_uri = |feed| {
		offset = (feed.page - 1) * page_size
		base = "/api/articles?limit=${page_size.to_str()}&offset=${offset.to_str()}"
		match feed.tag {
			Tagged(tag) => "${base}&tag=${tag}"
			AllTags => base
		}
	}

	author_articles_uri : Str -> Str
	author_articles_uri = |username| "/api/articles?limit=${page_size.to_str()}&offset=0&author=${username}"

	favorited_articles_uri : Str -> Str
	favorited_articles_uri = |username| "/api/articles?limit=${page_size.to_str()}&offset=0&favorited=${username}"

	article_uri : Str -> Str
	article_uri = |slug| "/api/articles/${slug}"

	profile_uri : Str -> Str
	profile_uri = |username| "/api/profiles/${username}"

	tags_uri : Str
	tags_uri = "/api/tags"

	decode_feed : Str -> Api.Remote(Api.FeedPage)
	decode_feed = |body| {
		parse : Str -> Try(Api.FeedPage, Json.ParseErr)
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(page) => Ready({ ..page, articles: page.articles.map(restore_summary) })
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_article : Str -> Api.Remote(Api.Article)
	decode_article = |body| {
		parse : Str -> Try({ article : Api.Article }, Json.ParseErr)
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready(restore_article(envelope.article))
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_profile : Str -> Api.Remote(Api.Profile)
	decode_profile = |body| {
		parse : Str -> Try({ profile : Api.Profile }, Json.ParseErr)
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready({ ..envelope.profile, bio: restore_text(envelope.profile.bio) })
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_tags : Str -> Api.Remote(List(Str))
	decode_tags = |body| {
		parse : Str -> Try({ tags : List(Str) }, Json.ParseErr)
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready(envelope.tags)
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	# The builtin Json parser rejects any backslash escape inside a JSON
	# string (Builtin.Json.split_json_string_tail treats a backslash before
	# the closing quote as invalid JSON), and RealWorld payloads legally
	# carry \n, \", \\, and \t escapes in article bodies and bios. Shield
	# those escapes with private-use placeholder characters before parsing
	# and restore the real characters on every decoded string field.
	# Unicode \uXXXX escapes remain unsupported. Remove this once upstream
	# escape support lands (finding recorded in
	# wip/research/realworld_demo_findings.md).

	replace : Str, Str, Str -> Str
	replace = |text, from, to| Str.join_with(Str.split_on(text, from), to)

	shield_escapes : Str -> Str
	shield_escapes = |raw| {
		backslashes = replace(raw, "\\\\", "\u(E000)")
		quotes = replace(backslashes, "\\\"", "\u(E001)")
		newlines = replace(quotes, "\\n", "\u(E002)")
		tabs = replace(newlines, "\\t", "\u(E003)")
		returns = replace(tabs, "\\r", "")
		replace(returns, "\\/", "/")
	}

	restore_text : Str -> Str
	restore_text = |text| {
		backslashes = replace(text, "\u(E000)", "\\")
		quotes = replace(backslashes, "\u(E001)", "\"")
		newlines = replace(quotes, "\u(E002)", "\n")
		replace(newlines, "\u(E003)", "\t")
	}

	restore_author : Api.Author -> Api.Author
	restore_author = |author| {
		{ ..author, bio: restore_text(author.bio) }
	}

	restore_summary : Api.ArticleSummary -> Api.ArticleSummary
	restore_summary = |summary| {
		{
			..summary,
			title: restore_text(summary.title),
			description: restore_text(summary.description),
			author: restore_author(summary.author),
		}
	}

	restore_article : Api.Article -> Api.Article
	restore_article = |article| {
		{
			..article,
			title: restore_text(article.title),
			description: restore_text(article.description),
			body: restore_text(article.body),
			author: restore_author(article.author),
		}
	}

	to_remote : Try(a, Json.ParseErr) -> Api.Remote(a)
	to_remote = |result|
		match result {
			Ok(value) => Ready(value)
			Err(MissingRequiredField(name)) => Failed("Response was missing ${name}")
			Err(InvalidJson(_)) => Failed("Response was not valid JSON")
		}

	request_failed : Str -> Api.Remote(a)
	request_failed = |err| Failed("Request failed: ${err}")
}
