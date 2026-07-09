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
			|| {
				task = Http.get_text_task("article")
				state : Signal.Signal(Api.Remote(Api.Article))
				state = Signal.fold_task(task, Loading, Api.decode_article, Api.request_failed)
				slug = route.map(|value| Route.article_slug(value))

				is_loading : Signal.Signal(Bool)
				is_loading = state.map(article_loading)

				is_failed : Signal.Signal(Bool)
				is_failed = state.map(article_failed)

				message : Signal.Signal(Str)
				message = state.map(article_message)

				title : Signal.Signal(Str)
				title = state.map(article_title)

				body : Signal.Signal(Str)
				body = state.map(article_body)

				meta : Signal.Signal(Str)
				meta = state.map(article_meta)

				author_rows : Signal.Signal(List(Str))
				author_rows = state.map(article_author_rows)

				loaded_title = title

				Html.section(
					"Article",
					[Html.class_attr("px-4 py-6")],
					[
						Ui.on_change_initial(
							slug,
							|value|
								if value.is_empty() {
									Signal.noop
								} else {
									Http.get_text(task, Api.article_uri(value))
								},
						),
						Ui.on_change(
							loaded_title,
							|value|
								if value.is_empty() {
									Signal.noop
								} else {
									Browser.set_title("${value} - Conduit")
								},
						),
						Ui.when(
							is_loading,
							|| Html.paragraph("Loading article..."),

							|| Ui.when(
								is_failed,
								|| Html.paragraph_s_c(message, "text-red-700"),

								|| Html.div(
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
