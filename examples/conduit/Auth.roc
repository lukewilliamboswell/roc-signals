## Sign-in and sign-up pages. Submissions snapshot the form into state so
## the request command fires once per submit (not per keystroke); a
## successful response persists the session keys and navigates home, and a
## 422 envelope renders as an error list above the form.
import Api
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

Auth := {}.{
	Form : {
		username : Str,
		email : Str,
		password : Str,
		serial : U64,
		submitted_username : Str,
		submitted_email : Str,
		submitted_password : Str,
	}

	empty_form : Auth.Form
	empty_form = {
		username: "",
		email: "",
		password: "",
		serial: 0,
		submitted_username: "",
		submitted_email: "",
		submitted_password: "",
	}

	submit_form : Auth.Form -> Auth.Form
	submit_form = |form| {
		{
			..form,
			serial: form.serial + 1,
			submitted_username: form.username,
			submitted_email: form.email,
			submitted_password: form.password,
		}
	}

	Submission : { serial : U64, username : Str, email : Str, password : Str }

	submission_of : Auth.Form -> Auth.Submission
	submission_of = |form| {
		{
			serial: form.serial,
			username: form.submitted_username,
			email: form.submitted_email,
			password: form.submitted_password,
		}
	}

	page : Bool, Ui.State(Nav.RouteIntent) -> Elem
	page = |is_register, intent| {
		Ui.component(
			|| {
				Ui.state(
					empty_form,
					|form| {
						task = Http.request_task(
							if is_register {
								"register"
							} else {
								"login"
							},
						)
						result : Signal.Signal(Api.AuthResult)
						result = Api.response_state(task).map(Api.classify_auth)

						form_signal : Signal.Signal(Auth.Form)
						form_signal = form.signal()

						submission : Signal(Auth.Submission)
						submission = form_signal.map(submission_of)

						errors : Signal.Signal(List(Str))
						errors = result.map(error_lines)

						accepted_token : Signal.Signal(Str)
						accepted_token = result.map(accepted_token_of)

						accepted_username : Signal.Signal(Str)
						accepted_username = result.map(accepted_username_of)

						username : Signal.Signal(Str)
						username = form_signal.map(|value| value.username)

						email : Signal.Signal(Str)
						email = form_signal.map(|value| value.email)

						password : Signal.Signal(Str)
						password = form_signal.map(|value| value.password)

						heading = if is_register {
							"Sign up"
						} else {
							"Sign in"
						}

						Html.section(
							heading,
							[Html.class_attr(Styles.narrow_page)],
							[
								Ui.on_change(
									submission,
									|snapshot|
										if snapshot.serial == 0 {
											Signal.noop
										} else if is_register {
											Http.start(task, Api.post_request("/api/users", Api.register_body(snapshot.username, snapshot.email, snapshot.password), ""))
										} else {
											Http.start(task, Api.post_request("/api/users/login", Api.login_body(snapshot.email, snapshot.password), ""))
										},
								),
								Ui.on_change(
									accepted_token,
									|token| if token.is_empty() {
										Signal.noop
									} else {
										Session.persist_token(token)
									},
								),
								Ui.on_change(
									accepted_username,
									|name| if name.is_empty() {
										Signal.noop
									} else {
										Session.persist_username(name)
									},
								),
								Ui.on_change(
									accepted_username,
									|name| if name.is_empty() {
										Signal.noop
									} else {
										Browser.push_state(Route.home_location)
									},
								),
								Html.heading_c(heading, "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
								Html.div_c(
									"mb-7 mt-2 text-center",
									[
										Nav.link(
											if is_register {
												"Have an account?"
											} else {
												"Need an account?"
											},
											"font-medium text-emerald-700",
											if is_register {
												Route.login_location
											} else {
												Route.register_location
											},
											intent,
										),
									],
								),
								error_list(errors),
								Html.form(
									[Html.class_attr(Styles.form), Html.on_submit_prevent_default(form.on_unit(submit_form))],
									[
										if is_register {
											Html.text_input_attrs(
												"Username",
												username,
												[Html.class_attr(field_class)],
												form.on_str(|value, text| { ..value, username: text }),
											)
										} else {
											Html.text("")
										},
										Html.text_input_attrs(
											"Email",
											email,
											[Html.class_attr(field_class), Html.attr("type", "email")],
											form.on_str(|value, text| { ..value, email: text }),
										),
										Html.text_input_attrs(
											"Password",
											password,
											[Html.class_attr(field_class), Html.attr("type", "password")],
											form.on_str(|value, text| { ..value, password: text }),
										),
										Html.button_attrs(
											heading,
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

	field_class : Str
	field_class = Styles.field

	error_list : Signal.Signal(List(Str)) -> Elem
	error_list = |errors| {
		has_errors : Signal.Signal(Bool)
		has_errors = errors.map(|lines| !lines.is_empty())

		keyed : Signal.Signal(List({ key : Str, text : Str }))
		keyed = errors.map(
			|lines|
				lines.fold(
					{ items: [], index: 0 },
					|acc, line| {
						items: acc.items.append({ key: "e:${acc.index.to_str()}", text: line }),
						index: acc.index + 1,
					},
				).items,
		)
		Ui.when(
			has_errors,
			|| Elem.Element(
				{
					tag: "ul",
					attrs: [Html.class_attr(Styles.error_list)],
					children: [
						Ui.each_str(
							keyed,
							|item| item.key,
							|_, item| Elem.Element({ tag: "li", attrs: [], children: [Html.text_s(item.map(|value| value.text))] }),
						),
					],
				},
			),
			|| Html.text(""),
		)
	}

	error_lines : Api.AuthResult -> List(Str)
	error_lines = |result|
		match result {
			AuthRejected(lines) => lines
			AuthErrored(message) => [message]
			_ => []
		}

	accepted_token_of : Api.AuthResult -> Str
	accepted_token_of = |result|
		match result {
			AuthAccepted(user) => user.token
			_ => ""
		}

	accepted_username_of : Api.AuthResult -> Str
	accepted_username_of = |result|
		match result {
			AuthAccepted(user) => user.username
			_ => ""
		}
}
