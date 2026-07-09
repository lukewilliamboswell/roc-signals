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
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Feed := {}.{
	PageItem : { key : Str, active : Bool }

	view : Signal.Signal(Api.Remote(Api.FeedPage)), Ui.State(Nav.RouteIntent) -> Elem
	view = |remote, intent| {
		is_loading = Signal.map(remote, is_loading_state)
		is_failed = Signal.map(remote, is_failed_state)
		is_empty = Signal.map(remote, is_empty_state)
		articles = Signal.map(remote, articles_of)
		message = Signal.map(remote, failure_message)
		Ui.component(
			|_|
				Html.div(
					[Html.attr("data-conduit", "article-list")],
					[
						Ui.when(
							is_loading,
							|_| Html.paragraph("Loading articles..."),
							|_|
								Ui.when(
									is_failed,
									|_| Html.paragraph_s_c(message, "text-red-700"),
									|_|
										Ui.when(
											is_empty,
											|_| Html.paragraph("No articles are here... yet."),
											|_| Ui.each_str(articles, |article| article.slug, |key, article| preview_row(key, article, intent)),
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
			Ready(page) => List.is_empty(page.articles)
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

	preview_row : Str, Signal.Signal(Api.ArticleSummary), Ui.State(Nav.RouteIntent) -> Elem
	preview_row = |slug, article, intent| {
		date_text = Signal.map(article, |value| Format.display_date(value.created_at))
		title = Signal.map(article, |value| value.title)
		description = Signal.map(article, |value| value.description)
		favorites = Signal.map(article, |value| "${value.favorites_count.to_str()} favorites")
		author_rows = Signal.map(article, |value| [value.author.username])
		tags = Signal.map(article, |value| value.tag_list)
		Elem.Element(
			{
				tag: "article",
				attrs: [Html.class_attr("border-t border-zinc-200 py-4")],
				children: [
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
							Html.text_s(favorites),
							Html.div_c(
								"flex gap-1",
								[Ui.each_str(tags, |tag| tag, |tag, _| tag_pill(tag, intent))],
							),
						],
					),
				],
			},
		)
	}

	tag_pill : Str, Ui.State(Nav.RouteIntent) -> Elem
	tag_pill = |tag, intent|
		Nav.link(tag, "rounded-full border border-zinc-300 px-2 text-xs text-zinc-500", Route.feed_location({ page: 1, tag: Tagged(tag), source: Global }), intent)

	pagination : Signal.Signal(Api.Remote(Api.FeedPage)), Signal.Signal(Route.Feed), Ui.State(Nav.RouteIntent) -> Elem
	pagination = |remote, feed, intent| {
		items = Signal.map2(remote, feed, page_items)
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
			classes = Signal.map(
				item,
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
		match Str.find_first(key, "|") {
			Ok(split) => split.before
			Err(_) => key
		}

	key_location : Str -> Browser.Location
	key_location = |key|
		match Str.find_first(key, "|") {
			Ok(split) => {
				page =
					match U64.from_str(split.before) {
						Ok(number) => number
						Err(_) => 1
					}
				tag =
					if Str.is_empty(split.after) {
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
			List.concat([from], number_range(from + 1, to))
		}

	is_loading_state : Api.Remote(Api.FeedPage) -> Bool
	is_loading_state = |remote|
		match remote {
			Loading => True
			_ => False
		}


}
