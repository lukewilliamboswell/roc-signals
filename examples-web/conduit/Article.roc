## Article page: fetches one article by slug, renders markdown, comments,
## and server-confirmed write actions for delete and comments.
import Api
import Auth
import Load
import Format
import Markdown
import Nav
import Route
import Session
import Styles
import pf.Action
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

Article := {}.{
	State : {
		article_delete_result : Article.DeleteResult,
		favorite_result : Article.FavoriteResult,
		favorite_generation : U64,
		comment_result : Article.CommentResult,
		comment_delete_result : Article.CommentDeleteResult,
		article_delete_serial : U64,
		comment_body : Str,
		comment_serial : U64,
		submitted_comment_body : Str,
		comment_delete_serial : U64,
		comment_delete_id : U64,
	}

	DeleteResult : [DeleteIdle, DeleteAccepted, DeleteRejected(Str)]

	FavoriteResult : [FavoriteIdle, FavoriteAccepted(Api.Article), FavoriteRejected(Str)]

	CommentResult : [CommentIdle, CommentAccepted, CommentRejected(List(Str)), CommentErrored(Str)]

	CommentDeleteResult : [CommentDeleteIdle, CommentDeleteAccepted, CommentDeleteRejected(Str)]

	initial_state : Article.State
	initial_state = {
		article_delete_result: DeleteIdle,
		favorite_result: FavoriteIdle,
		favorite_generation: 0,
		comment_result: CommentIdle,
		comment_delete_result: CommentDeleteIdle,
		article_delete_serial: 0,
		comment_body: "",
		comment_serial: 0,
		submitted_comment_body: "",
		comment_delete_serial: 0,
		comment_delete_id: 0,
	}

	page : Signal.Signal(Route), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	page = |route, session, intent| {
		Ui.state(
			{ generation: 0.U64, value: Loading },
			|article| {
				Ui.state(
					{ generation: 0.U64, value: Loading },
					|comments| {
						Ui.component(
							|| {
								Ui.state(
									initial_state,
									|model| {

										article_state : Signal.Signal(Api.Remote(Api.Article))
										article_state = article.signal().map(|value| value.value)

										comments_state : Signal.Signal(Api.Remote(List(Api.Comment)))
										comments_state = comments.signal().map(|value| value.value)

										article_delete_result : Signal.Signal(Article.DeleteResult)
										article_delete_result = model.signal().map(|value| value.article_delete_result)

										favorite_result : Signal.Signal(Article.FavoriteResult)
										favorite_result = model.signal().map(|value| value.favorite_result)

										comment_result : Signal.Signal(Article.CommentResult)
										comment_result = model.signal().map(|value| value.comment_result)

										comment_delete_result : Signal.Signal(Article.CommentDeleteResult)
										comment_delete_result = model.signal().map(|value| value.comment_delete_result)

										slug = route.map(|value| Route.article_slug(value))
										token = session.map(|value| Session.token_of(value))
										model_signal = model.signal()

										article_delete_inputs = { model: model_signal, slug: slug, token: token }.Signal
										article_delete_request = article_delete_inputs.map(|value| { serial: value.model.article_delete_serial, slug: value.slug, token: value.token })

										favorite_action = Action.run(
											{ article: article_state, slug: slug, token: token, generation: model.signal().map(|value| value.favorite_generation) }.Signal,
											|read| if read.slug.is_empty() {
												Action.none
											} else {
												generation = read.generation + 1
												Action.then([model.write(|current| { ..current, favorite_generation: generation, favorite_result: FavoriteIdle })], |_| favorite!(model, read, generation))
											},
										)

										comment_inputs = { model: model_signal, slug: slug, token: token }.Signal
										comment_request = comment_inputs.map(|value| { serial: value.model.comment_serial, body: value.model.submitted_comment_body, slug: value.slug, token: value.token })

										comment_delete_inputs = { model: model_signal, slug: slug, token: token }.Signal
										comment_delete_request = comment_delete_inputs.map(
											|value| { serial: value.model.comment_delete_serial, id: value.model.comment_delete_id, slug: value.slug, token: value.token },
										)

										comment_create_refetch = { result: comment_result, slug: slug }.Signal
										comment_delete_refetch = { result: comment_delete_result, slug: slug }.Signal

										article_refetch = { result: favorite_result, slug: slug }.Signal

										is_loading : Signal.Signal(Bool)
										is_loading = article_state.map(Api.is_loading)

										is_failed : Signal.Signal(Bool)
										is_failed = article_state.map(Api.is_failed)

										message : Signal.Signal(Str)
										message = article_state.map(Api.failure_message)

										title : Signal.Signal(Str)
										title = article_state.map(article_title)

										body : Signal.Signal(Str)
										body = article_state.map(article_body)

										meta : Signal.Signal(Str)
										meta = article_state.map(article_meta)

										author_rows : Signal.Signal(List(Str))
										author_rows = article_state.map(article_author_rows)

										can_delete_inputs = { article: article_state, session: session }.Signal
										can_delete = can_delete_inputs.map(|value| can_delete_article(value.article, value.session))

										can_favorite = session.map(|value| Session.is_signed_in(value))
										favorite_label = article_state.map(favorite_button_label)
										favorite_message = favorite_result.map(favorite_message_of)

										article_delete_message = article_delete_result.map(article_delete_message_of)
										article_delete_done = article_delete_result.map(article_delete_done_of)

										comment_body = model_signal.map(|value| value.comment_body)
										comment_errors = comment_result.map(comment_error_lines)
										comment_delete_message = comment_delete_result.map(comment_delete_message_of)
										signed_in = session.map(|value| Session.is_signed_in(value))
										loaded_title = title

										Html.section(
											"Article",
											[Html.class_attr(Styles.wide_page)],
											[
												# Both read effects belong to the page, even before comments render.
												Load.watch(
													article,
													slug.map(
														|value| if value.is_empty() {
															""
														} else {
															Api.article_uri(value)
														},
													),
													Api.decode_article,
												),
												Load.watch(
													comments,
													slug.map(
														|value| if value.is_empty() {
															""
														} else {
															Api.comments_uri(value)
														},
													),
													Api.decode_comments,
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
												Action.on_change(
													Action.sampled(model_signal.map(|value| value.article_delete_serial), article_delete_request),
													|read| if read.serial == 0 or read.slug.is_empty() {
														Action.none
													} else {
														Action.then([model.write(|current| { ..current, article_delete_result: DeleteIdle })], |snapshot| delete_article!(model, snapshot))
													},
												),
												Action.on_change(
													Action.sampled(model_signal.map(|value| value.comment_serial), comment_request),
													|read| if read.serial == 0 or read.slug.is_empty() {
														Action.none
													} else {
														Action.then([model.write(|current| { ..current, comment_result: CommentIdle })], |snapshot| create_comment!(model, snapshot))
													},
												),
												Action.on_change(
													Action.sampled(model_signal.map(|value| value.comment_delete_serial), comment_delete_request),
													|read| if read.serial == 0 or read.slug.is_empty() or read.id == 0 {
														Action.none
													} else {
														Action.then([model.write(|current| { ..current, comment_delete_result: CommentDeleteIdle })], |snapshot| delete_comment!(model, snapshot))
													},
												),
												Action.on_change(
													Action.sampled(
														comment_result,
														{
															uri: comment_create_refetch.map(
																|request| match request.result {
																	CommentAccepted => if request.slug.is_empty() {
																		""
																	} else {
																		Api.comments_uri(request.slug)
																	}
																	_ => ""
																},
															),
															current: comments.signal(),
														}.Signal,
													),
													|read| Load.start(comments, Api.decode_comments, read),
												),
												Action.on_change(
													Action.sampled(
														comment_delete_result,
														{
															uri: comment_delete_refetch.map(
																|request| match request.result {
																	CommentDeleteAccepted => if request.slug.is_empty() {
																		""
																	} else {
																		Api.comments_uri(request.slug)
																	}
																	_ => ""
																},
															),
															current: comments.signal(),
														}.Signal,
													),
													|read| Load.start(comments, Api.decode_comments, read),
												),
												Action.on_change(
													Action.sampled(
														favorite_result,
														{
															uri: article_refetch.map(
																|request| match request.result {
																	FavoriteAccepted(_) => if request.slug.is_empty() {
																		""
																	} else {
																		Api.article_uri(request.slug)
																	}
																	_ => ""
																},
															),
															current: article.signal(),
														}.Signal,
													),
													|read| Load.start(article, Api.decode_article, read),
												),
												Ui.on_change(
													article_delete_done,
													|done| if done {
														Browser.push_state(Route.home_location)
													} else {
														Signal.noop
													},
												),
												Ui.when(
													is_loading,
													|| Html.paragraph_c("Loading article...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),

													|| Ui.when(
														is_failed,
														|| Html.paragraph_s_c(message, Styles.status_error),

														|| Html.div(
															[Html.attr("data-conduit", "article"), Html.class_attr("rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm sm:p-10")],
															[
																Elem.Element({ namespace: Html, tag: "h2", attrs: [Html.class_attr("text-4xl font-semibold leading-tight tracking-normal text-zinc-950 sm:text-5xl")], children: [Html.text_s(title)] }),
																Html.div_c(
																	"flex flex-wrap items-center gap-2 py-4 text-sm text-zinc-500",
																	[
																		Ui.each(Signal.map(author_rows, |rows_items| Rows.from_list(rows_items, |name| name) ?? crash "duplicate row key"), |each_row| Nav.link(each_row.key(), "font-medium text-emerald-600", Route.profile_location(each_row.key()), intent)),
																		Html.text_s(meta),
																	],
																),
																Ui.when(
																	can_favorite,
																	|| Html.action_button_attrs(
																		favorite_label,
																		favorite_label.map(|_| False),
																		[Html.class_attr("mb-4 mr-2 rounded-lg border border-emerald-500 bg-white px-4 py-2 text-sm font-medium text-emerald-700 shadow-sm transition hover:bg-emerald-50")],
																		favorite_action,
																	),
																	|| Html.text(""),
																),
																Html.paragraph_s_c(favorite_message, "text-red-700"),
																Ui.when(
																	can_delete,
																	|| Html.button_attrs(
																		"Delete Article",
																		[Html.class_attr("mb-4 ${Styles.danger_button}"), Html.attr("type", "button")],
																		model.update(|value| { ..value, article_delete_serial: value.article_delete_serial + 1 }),
																	),
																	|| Html.text(""),
																),
																Html.paragraph_s_c(article_delete_message, "text-red-700"),
																Markdown.view(body),
																comments_section(comments_state, session, signed_in, comment_body, comment_errors, comment_delete_message, model),
															],
														),
													),
												),
											],
										)
									},
								)
							},
						)
					},
				)
			},
		)
	}

	FavoriteRead : { article : Api.Remote(Api.Article), slug : Str, token : Str, generation : U64 }
	DeleteRead : { serial : U64, slug : Str, token : Str }
	CommentRead : { serial : U64, slug : Str, token : Str, body : Str }
	CommentDeleteRead : { serial : U64, slug : Str, token : Str, id : U64 }

	favorite! : Ui.State(Article.State), Article.FavoriteRead, U64 => Action(Article.FavoriteRead)
	favorite! = |state, read, generation| {
		request = if article_favorited(read.article) {
			Api.delete_request(Api.favorite_uri(read.slug), read.token)
		} else {
			Api.post_request(Api.favorite_uri(read.slug), "", read.token)
		}
		result = classify_favorite(Api.send_response!(request))
		Action.update([
			state.write(
				|current| if current.favorite_generation == generation {
					{ ..current, favorite_result: result }
				} else {
					current
				},
			),
		])
	}

	delete_article! : Ui.State(Article.State), Article.DeleteRead => Action(Article.DeleteRead)
	delete_article! = |state, read| {
		result = classify_article_delete(Api.send_response!(Api.delete_request(Api.article_uri(read.slug), read.token)))
		Action.update([
			state.write(
				|current| if current.article_delete_serial == read.serial {
					{ ..current, article_delete_result: result }
				} else {
					current
				},
			),
		])
	}

	create_comment! : Ui.State(Article.State), Article.CommentRead => Action(Article.CommentRead)
	create_comment! = |state, read| {
		result = classify_comment(Api.send_response!(Api.post_request(Api.comments_uri(read.slug), read.body, read.token)))
		Action.update([
			state.write(
				|current| if current.comment_serial == read.serial {
					{ ..current, comment_result: result }
				} else {
					current
				},
			),
		])
	}

	delete_comment! : Ui.State(Article.State), Article.CommentDeleteRead => Action(Article.CommentDeleteRead)
	delete_comment! = |state, read| {
		result = classify_comment_delete(Api.send_response!(Api.delete_request(Api.comment_uri(read.slug, read.id), read.token)))
		Action.update([
			state.write(
				|current| if current.comment_delete_serial == read.serial {
					{ ..current, comment_delete_result: result }
				} else {
					current
				},
			),
		])
	}

	comment_body_json : Str -> Str
	comment_body_json = |body| "{\"comment\":{\"body\":${Json.to_str(body)}}}"

	submit_comment : Article.State -> Article.State
	submit_comment = |state| {
		{ ..state, comment_serial: state.comment_serial + 1, submitted_comment_body: comment_body_json(state.comment_body.trim()) }
	}

	classify_article_delete : Api.ResponseState -> Article.DeleteResult
	classify_article_delete = |response| {
		if !response.ready {
			DeleteIdle
		} else if !response.error.is_empty() {
			DeleteRejected("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 204 {
			DeleteAccepted
		} else if response.status == 401 {
			DeleteRejected("Please sign in to delete articles.")
		} else if response.status == 403 {
			DeleteRejected("Only the author can delete this article.")
		} else if response.status == 404 {
			DeleteRejected("Article was not found.")
		} else {
			DeleteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_favorite : Api.ResponseState -> Article.FavoriteResult
	classify_favorite = |response| {
		if !response.ready {
			FavoriteIdle
		} else if !response.error.is_empty() {
			FavoriteRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_article(response.body) {
				Ready(article) => FavoriteAccepted(article)
				Failed(message) => FavoriteRejected(message)
				Loading => FavoriteRejected("The server returned an empty article response.")
			}
		} else if response.status == 401 {
			FavoriteRejected("Please sign in to favorite articles.")
		} else if response.status == 404 {
			FavoriteRejected("Article was not found.")
		} else {
			FavoriteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_comment : Api.ResponseState -> Article.CommentResult
	classify_comment = |response| {
		if !response.ready {
			CommentIdle
		} else if !response.error.is_empty() {
			CommentErrored("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 201 {
			CommentAccepted
		} else if response.status == 422 {
			CommentRejected(Api.parse_errors(response.body))
		} else if response.status == 401 {
			CommentErrored("Please sign in to comment.")
		} else if response.status == 404 {
			CommentErrored("Article was not found.")
		} else {
			CommentErrored("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_comment_delete : Api.ResponseState -> Article.CommentDeleteResult
	classify_comment_delete = |response| {
		if !response.ready {
			CommentDeleteIdle
		} else if !response.error.is_empty() {
			CommentDeleteRejected("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 204 {
			CommentDeleteAccepted
		} else if response.status == 401 {
			CommentDeleteRejected("Please sign in to delete comments.")
		} else if response.status == 403 {
			CommentDeleteRejected("Only the author can delete this comment.")
		} else if response.status == 404 {
			CommentDeleteRejected("Comment was not found.")
		} else {
			CommentDeleteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	comments_section : Signal.Signal(Api.Remote(List(Api.Comment))), Signal.Signal(Session), Signal.Signal(Bool), Signal.Signal(Str), Signal.Signal(List(Str)), Signal.Signal(Str), Ui.State(Article.State) -> Elem
	comments_section = |comments_state, session, signed_in, comment_body, comment_errors, comment_delete_message, model| {
		is_loading = comments_state.map(Api.is_loading)
		is_failed = comments_state.map(Api.is_failed)
		message = comments_state.map(Api.failure_message)
		comments = comments_state.map(comments_of)
		Html.div_c(
			"mt-10 border-t border-zinc-200 pt-8",
			[
				Elem.Element({ namespace: Html, tag: "h3", attrs: [Html.class_attr("mb-5 text-2xl font-semibold tracking-normal text-zinc-950")], children: [Html.text("Comments")] }),
				Ui.when(
					signed_in,
					|| comment_form(comment_body, comment_errors, model),
					|| Html.paragraph("Sign in to add a comment."),
				),
				Html.paragraph_s_c(comment_delete_message, "text-red-700"),
				Ui.when(
					is_loading,
					|| Html.paragraph("Loading comments..."),

					|| Ui.when(
						is_failed,
						|| Html.paragraph_s_c(message, "text-red-700"),

						|| Ui.each(Signal.map(comments, |rows_items| Rows.from_list(rows_items, |comment| comment.id.to_str()) ?? crash "duplicate row key"), |each_row| comment_row(each_row.key(), each_row.signal(), session, model)),
					),
				),
			],
		)
	}

	comment_form : Signal.Signal(Str), Signal.Signal(List(Str)), Ui.State(Article.State) -> Elem
	comment_form = |body, errors, model|
		Html.form(
			[Html.class_attr("mb-8 grid gap-3 rounded-xl border border-zinc-200 bg-zinc-50 p-4"), Html.on_submit_prevent_default(model.update(submit_comment))],
			[
				Auth.error_list(errors),
				Html.textarea_attrs(
					"Comment",
					body,
					[Html.class_attr(Auth.field_class)],
					model.update_str(|value, text| { ..value, comment_body: text }),
				),
				Html.button_attrs(
					"Post Comment",
					[Html.class_attr(Styles.primary_button), Html.attr("type", "submit")],
					model.update(submit_comment),
				),
			],
		)

	comment_row : Str, Signal.Signal(Api.Comment), Signal.Signal(Session), Ui.State(Article.State) -> Elem
	comment_row = |key, comment, session, model| {
		body = comment.map(|value| value.body)
		meta = comment.map(|value| "${value.author.username} on ${Format.display_date(value.created_at)}")
		can_delete_inputs = { comment: comment, session: session }.Signal
		can_delete = can_delete_inputs.map(|value| value.comment.author.username == Session.username_of(value.session))
		Html.div_c(
			"my-4 overflow-hidden rounded-xl border border-zinc-200 bg-white p-4",
			[
				Html.paragraph_s(body),
				Html.paragraph_s_c(meta, "text-sm text-zinc-500"),
				Ui.when(
					can_delete,
					|| Html.button_attrs(
						"Delete Comment",
						[Html.class_attr("mt-3 ${Styles.danger_button}"), Html.attr("type", "button")],
						model.update(|value| { ..value, comment_delete_serial: value.comment_delete_serial + 1, comment_delete_id: comment_id_from_key(key) }),
					),
					|| Html.text(""),
				),
			],
		)
	}

	comment_id_from_key : Str -> U64
	comment_id_from_key = |key| U64.from_str(key) ?? 0

	can_delete_article : Api.Remote(Api.Article), Session -> Bool
	can_delete_article = |remote, session|
		match remote {
			Ready(article) => article.author.username == Session.username_of(session)
			_ => False
		}

	article_favorited : Api.Remote(Api.Article) -> Bool
	article_favorited = |remote|
		match remote {
			Ready(article) => article.favorited
			_ => False
		}

	favorite_button_label : Api.Remote(Api.Article) -> Str
	favorite_button_label = |remote|
		match remote {
			Ready(article) =>
				if article.favorited {
					"Unfavorite Article (${article.favorites_count.to_str()})"
				} else {
					"Favorite Article (${article.favorites_count.to_str()})"
				}
			_ => "Favorite Article"
		}

	favorite_message_of : Article.FavoriteResult -> Str
	favorite_message_of = |result|
		match result {
			FavoriteRejected(message) => message
			_ => ""
		}

	article_delete_message_of : Article.DeleteResult -> Str
	article_delete_message_of = |result|
		match result {
			DeleteRejected(message) => message
			_ => ""
		}

	article_delete_done_of : Article.DeleteResult -> Bool
	article_delete_done_of = |result|
		match result {
			DeleteAccepted => True
			_ => False
		}

	comment_error_lines : Article.CommentResult -> List(Str)
	comment_error_lines = |result|
		match result {
			CommentRejected(lines) => lines
			CommentErrored(message) => [message]
			_ => []
		}

	comment_delete_message_of : Article.CommentDeleteResult -> Str
	comment_delete_message_of = |result|
		match result {
			CommentDeleteRejected(message) => message
			_ => ""
		}

	comments_of : Api.Remote(List(Api.Comment)) -> List(Api.Comment)
	comments_of = |remote|
		match remote {
			Ready(comments) => comments
			_ => []
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
