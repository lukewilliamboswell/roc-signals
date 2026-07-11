## Shared article-list rendering: loading/failed/empty states, keyed article
## previews, and pagination links. Used by the home feeds and the profile
## tabs. Pagination rows encode page and tag in the row key because keyed
## rows only receive static keys plus item signals; the row parses its key
## back into a target location (a construction-order identity workaround
## recorded in the findings ledger).
import Api
import Format
import Nav
import Route
import Session
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Feed := {}.{
	PageItem : { key : Str, active : Bool }

	State : { favorite_serial : U64 }

	FavoriteResult : [FavoriteIdle, FavoriteAccepted(Api.Article), FavoriteRejected(Str)]

	initial_state : Feed.State
	initial_state = { favorite_serial: 0 }

	view : Signal.Signal(Api.Remote(Api.FeedPage)), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	view = |remote, session, intent| {
		is_loading : Signal.Signal(Bool)
		is_loading = remote.map(is_loading_state)

		is_failed : Signal.Signal(Bool)
		is_failed = remote.map(is_failed_state)

		is_empty : Signal.Signal(Bool)
		is_empty = remote.map(is_empty_state)

		articles : Signal.Signal(List(Api.ArticleSummary))
		articles = remote.map(articles_of)

		message : Signal.Signal(Str)
		message = remote.map(failure_message)

		article_key : Api.ArticleSummary -> Str
		article_key = |article| article.slug

		article_row : Str, Signal.Signal(Api.ArticleSummary) -> Elem
		article_row = |key, article| preview_row(key, article, session, intent)

		Ui.component(
			|| Html.div(
				[Html.attr("data-conduit", "article-list")],
				[
					Ui.when(
						is_loading,
						|| Html.paragraph("Loading articles..."),
						|| Ui.when(
							is_failed,
							|| Html.paragraph_s_c(message, "text-red-700"),
							|| Ui.when(
								is_empty,
								|| Html.paragraph("No articles are here... yet."),
								|| Ui.each_str(articles, article_key, article_row),
							),
						),
					),
				],
			),
		)
	}

	is_failed_state : Api.Remote(Api.FeedPage) -> Bool
	is_failed_state = |remote|
		match remote {
			Failed(_) => True
			_ => False
		}

	is_empty_state : Api.Remote(Api.FeedPage) -> Bool
	is_empty_state = |remote|
		match remote {
			Ready(page) => page.articles.is_empty()
			_ => False
		}

	articles_of : Api.Remote(Api.FeedPage) -> List(Api.ArticleSummary)
	articles_of = |remote|
		match remote {
			Ready(page) => page.articles
			_ => []
		}

	failure_message : Api.Remote(Api.FeedPage) -> Str
	failure_message = |remote|
		match remote {
			Failed(message) => message
			_ => ""
		}

	preview_row : Str, Signal.Signal(Api.ArticleSummary), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	preview_row = |slug, article, session, intent| {
		Ui.component(
			|| {
				Ui.state(
					initial_state,
					|model| {
						favorite_task = Http.request_task("feed-favorite")
						favorite_result : Signal.Signal(Feed.FavoriteResult)
						favorite_result = Signal.fold_task(
							favorite_task,
							FavoriteIdle,
							classify_favorite,
							|err| FavoriteRejected("Request failed: ${Http.error_text(err)}"),
						)

						model_signal = model.signal()
						token = session.map(|value| Session.token_of(value))
						row = { article: article, result: favorite_result }.Signal.map(|value| row_state(value.article, value.result))
						request_inputs = { model: model_signal, row: row, token: token }.Signal
						request = request_inputs.map(|value| { serial: value.model.favorite_serial, slug: value.row.slug, favorited: value.row.favorited, token: value.token })

						date_text : Signal.Signal(Str)
						date_text = article.map(|value| Format.display_date(value.created_at))

						title : Signal.Signal(Str)
						title = row.map(|value| value.title)

						description : Signal.Signal(Str)
						description = row.map(|value| value.description)

						favorites : Signal.Signal(Str)
						favorites = row.map(|value| "${value.favorites_count.to_str()} favorites")

						favorite_label : Signal.Signal(Str)
						favorite_label = row.map(favorite_button_label)

						favorite_error : Signal.Signal(Str)
						favorite_error = favorite_result.map(favorite_message_of)

						author_rows : Signal.Signal(List(Str))
						author_rows = article.map(|value| [value.author.username])

						tags : Signal.Signal(List(Str))
						tags = article.map(|value| value.tag_list)

						signed_in = session.map(|value| Session.is_signed_in(value))

						Elem.Element(
							{
								tag: "article",
								attrs: [Html.class_attr("border-t border-zinc-200 py-4")],
								children: [
									Ui.on_change(
										request,
										|value|
											if value.serial == 0 or value.slug.is_empty() {
												Signal.noop
											} else if value.favorited {
												Http.start(favorite_task, Api.delete_request(Api.favorite_uri(value.slug), value.token))
											} else {
												Http.start(favorite_task, Api.post_request(Api.favorite_uri(value.slug), "", value.token))
											},
									),
									Html.div_c(
										"flex items-center gap-2 text-sm text-zinc-500",
										[
											Ui.each_str(author_rows, |name| name, |name, _| Nav.link(name, "font-medium text-emerald-600", Route.profile_location(name), intent)),
											Html.text_s(date_text),
										],
									),
									Elem.Element(
										{
											tag: "a",
											attrs: [
												Html.class_attr("block text-lg font-semibold"),
												Html.attr("href", "/article/${slug}"),
												Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| Nav.for_target(current, Route.article_location(slug)))),
											],
											children: [Html.text_s(title)],
										},
									),
									Html.paragraph_s_c(description, "text-zinc-500"),
									Html.div_c(
										"flex items-center justify-between text-sm text-zinc-500",
										[
											Ui.when(
												signed_in,
												|| Html.action_button_attrs(
													favorite_label,
													favorite_label.map(|_| False),
													[Html.class_attr("rounded border border-emerald-600 px-2 py-1 text-emerald-700")],
													model.on_unit(|value| { favorite_serial: value.favorite_serial + 1 }),
												),
												|| Html.text_s(favorites),
											),
											Html.div_c(
												"flex gap-1",
												[Ui.each_str(tags, |tag| tag, |tag, _| tag_pill(tag, intent))],
											),
										],
									),
									Html.paragraph_s_c(favorite_error, "text-red-700"),
								],
							},
						)
					},
				)
			},
		)
	}

	classify_favorite : _ -> Feed.FavoriteResult
	classify_favorite = |response| {
		status = Http.response_status(response)
		if status == 200 {
			match Api.decode_article(Api.response_text(response)) {
				Ready(article) => FavoriteAccepted(article)
				Failed(message) => FavoriteRejected(message)
				Loading => FavoriteRejected("The server response could not be read.")
			}
		} else if status == 401 {
			FavoriteRejected("Please sign in to favorite articles.")
		} else if status == 404 {
			FavoriteRejected("Article was not found.")
		} else {
			FavoriteRejected("The server responded with status ${status.to_str()}.")
		}
	}

	row_state : Api.ArticleSummary, Feed.FavoriteResult -> Api.ArticleSummary
	row_state = |article, result|
		match result {
			FavoriteAccepted(updated) => {
				..article,
				favorited: updated.favorited,
				favorites_count: updated.favorites_count,
			}
			_ => article
		}

	favorite_button_label : Api.ArticleSummary -> Str
	favorite_button_label = |article| {
		prefix =
			if article.favorited {
				"Unfavorite"
			} else {
				"Favorite"
			}
		"${prefix} ${article.title} (${article.favorites_count.to_str()})"
	}

	favorite_message_of : Feed.FavoriteResult -> Str
	favorite_message_of = |result|
		match result {
			FavoriteRejected(message) => message
			_ => ""
		}

	tag_pill : Str, Ui.State(Nav.RouteIntent) -> Elem
	tag_pill = |tag, intent|
		Nav.link(tag, "rounded-full border border-zinc-300 px-2 text-xs text-zinc-500", Route.feed_location({ page: 1, tag: Tagged(tag), source: Global }), intent)

	pagination : Signal.Signal(Api.Remote(Api.FeedPage)), Signal.Signal(Route.Feed), Ui.State(Nav.RouteIntent) -> Elem
	pagination = |remote, feed, intent| {
		inputs = { remote: remote, feed: feed }.Signal
		items = inputs.map(|value| page_items(value.remote, value.feed))
		Elem.Element(
			{
				tag: "nav",
				attrs: [Html.attr("aria-label", "Pagination"), Html.class_attr("flex gap-1 py-2")],
				children: [Ui.each_str(items, |item| item.key, page_link_row(intent))],
			},
		)
	}

	page_link_row : Ui.State(Nav.RouteIntent) -> (Str, Signal.Signal(Feed.PageItem) -> Elem)
	page_link_row = |intent|
		|key, item| {
			classes = item.map(
				|value|
					if value.active {
						"rounded bg-emerald-600 px-2 text-white"
					} else {
						"rounded border border-zinc-300 px-2 text-zinc-600"
					},
			)
			target = key_location(key)
			Nav.link_c(page_label(key), classes, target, intent)
		}

	page_items : Api.Remote(Api.FeedPage), Route.Feed -> List(Feed.PageItem)
	page_items = |remote, feed|
		match remote {
			Ready(page) => {
				pages = Api.page_count(page.articles_count)
				if pages <= 1 {
					[]
				} else {
					number_range(1, pages).map(|number| { key: page_key(number, feed.tag), active: number == feed.page })
				}
			}
			_ => []
		}

	page_key : U64, [AllTags, Tagged(Str)] -> Str
	page_key = |number, tag|
		match tag {
			Tagged(name) => "${number.to_str()}|${name}"
			AllTags => "${number.to_str()}|"
		}

	page_label : Str -> Str
	page_label = |key|
		match key.find_first("|") {
			Ok(split) => split.before
			Err(_) => key
		}

	key_location : Str -> Browser.Location
	key_location = |key|
		match key.find_first("|") {
			Ok(split) => {
				page =
					match U64.from_str(split.before) {
						Ok(number) => number
						Err(_) => 1
					}
				tag =
					if split.after.is_empty() {
						AllTags
					} else {
						Tagged(split.after)
					}
				Route.feed_location({ page: page, tag: tag, source: Global })
			}
			Err(_) => Route.home_location
		}

	number_range : U64, U64 -> List(U64)
	number_range = |from, to|
		if from > to {
			[]
		} else {
			[from].concat(number_range(from + 1, to))
		}

	is_loading_state : Api.Remote(Api.FeedPage) -> Bool
	is_loading_state = |remote|
		match remote {
			Loading => True
			_ => False
		}

}
