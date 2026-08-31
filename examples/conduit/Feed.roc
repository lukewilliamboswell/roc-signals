## Shared article-list rendering: loading/failed/empty states, keyed article
## previews, and pagination links. Used by the home feeds and the profile
## tabs. Pagination rows encode page and tag in the row key because keyed
## rows only receive static keys plus item signals; the row parses its key
## back into a target location as a construction-order identity workaround.
import Api
import Format
import Nav
import Route
import Session
import Styles
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
		is_loading = remote.map(Api.is_loading)

		is_failed : Signal.Signal(Bool)
		is_failed = remote.map(Api.is_failed)

		is_empty : Signal.Signal(Bool)
		is_empty = remote.map(is_empty_state)

		articles : Signal.Signal(List(Api.ArticleSummary))
		articles = remote.map(articles_of)

		message : Signal.Signal(Str)
		message = remote.map(Api.failure_message)

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
						|| Html.paragraph_c("Loading articles...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
						|| Ui.when(
							is_failed,
							|| Html.paragraph_s_c(message, Styles.status_error),
							|| Ui.when(
								is_empty,
								|| Html.paragraph_c("No articles are here... yet.", "rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"),
								|| Ui.each(articles, article_key, |each_row| article_row(each_row.key(), each_row.signal())),
							),
						),
					),
				],
			),
		)
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


	preview_row : Str, Signal.Signal(Api.ArticleSummary), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	preview_row = |slug, article, session, intent| {
		Ui.component(
			|| {
				Ui.state(
					initial_state,
					|model| {
						favorite_task = Http.request_task("feed-favorite")
						favorite_result : Signal.Signal(Feed.FavoriteResult)
						favorite_result = Api.response_state(favorite_task).map(classify_favorite)

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
								attrs: [Html.class_attr("border-b border-zinc-200 bg-white py-6 first:border-t")],
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
										"mb-3 flex flex-wrap items-center gap-2 text-sm text-zinc-500",
										[
											Ui.each(author_rows, |name| name, |each_row| Nav.link(each_row.key(), "font-medium text-emerald-600", Route.profile_location(each_row.key()), intent)),
											Html.text_s(date_text),
										],
									),
									Elem.Element(
										{
											tag: "a",
											attrs: [
											Html.class_attr("block text-2xl font-semibold tracking-normal text-zinc-900 no-underline hover:text-emerald-700 hover:no-underline"),
												Html.attr("href", "/article/${slug}"),
												Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| Nav.for_target(current, Route.article_location(slug)))),
											],
											children: [Html.text_s(title)],
										},
									),
									Html.paragraph_s_c(description, "mt-2 leading-7 text-zinc-600"),
									Html.div_c(
										"mt-4 flex flex-wrap items-center justify-between gap-3 text-sm text-zinc-500",
										[
											Ui.when(
												signed_in,
												|| Html.action_button_attrs(
													favorite_label,
													favorite_label.map(|_| False),
												[Html.class_attr("rounded-full border border-emerald-500 bg-white px-3 py-1.5 font-medium text-emerald-700 transition hover:bg-emerald-50")],
													model.on_unit(|value| { favorite_serial: value.favorite_serial + 1 }),
												),
												|| Html.text_s(favorites),
											),
											Html.div_c(
												"flex gap-1",
												[Ui.each(tags, |tag| tag, |each_row| tag_pill(each_row.key(), intent))],
											),
										],
									),
									Html.paragraph_s_c(favorite_error, "mt-3 text-sm text-red-700"),
								],
							},
						)
					},
				)
			},
		)
	}

	classify_favorite : Api.ResponseState -> Feed.FavoriteResult
	classify_favorite = |response| {
		if !response.ready {
			FavoriteIdle
		} else if !response.error.is_empty() {
			FavoriteRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_article(response.body) {
				Ready(article) => FavoriteAccepted(article)
				Failed(message) => FavoriteRejected(message)
				Loading => FavoriteRejected("The server response could not be read.")
			}
		} else if response.status == 401 {
			FavoriteRejected("Please sign in to favorite articles.")
		} else if response.status == 404 {
			FavoriteRejected("Article was not found.")
		} else {
			FavoriteRejected("The server responded with status ${response.status.to_str()}.")
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
		Nav.link(tag, "rounded-full border border-zinc-300 px-2.5 py-1 text-xs text-zinc-500 no-underline hover:border-emerald-400 hover:text-emerald-700 hover:no-underline", Route.feed_location({ page: 1, tag: Tagged(tag), source: Global }), intent)

	pagination : Signal.Signal(Api.Remote(Api.FeedPage)), Signal.Signal(Route.Feed), Ui.State(Nav.RouteIntent) -> Elem
	pagination = |remote, feed, intent| {
		inputs = { remote: remote, feed: feed }.Signal
		items = inputs.map(|value| page_items(value.remote, value.feed))
		Elem.Element(
			{
				tag: "nav",
				attrs: [Html.attr("aria-label", "Pagination"), Html.class_attr("flex flex-wrap gap-2 py-6")],
				children: [Ui.each(items, |item| item.key, |each_row| page_link_row(intent)(each_row.key(), each_row.signal()))],
			},
		)
	}

	page_link_row : Ui.State(Nav.RouteIntent) -> (Str, Signal.Signal(Feed.PageItem) -> Elem)
	page_link_row = |intent|
		|key, item| {
			classes = item.map(
				|value|
					if value.active {
						"rounded-lg bg-emerald-600 px-3 py-2 text-sm font-medium text-white no-underline hover:text-white hover:no-underline"
					} else {
						"rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-600 no-underline hover:border-emerald-500 hover:no-underline"
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
	page_label = |key| key.split_first("|").map_ok(|split| split.before) ?? key

	key_location : Str -> Browser.Location
	key_location = |key|
		key.split_first("|").map_ok(
			|split| {
				page = U64.from_str(split.before) ?? 1
				tag =
					if split.after.is_empty() {
						AllTags
					} else {
						Tagged(split.after)
					}
				Route.feed_location({ page: page, tag: tag, source: Global })
			},
		)
		?? Route.home_location

	number_range : U64, U64 -> List(U64)
	number_range = |from, to|
		if from > to {
			[]
		} else {
			[from].concat(number_range(from + 1, to))
		}


}

## A pagination row key renders the bare page number as its button label.
expect Feed.page_label(Feed.page_key(3, Tagged("roc"))) == "3"

## ...and decodes back to the exact location that page and tag came from, which
## is the only channel a keyed row has to its navigation target.
expect Feed.key_location(Feed.page_key(3, Tagged("roc"))) == Route.feed_location({ page: 3, tag: Tagged("roc"), source: Global })

## Page one with no tag decodes to the bare home location, not a query string.
expect Feed.key_location(Feed.page_key(1, AllTags)) == Route.home_location
