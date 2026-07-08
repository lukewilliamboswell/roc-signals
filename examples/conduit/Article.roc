## Article page: fetches one article by slug, renders the markdown body to
## Elem nodes, and overrides the document title with the loaded article
## title (the route-derived slug title stands until the response lands).
import Api
import Format
import Markdown
import Nav
import Route
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Article := {}.{
	page : Signal.Signal(Route), Ui.State(Nav.RouteIntent) -> Elem
	page = |route, intent| {
		Ui.component(
			|_| {
				task = Http.get_text_task("article")
				state = Signal.fold_task(task, Loading, Api.decode_article, Api.request_failed)
				slug = Signal.map(route, |value| Route.article_slug(value))
				is_loading = Signal.map(state, article_loading)
				is_failed = Signal.map(state, article_failed)
				message = Signal.map(state, article_message)
				title = Signal.map(state, article_title)
				body = Signal.map(state, article_body)
				meta = Signal.map(state, article_meta)
				author_rows = Signal.map(state, article_author_rows)
				loaded_title = Signal.map(state, article_title)

				Html.section(
					"Article",
					[Html.class_attr("px-4 py-6")],
					[
						Ui.on_change_initial(
							slug,
							|value|
								if Str.is_empty(value) {
									Signal.noop
								} else {
									Http.get_text(task, Api.article_uri(value))
								},
						),
						Ui.on_change(
							loaded_title,
							|value|
								if Str.is_empty(value) {
									Signal.noop
								} else {
									Browser.set_title("${value} - Conduit")
								},
						),
						Ui.when(
							is_loading,
							|_| Html.paragraph("Loading article..."),
							|_|
								Ui.when(
									is_failed,
									|_| Html.paragraph_s_c(message, "text-red-700"),
									|_|
										Html.div(
											[Html.attr("data-conduit", "article")],
											[
												Elem.Element({ tag: "h2", attrs: [Html.class_attr("text-2xl font-bold")], children: [Html.text_s(title)] }),
												Html.div_c(
													"flex items-center gap-2 py-2 text-sm text-zinc-500",
													[
														Ui.each_str(author_rows, |name| name, |name, _| Nav.link(name, "font-medium text-emerald-600", Route.profile_location(name), intent)),
														Html.text_s(meta),
													],
												),
												Markdown.view(body),
											],
										),
								),
						),
					],
				)
			},
		)
	}

	article_loading : Api.Remote(Api.Article) -> Bool
	article_loading = |remote|
		match remote {
			Loading => True
			_ => False
		}

	article_failed : Api.Remote(Api.Article) -> Bool
	article_failed = |remote|
		match remote {
			Failed(_) => True
			_ => False
		}

	article_message : Api.Remote(Api.Article) -> Str
	article_message = |remote|
		match remote {
			Failed(message) => message
			_ => ""
		}

	article_title : Api.Remote(Api.Article) -> Str
	article_title = |remote|
		match remote {
			Ready(article) => article.title
			_ => ""
		}

	article_body : Api.Remote(Api.Article) -> Str
	article_body = |remote|
		match remote {
			Ready(article) => article.body
			_ => ""
		}

	article_meta : Api.Remote(Api.Article) -> Str
	article_meta = |remote|
		match remote {
			Ready(article) => "${Format.display_date(article.created_at)} | ${article.favorites_count.to_str()} favorites"
			_ => ""
		}

	article_author_rows : Api.Remote(Api.Article) -> List(Str)
	article_author_rows = |remote|
		match remote {
			Ready(article) => [article.author.username]
			_ => []
		}
}
