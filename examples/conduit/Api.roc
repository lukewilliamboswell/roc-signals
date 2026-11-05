## RealWorld API surface: DTO records, camelCase JSON decoding through the
## builtin Json, URI builders, auth headers (`Authorization: Token <jwt>` per
## the spec), and the Remote loading/ready/failed shape every fetch surface
## renders from.
import pf.Engine
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

	Comment : {
		id : U64,
		created_at : Str,
		body : Str,
		author : Api.Author,
	}

	page_size : U64
	page_size = 20

	page_count : U64 -> U64
	page_count = |total| (total + page_size - 1) // page_size

	feed_uri : Route.Feed -> Str
	feed_uri = |feed| {
		offset = (feed.page - 1) * page_size
		path = match feed.source {
			Global => "/api/articles"
			Yours => "/api/articles/feed"
		}
		base = "${path}?limit=${page_size.to_str()}&offset=${offset.to_str()}"
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

	favorite_uri : Str -> Str
	favorite_uri = |slug| "/api/articles/${slug}/favorite"

	comments_uri : Str -> Str
	comments_uri = |slug| "/api/articles/${slug}/comments"

	comment_uri : Str, U64 -> Str
	comment_uri = |slug, id| "/api/articles/${slug}/comments/${id.to_str()}"

	profile_uri : Str -> Str
	profile_uri = |username| "/api/profiles/${username}"

	follow_uri : Str -> Str
	follow_uri = |username| "/api/profiles/${username}/follow"

	tags_uri : Str
	tags_uri = "/api/tags"

	decode_feed : Str -> Api.Remote(Api.FeedPage)
	decode_feed = |body| {
		parse : Str -> Try(Api.FeedPage, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		to_remote(parse(shield_escapes(body)).map_ok(|page| { ..page, articles: page.articles.map(restore_summary) }))
	}

	decode_article : Str -> Api.Remote(Api.Article)
	decode_article = |body| {
		parse : Str -> Try({ article : Api.Article }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		to_remote(parse(shield_escapes(body)).map_ok(|envelope| restore_article(envelope.article)))
	}

	decode_profile : Str -> Api.Remote(Api.Profile)
	decode_profile = |body| {
		parse : Str -> Try({ profile : Api.Profile }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		to_remote(parse(shield_escapes(body)).map_ok(|envelope| { ..envelope.profile, bio: restore_text(envelope.profile.bio) }))
	}

	decode_comments : Str -> Api.Remote(List(Api.Comment))
	decode_comments = |body| {
		parse : Str -> Try({ comments : List(Api.Comment) }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		to_remote(parse(shield_escapes(body)).map_ok(|envelope| envelope.comments.map(restore_comment)))
	}

	decode_tags : Str -> Api.Remote(List(Str))
	decode_tags = |body| {
		parse : Str -> Try({ tags : List(Str) }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		to_remote(parse(shield_escapes(body)).map_ok(|envelope| envelope.tags))
	}

	# TODO remove once https://github.com/roc-lang/roc/pull/10045 is merged
	#
	# The builtin Json parser rejects any backslash escape inside a JSON
	# string (Builtin.Json.split_json_string_tail treats a backslash before
	# the closing quote as invalid JSON), and RealWorld payloads legally
	# carry \n, \", \\, and \t escapes in article bodies and bios. Shield
	# those escapes with private-use placeholder characters before parsing
	# and restore the real characters on every decoded string field.
	# Unicode \uXXXX escapes remain unsupported. Remove this once upstream
	# escape support lands (finding recorded in
	# https://github.com/roc-lang/roc/pull/10045).

	replace : Str, Str, Str -> Str
	replace = |text, from, to| Str.join_with(text.split_on(from), to)

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

	restore_comment : Api.Comment -> Api.Comment
	restore_comment = |comment| {
		{
			..comment,
			body: restore_text(comment.body),
			author: restore_author(comment.author),
		}
	}

	## Every fetch surface renders `Remote` the same three ways, so the
	## predicates and the failure message live here instead of being
	## re-derived once per page module.
	is_loading : Api.Remote(a) -> Bool
	is_loading = |remote|
		match remote {
			Loading => True
			_ => False
		}

	is_failed : Api.Remote(a) -> Bool
	is_failed = |remote|
		match remote {
			Failed(_) => True
			_ => False
		}

	failure_message : Api.Remote(a) -> Str
	failure_message = |remote|
		match remote {
			Failed(message) => message
			_ => ""
		}

	to_remote : Try(a, [InvalidJson(Str), MissingRequiredField(Str)]) -> Api.Remote(a)
	to_remote = |result|
		match result {
			Ok(value) => Ready(value)
			Err(MissingRequiredField(name)) => Failed("Response was missing ${name}")
			Err(InvalidJson(_)) => Failed("Response was not valid JSON")
		}

	request_failed : Str -> Api.Remote(a)
	request_failed = |err| Failed("Request failed: ${err}")

	User : { email : Str, token : Str, username : Str }

	AuthResult : [AuthIdle, AuthAccepted(Api.User), AuthRejected(List(Str)), AuthErrored(Str)]

	# Page classifiers consume status and strict text, not package-owned responses.
	ResponseState : { status : U16, body : Str, error : Str, ready : Bool }

	## The status and text of an effect result, as page classifiers consume
	## it: any response (the pages classify 4xx envelopes themselves), or a
	## failure shown as its inspected `Engine.HttpError` (`Network("offline")`,
	## `Timeout`, `Refused`).
	response_of : Engine.Res -> Api.ResponseState
	response_of = |res| match res {
		Http({ status, headers: _, body }) => { status, body, error: "", ready: True }
		Network(message) => Api.failure(Network(message))
		Timeout => Api.failure(Timeout)
		Refused => Api.failure(Refused)
		_ => crash "contract: a Conduit request reaction received a result that is not an HTTP result"
	}

	failure : Engine.HttpError -> Api.ResponseState
	failure = |err| { status: 0, body: "", error: Str.inspect(err), ready: True }

	## Per-request HTTP timeout (a typed Timeout result when it fires).
	timeout_ms : U32
	timeout_ms = 30000

	auth_headers : Str -> List((Str, Str))
	auth_headers = |token| if token.is_empty() {
		[]
	} else {
		[("authorization", "Token ${token}")]
	}

	json_headers : Str -> List((Str, Str))
	json_headers = |token|
		if token.is_empty() {
			[("content-type", "application/json")]
		} else {
			[("content-type", "application/json"), ("authorization", "Token ${token}")]
		}

	get_request : Str, Str -> Engine.Req
	get_request = |uri, token| Http({ method: "GET", url: uri, headers: auth_headers(token), body: "", timeout_ms: Api.timeout_ms })

	post_request : Str, Str, Str -> Engine.Req
	post_request = |uri, body, token| Http({ method: "POST", url: uri, headers: json_headers(token), body, timeout_ms: Api.timeout_ms })

	put_request : Str, Str, Str -> Engine.Req
	put_request = |uri, body, token| Http({ method: "PUT", url: uri, headers: json_headers(token), body, timeout_ms: Api.timeout_ms })

	delete_request : Str, Str -> Engine.Req
	delete_request = |uri, token| Http({ method: "DELETE", url: uri, headers: auth_headers(token), body: "", timeout_ms: Api.timeout_ms })

	## A GET whose body decodes into a page resource (the original `Load`).
	decode_get : Api.ResponseState, (Str -> Api.Remote(a)) -> Api.Remote(a)
	decode_get = |response, decode| {
		if !response.error.is_empty() {
			request_failed(response.error)
		} else if response.status == 200 {
			decode(response.body)
		} else {
			Failed("The server responded with status ${response.status.to_str()}.")
		}
	}

	login_body : Str, Str -> Str
	login_body = |email, password| Json.to_str({ user: { email: email, password: password } })

	register_body : Str, Str, Str -> Str
	register_body = |username, email, password|
		Json.to_str({ user: { username: username, email: email, password: password } })

	decode_feed_response : Api.ResponseState -> Api.Remote(Api.FeedPage)
	decode_feed_response = |response| {
		if !response.ready {
			Loading
		} else if !response.error.is_empty() {
			request_failed(response.error)
		} else if response.status == 200 {
			decode_feed(response.body)
		} else if response.status == 401 {
			Failed("Please sign in to see this feed.")
		} else {
			Failed("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_auth : Api.ResponseState -> Api.AuthResult
	classify_auth = |response| {
		if !response.ready {
			AuthIdle
		} else if !response.error.is_empty() {
			AuthErrored("Request failed: ${response.error}")
		} else if response.status == 200 {
			parse : Str -> Try({ user : Api.User }, [InvalidJson(Str), MissingRequiredField(Str)])
			parse = Json.parser_camel()
			match parse(shield_escapes(response.body)) {
				Ok(envelope) => AuthAccepted(envelope.user)
				Err(_) => AuthErrored("The server response could not be read.")
			}
		} else if response.status == 422 {
			AuthRejected(parse_errors(response.body))
		} else {
			AuthErrored("The server responded with status ${response.status.to_str()}.")
		}
	}

	# 422 validation envelopes ({"errors": {"field": ["message", ...]}})
	# carry dynamic object keys, which derived record decoding cannot
	# express, so the envelope is string-parsed: one "field message" entry
	# per key, first message only.
	parse_errors : Str -> List(Str)
	parse_errors = |body| {
		shielded = shield_escapes(body)
		shielded.split_first("\"errors\"").map_ok(|split| collect_errors(split.after, []))
			?? ["The request was rejected."]
	}

	## Each step of the scan may run out of input; `?` short-circuits to the
	## entries collected so far, which is exactly the old nested-match
	## behaviour without the staircase.
	collect_errors : Str, List(Str) -> List(Str)
	collect_errors = |rest, acc| collect_one_error(rest, acc) ?? acc

	collect_one_error : Str, List(Str) -> Try(List(Str), _)
	collect_one_error = |rest, acc| {
		key_open = rest.split_first("\"")?
		key_close = key_open.after.split_first("\"")?
		list_open = key_close.after.split_first("[\"")?
		message_close = list_open.after.split_first("\"")?
		entry = restore_text("${key_close.before} ${message_close.before}")
		next = acc.append(entry)
		Ok(
			message_close.after.split_first("]").map_ok(|list_close| collect_errors(list_close.after, next))
				?? next,
		)
	}
}

## A 422 envelope becomes one "field message" sentence per field, in envelope order.
expect Api.parse_errors("{\"errors\":{\"email\":[\"can't be blank\"],\"password\":[\"is too short\"]}}") == ["email can't be blank", "password is too short"]

## A body with no "errors" key falls back to a single generic rejection sentence.
expect Api.parse_errors("{\"message\":\"nope\"}") == ["The request was rejected."]
