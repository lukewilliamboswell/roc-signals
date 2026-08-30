## Article editor create/edit paths. Writes snapshot the controlled fields on
## submit, send RealWorld article envelopes, render 422 validation envelopes,
## and navigate to the accepted article only after the server confirms it.
import Api
import Auth
import Route
import Session
import Styles
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Editor := {}.{
	ArticleResult : [ArticleIdle, ArticleAccepted(Api.Article), ArticleRejected(List(Str)), ArticleErrored(Str)]

	Form : {
		title : Str,
		description : Str,
		body : Str,
		tag_input : Str,
		serial : U64,
		submitted_body : Str,
	}

	empty_form : Editor.Form
	empty_form = {
		title: "",
		description: "",
		body: "",
		tag_input: "",
		serial: 0,
		submitted_body: "",
	}

	parse_tags : Str -> List(Str)
	parse_tags = |raw| raw.split_on(",").map(|part| part.trim()).keep_if(|tag| !tag.is_empty())

	article_body : Str, Str, Str, List(Str) -> Str
	article_body = |title, description, body, tags| {
		encoded_tags = Str.join_with(tags.map(|tag| Json.to_str(tag)), ",")
		"{\"article\":{\"title\":${Json.to_str(title)},\"description\":${Json.to_str(description)},\"body\":${Json.to_str(body)},\"tagList\":[${encoded_tags}]}}"
	}

	submit_form : Editor.Form -> Editor.Form
	submit_form = |form| {
		body = article_body(form.title.trim(), form.description.trim(), form.body, parse_tags(form.tag_input))
		{ ..form, serial: form.serial + 1, submitted_body: body }
	}

	create_page : Signal.Signal(Session) -> Elem
	create_page = |session| {
		Ui.component(
			|| {
				Ui.state(
					empty_form,
					|form| {
						task = Http.request_task("editor")
						result : Signal.Signal(Editor.ArticleResult)
						result = Api.response_state(task).map(classify_article)

						form_signal : Signal.Signal(Editor.Form)
						form_signal = form.signal()

						token = session.map(|value| Session.token_of(value))
						submission_inputs = { form: form_signal, token: token }.Signal

						submission : Signal.Signal({ serial : U64, body : Str, token : Str })
						submission = submission_inputs.map(|value| { serial: value.form.serial, body: value.form.submitted_body, token: value.token })

						errors : Signal.Signal(List(Str))
						errors = result.map(error_lines)

						accepted_slug : Signal.Signal(Str)
						accepted_slug = result.map(accepted_slug_of)

						title : Signal.Signal(Str)
						title = form_signal.map(|value| value.title)

						description : Signal.Signal(Str)
						description = form_signal.map(|value| value.description)

						body : Signal.Signal(Str)
						body = form_signal.map(|value| value.body)

						tag_input : Signal.Signal(Str)
						tag_input = form_signal.map(|value| value.tag_input)

						Html.section(
							"New article",
							[Html.class_attr(Styles.wide_page)],
							[
								Ui.on_change(
									submission,
									|snapshot|
										if snapshot.serial == 0 {
											Signal.noop
										} else {
											Http.start(task, Api.post_request("/api/articles", snapshot.body, snapshot.token))
										},
								),
								Ui.on_change(
									accepted_slug,
									|slug| if slug.is_empty() {
										Signal.noop
									} else {
										Browser.push_state(Route.article_location(slug))
									},
								),
								Html.heading_c("New article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
								Auth.error_list(errors),
								Html.form(
									[Html.class_attr(Styles.form), Html.on_submit_prevent_default(form.on_unit(submit_form))],
									[
										Html.text_input_attrs(
											"Title",
											title,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, title: text }),
										),
										Html.text_input_attrs(
											"Description",
											description,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, description: text }),
										),
										Html.textarea_attrs(
											"Body",
											body,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, body: text }),
										),
										Html.text_input_attrs(
											"Tags",
											tag_input,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, tag_input: text }),
										),
										Html.button_attrs(
											"Publish Article",
											[Html.class_attr(Styles.primary_button), Html.attr("type", "submit")],
											form.on_unit(submit_form),
										),
									],
								),
							],
						)
					},
				)
			},
		)
	}

	edit_page : Signal.Signal(Route), Signal.Signal(Session) -> Elem
	edit_page = |route, session| {
		Ui.component(
			|| {
				Ui.state(
					empty_form,
					|form| {
						article_task = Http.get_text_task("editor-load")
						task = Http.request_task("editor")

						article_state : Signal.Signal(Api.Remote(Api.Article))
						article_state = Signal.fold_task(article_task, Loading, Api.decode_article, Api.request_failed)

						result : Signal.Signal(Editor.ArticleResult)
						result = Api.response_state(task).map(classify_article)

						slug = route.map(|value| Route.article_slug(value))
						form_signal : Signal.Signal(Editor.Form)
						form_signal = form.signal()
						token = session.map(|value| Session.token_of(value))
						submission_inputs = { form: form_signal, slug: slug, token: token }.Signal

						submission : Signal.Signal({ serial : U64, body : Str, slug : Str, token : Str })
						submission = submission_inputs.map(
							|value| { serial: value.form.serial, body: value.form.submitted_body, slug: value.slug, token: value.token },
						)

						errors : Signal.Signal(List(Str))
						errors = result.map(error_lines)

						accepted_slug : Signal.Signal(Str)
						accepted_slug = result.map(accepted_slug_of)

						title : Signal.Signal(Str)
						title = form_signal.map(|value| value.title)

						description : Signal.Signal(Str)
						description = form_signal.map(|value| value.description)

						body : Signal.Signal(Str)
						body = form_signal.map(|value| value.body)

						tag_input : Signal.Signal(Str)
						tag_input = form_signal.map(|value| value.tag_input)

						is_loading : Signal.Signal(Bool)
						is_loading = article_state.map(Api.is_loading)

						is_failed : Signal.Signal(Bool)
						is_failed = article_state.map(Api.is_failed)

						load_message : Signal.Signal(Str)
						load_message = article_state.map(Api.failure_message)

						current_title : Signal.Signal(Str)
						current_title = article_state.map(current_title_text)

						current_description : Signal.Signal(Str)
						current_description = article_state.map(current_description_text)

						current_body : Signal.Signal(Str)
						current_body = article_state.map(current_body_text)

						current_tags : Signal.Signal(Str)
						current_tags = article_state.map(current_tags_text)

						Html.section(
							"Edit article",
							[Html.class_attr(Styles.wide_page)],
							[
								Ui.on_change_initial(
									slug,
									|value|
										if value.is_empty() {
											Signal.noop
										} else {
											Http.get_text(article_task, Api.article_uri(value))
										},
								),
								Ui.on_change(
									submission,
									|snapshot|
										if snapshot.serial == 0 or snapshot.slug.is_empty() {
											Signal.noop
										} else {
											Http.start(task, Api.put_request(Api.article_uri(snapshot.slug), snapshot.body, snapshot.token))
										},
								),
								Ui.on_change(
									accepted_slug,
									|value| if value.is_empty() {
										Signal.noop
									} else {
										Browser.push_state(Route.article_location(value))
									},
								),
								Html.heading_c("Edit article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
								Ui.when(
									is_loading,
									|| Html.paragraph("Loading article..."),

									|| Ui.when(
										is_failed,
										|| Html.paragraph_s_c(load_message, "text-red-700"),

										|| Html.div_c(
											"mb-4 space-y-1 rounded border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-700",
											[
												Html.paragraph_s(current_title),
												Html.paragraph_s(current_description),
												Html.paragraph_s(current_body),
												Html.paragraph_s(current_tags),
											],
										),
									),
								),
								Auth.error_list(errors),
								Html.form(
									[Html.class_attr(Styles.form), Html.on_submit_prevent_default(form.on_unit(submit_form))],
									[
										Html.text_input_attrs(
											"Title",
											title,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, title: text }),
										),
										Html.text_input_attrs(
											"Description",
											description,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, description: text }),
										),
										Html.textarea_attrs(
											"Body",
											body,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, body: text }),
										),
										Html.text_input_attrs(
											"Tags",
											tag_input,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, tag_input: text }),
										),
										Html.button_attrs(
											"Update Article",
											[Html.class_attr(Styles.primary_button), Html.attr("type", "submit")],
											form.on_unit(submit_form),
										),
									],
								),
							],
						)
					},
				)
			},
		)
	}

	classify_article : Api.ResponseState -> Editor.ArticleResult
	classify_article = |response| {
		if !response.ready {
			ArticleIdle
		} else if !response.error.is_empty() {
			ArticleErrored("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 201 {
			match Api.decode_article(response.body) {
				Ready(article) => ArticleAccepted(article)
				Failed(message) => ArticleErrored(message)
				Loading => ArticleErrored("The server response could not be read.")
			}
		} else if response.status == 422 {
			ArticleRejected(Api.parse_errors(response.body))
		} else if response.status == 401 {
			ArticleErrored("Please sign in to edit articles.")
		} else {
			ArticleErrored("The server responded with status ${response.status.to_str()}.")
		}
	}

	error_lines : Editor.ArticleResult -> List(Str)
	error_lines = |result|
		match result {
			ArticleRejected(lines) => lines
			ArticleErrored(message) => [message]
			_ => []
		}

	accepted_slug_of : Editor.ArticleResult -> Str
	accepted_slug_of = |result|
		match result {
			ArticleAccepted(article) => article.slug
			_ => ""
		}




	current_title_text : Api.Remote(Api.Article) -> Str
	current_title_text = |remote|
		match remote {
			Ready(article) => "Current title: ${article.title}"
			_ => ""
		}

	current_description_text : Api.Remote(Api.Article) -> Str
	current_description_text = |remote|
		match remote {
			Ready(article) => "Current description: ${article.description}"
			_ => ""
		}

	current_body_text : Api.Remote(Api.Article) -> Str
	current_body_text = |remote|
		match remote {
			Ready(article) => "Current body: ${article.body}"
			_ => ""
		}

	current_tags_text : Api.Remote(Api.Article) -> Str
	current_tags_text = |remote|
		match remote {
			Ready(article) => "Current tags: ${Str.join_with(article.tag_list, ", ")}"
			_ => ""
		}
}

## Tag input is trimmed per entry and empty entries between commas are dropped.
expect Editor.parse_tags(" roc , signals ,, ") == ["roc", "signals"]

## An empty tag box yields no tags rather than one empty tag.
expect Editor.parse_tags("") == []
