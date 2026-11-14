## RealWorld API surface: DTO records, camelCase JSON decoding through the
## builtin Json, URI builders, auth headers (`Authorization: Token <jwt>` per
## the spec), and the Remote loading/ready/failed shape every fetch surface
## renders from.
import pf.Engine
import pf.Url
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

	articles : Url
	articles = "/api/articles"

	profiles : Url
	profiles = "/api/profiles"

	## Build the feed query from decoded fields, without allowing a field to add a parameter.
	feed_uri : Route.Feed -> Str
	feed_uri = |feed| {
		base : Url
		base = if feed.source == Yours {
			"/api/articles/feed"
		} else {
			articles
		}
		page = base.append_query_param("limit", page_size.to_str()).append_query_param("offset", ((feed.page - 1) * page_size).to_str())
		match feed.tag {
			Tagged(tag) => page.append_query_param("tag", tag).request_target()
			AllTags => page.request_target()
		}
	}

	## Author names are query values, including text that looks like another pair.
	author_articles_uri : Str -> Str
	author_articles_uri = |username| articles.append_query_param("limit", page_size.to_str()).append_query_param("offset", "0").append_query_param("author", username).request_target()

	favorited_articles_uri : Str -> Str
	favorited_articles_uri = |username| articles.append_query_param("limit", page_size.to_str()).append_query_param("offset", "0").append_query_param("favorited", username).request_target()

	## Refused segment names have no target; request plans must retain the refusal.
	article_uri : Str -> Try(Str, Url.SegmentErr)
	article_uri = |slug| articles.append_path_segments([slug]).map_ok(Url.request_target)

	favorite_uri : Str -> Try(Str, Url.SegmentErr)
	favorite_uri = |slug| articles.append_path_segments([slug, "favorite"]).map_ok(Url.request_target)

	comments_uri : Str -> Try(Str, Url.SegmentErr)
	comments_uri = |slug| articles.append_path_segments([slug, "comments"]).map_ok(Url.request_target)

	comment_uri : Str, U64 -> Try(Str, Url.SegmentErr)
	comment_uri = |slug, id| articles.append_path_segments([slug, "comments", id.to_str()]).map_ok(Url.request_target)

	profile_uri : Str -> Try(Str, Url.SegmentErr)
	profile_uri = |username| profiles.append_path_segments([username]).map_ok(Url.request_target)

	follow_uri : Str -> Try(Str, Url.SegmentErr)
	follow_uri = |username| profiles.append_path_segments([username, "follow"]).map_ok(Url.request_target)

	tags : Url
	tags = "/api/tags"

	users : Url
	users = "/api/users"

	login : Url
	login = "/api/users/login"

	user : Url
	user = "/api/user"

	tags_uri : Str
	tags_uri = tags.request_target()

	decode_feed : Str -> Api.Remote(Api.FeedPage)
	decode_feed = |body| {
		parse : Str -> Try(Api.FeedPage, [InvalidJson(Str)])
		parse = Json.parser_camel()
		to_remote(parse(body))
	}

	decode_article : Str -> Api.Remote(Api.Article)
	decode_article = |body| {
		parse : Str -> Try({ article : Api.Article }, [InvalidJson(Str)])
		parse = Json.parser_camel()
		to_remote(parse(body).map_ok(|envelope| envelope.article))
	}

	decode_profile : Str -> Api.Remote(Api.Profile)
	decode_profile = |body| {
		parse : Str -> Try({ profile : Api.Profile }, [InvalidJson(Str)])
		parse = Json.parser_camel()
		to_remote(parse(body).map_ok(|envelope| envelope.profile))
	}

	decode_comments : Str -> Api.Remote(List(Api.Comment))
	decode_comments = |body| {
		parse : Str -> Try({ comments : List(Api.Comment) }, [InvalidJson(Str)])
		parse = Json.parser_camel()
		to_remote(parse(body).map_ok(|envelope| envelope.comments))
	}

	decode_tags : Str -> Api.Remote(List(Str))
	decode_tags = |body| {
		parse : Str -> Try({ tags : List(Str) }, [InvalidJson(Str)])
		parse = Json.parser_camel()
		to_remote(parse(body).map_ok(|envelope| envelope.tags))
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

	to_remote : Try(a, [InvalidJson(Str)]) -> Api.Remote(a)
	to_remote = |result|
		match result {
			Ok(value) => Ready(value)
			Err(InvalidJson(_)) => Failed("Response was not valid JSON")
		}

	request_failed : Str -> Api.Remote(a)
	request_failed = |err| Failed("Request failed: ${err}")

	User : { email : Str, token : Str, username : Str }

	AuthResult : [AuthIdle, AuthAccepted(Api.User), AuthRejected(List(Str)), AuthErrored(Str)]

	# What a page's classifier reads of a response: its status and body, or
	# the error in their place.
	ResponseState : { status : U16, body : Str, error : Str, ready : Bool }

	## The status and text of an effect result, as page classifiers consume
	## it: any response (the pages classify 4xx envelopes themselves), or a
	## failure shown as its inspected `Engine.HttpFailure` (`Network("offline")`,
	## `Timeout`, `Refused`).
	response_of : Try(Engine.Response, Engine.HttpFailure) -> Api.ResponseState
	response_of = |res| match res {
		Ok({ status, headers: _, body }) => { status, body, error: "", ready: True }
		Err(error) => Api.failure(error)
	}

	failure : Engine.HttpFailure -> Api.ResponseState
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

	get_request : Str, Str -> Engine.Ask(Engine.Response, Engine.HttpFailure)
	get_request = |uri, token| Engine.http({ method: "GET", url: uri, headers: auth_headers(token), body: "", timeout: Ms(Api.timeout_ms) })

	post_request : Str, Str, Str -> Engine.Ask(Engine.Response, Engine.HttpFailure)
	post_request = |uri, body, token| Engine.http({ method: "POST", url: uri, headers: json_headers(token), body, timeout: Ms(Api.timeout_ms) })

	put_request : Str, Str, Str -> Engine.Ask(Engine.Response, Engine.HttpFailure)
	put_request = |uri, body, token| Engine.http({ method: "PUT", url: uri, headers: json_headers(token), body, timeout: Ms(Api.timeout_ms) })

	delete_request : Str, Str -> Engine.Ask(Engine.Response, Engine.HttpFailure)
	delete_request = |uri, token| Engine.http({ method: "DELETE", url: uri, headers: auth_headers(token), body: "", timeout: Ms(Api.timeout_ms) })

	## A GET whose body decodes into a page resource.
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
			parse : Str -> Try({ user : Api.User }, [InvalidJson(Str)])
			parse = Json.parser_camel()
			match parse(response.body) {
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

	# The scan finds each string by its quotes, so the escapes a JSON
	# string may carry are swapped for private-use placeholder characters
	# before it and put back in each entry (`restore_text`). A `\uXXXX`
	# escape is left as it is written.
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

	replace : Str, Str, Str -> Str
	replace = |text, from, to| Str.join_with(text.split_on(from), to)

	## Each step of the scan may run out of input; `?` short-circuits to the
	## entries collected so far.
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

## An escaped quote inside a message does not end it.
expect Api.parse_errors("{\"errors\":{\"title\":[\"must not be \\\"draft\\\"\"]}}") == ["title must not be \"draft\""]

## A decoded string holds the characters its JSON escapes stand for.
expect Api.decode_tags("{\"tags\":[\"two\\nlines\",\"a \\\"quoted\\\" word\"]}") == Ready(["two\nlines", "a \"quoted\" word"])

## A body with no "errors" key falls back to a single generic rejection sentence.
expect Api.parse_errors("{\"message\":\"nope\"}") == ["The request was rejected."]

## Tags remain one form value, including literal plus, percent, and delimiters.
expect {
	values = [("c&c", "c%26c"), ("a?b", "a%3Fb"), ("c++", "c%2B%2B"), ("c#", "c%23"), ("%41", "%2541"), ("a b", "a+b")]
	values.all(|(value, encoded)| Api.feed_uri({ page: 1, tag: Tagged(value), source: Global }) == "/api/articles?limit=20&offset=0&tag=${encoded}")
}

## Usernames cannot inject another author filter and remain one path segment.
expect Api.author_articles_uri("x&favorited=anna") == "/api/articles?limit=20&offset=0&author=x%26favorited%3Danna" and Api.profile_uri("anna?x") == Ok("/api/profiles/anna%3Fx") and Api.profile_uri("a/b") == Ok("/api/profiles/a%2Fb")

## Unsafe supplied resource names retain their typed refusal.
expect Api.article_uri("..") == Err(DotSegment("..")) and Api.profile_uri(".") == Err(DotSegment(".")) and Api.comments_uri("") == Err(EmptySegment)
