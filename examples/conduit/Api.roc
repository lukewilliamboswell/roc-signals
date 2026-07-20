## RealWorld API surface: DTO records, camelCase JSON decoding through the
## builtin Json (single wide-enough parses; roc#9964 no longer reproduces on
## the current nightly, see wip/research/realworld_demo_findings.md), URI
## builders, auth headers (`Authorization: Token <jwt>` per the spec), and
## the Remote loading/ready/failed shape every fetch surface renders from.
import Route
import pf.Http
import pf.Signal

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
		match to_remote(parse(shield_escapes(body))) {
			Ready(page) => Ready({ ..page, articles: page.articles.map(restore_summary) })
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_article : Str -> Api.Remote(Api.Article)
	decode_article = |body| {
		parse : Str -> Try({ article : Api.Article }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready(restore_article(envelope.article))
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_profile : Str -> Api.Remote(Api.Profile)
	decode_profile = |body| {
		parse : Str -> Try({ profile : Api.Profile }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready({ ..envelope.profile, bio: restore_text(envelope.profile.bio) })
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_comments : Str -> Api.Remote(List(Api.Comment))
	decode_comments = |body| {
		parse : Str -> Try({ comments : List(Api.Comment) }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready(envelope.comments.map(restore_comment))
			Loading => Loading
			Failed(message) => Failed(message)
		}
	}

	decode_tags : Str -> Api.Remote(List(Str))
	decode_tags = |body| {
		parse : Str -> Try({ tags : List(Str) }, [InvalidJson(Str), MissingRequiredField(Str)])
		parse = Json.parser_camel()
		match to_remote(parse(shield_escapes(body))) {
			Ready(envelope) => Ready(envelope.tags)
			Loading => Loading
			Failed(message) => Failed(message)
		}
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
	# wip/research/realworld_demo_findings.md).

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

	# Keep the package-owned Response value confined to one small transform.
	# Current Roc main overflows its compiler stack when a task fold transforms
	# that opaque value directly into Conduit's larger domain unions.
	ResponseState : { status : U16, body : Str, error : Str, ready : Bool }

	response_state = |task|
		Signal.fold_task(
			task,
			{ status: 0, body: "", error: "", ready: False },
			|response| { status: Http.response_status(response), body: response_text(response), error: "", ready: True },
			|err| { status: 0, body: "", error: Http.error_text(err), ready: True },
		)

	auth_headers : Str -> List(Http.Header)
	auth_headers = |token| if token.is_empty() { [] } else { [{ name: "authorization", value: "Token ${token}" }] }

	json_headers : Str -> List(Http.Header)
	json_headers = |token|
		if token.is_empty() {
			[{ name: "content-type", value: "application/json" }]
		} else {
			[
				{ name: "content-type", value: "application/json" },
				{ name: "authorization", value: "Token ${token}" },
			]
		}

	# Authenticated requests use the full request/response path because the
	# text-task helpers cannot carry headers.
	get_request : Str, Str -> _
	get_request = |uri, token| {
		Http.with_timeout_ms(
			Http.with_headers(
				Http.request_from_method(Http.method_get)
					.with_uri(uri),
				auth_headers(token),
			),
			8000,
		)
	}

	post_request : Str, Str, Str -> _
	post_request = |uri, body, token| {
		Http.with_timeout_ms(
			Http.with_headers(
				Http.request_from_method(Http.method_post)
					.with_uri(uri)
					.with_body(body.to_utf8()),
				json_headers(token),
			),
			8000,
		)
	}

	put_request : Str, Str, Str -> _
	put_request = |uri, body, token| {
		Http.with_timeout_ms(
			Http.with_headers(
				Http.request_from_method(Http.method_put)
					.with_uri(uri)
					.with_body(body.to_utf8()),
				json_headers(token),
			),
			8000,
		)
	}

	delete_request : Str, Str -> _
	delete_request = |uri, token| {
		Http.with_timeout_ms(
			Http.with_headers(
				Http.request_from_method(Http.method_delete)
					.with_uri(uri),
				auth_headers(token),
			),
			8000,
		)
	}

	feed_request : Route.Feed, Str -> _
	feed_request = |feed, token| get_request(feed_uri(feed), token)

	feed_uri_for : Route.Feed -> Str
	feed_uri_for = |feed| feed_uri(feed)

	login_body : Str, Str -> Str
	login_body = |email, password| Json.to_str({ user: { email: email, password: password } })

	register_body : Str, Str, Str -> Str
	register_body = |username, email, password|
		Json.to_str({ user: { username: username, email: email, password: password } })

	response_text : _ -> Str
	response_text = |response| Str.from_utf8_lossy(Http.response_body(response))

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
	# per key, first message only. JSON/body ergonomics evidence for
	# NEXT_STEPS priority 3 (see the findings ledger).
	parse_errors : Str -> List(Str)
	parse_errors = |body| {
		shielded = shield_escapes(body)
		match shielded.find_first("\"errors\"") {
			Ok(split) => collect_errors(split.after, [])
			Err(_) => ["The request was rejected."]
		}
	}

	collect_errors : Str, List(Str) -> List(Str)
	collect_errors = |rest, acc|
		match rest.find_first("\"") {
			Err(_) => acc
			Ok(key_open) =>
				match key_open.after.find_first("\"") {
					Err(_) => acc
					Ok(key_close) =>
						match key_close.after.find_first("[\"") {
							Err(_) => acc
							Ok(list_open) =>
								match list_open.after.find_first("\"") {
									Err(_) => acc
									Ok(message_close) => {
										entry = restore_text("${key_close.before} ${message_close.before}")
										next = acc.append(entry)
										match message_close.after.find_first("]") {
											Err(_) => next
											Ok(list_close) => collect_errors(list_close.after, next)
										}
									}
								}
						}
				}
		}
}
