## Settings page: update the current user over PUT /api/user (auth header
## required) and sign out. Sign-out clears the namespaced session keys and
## navigates home. The form starts from the session's username rather than
## prefilling from GET /api/user — controlled inputs cannot seed state from
## an async response (recorded in the findings ledger).
import Api
import Auth
import Nav
import Route
import Session
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Settings := {}.{
	Form : {
		image : Str,
		bio : Str,
		email : Str,
		password : Str,
		serial : U64,
		submitted_body : Str,
		logout_serial : U64,
	}

	empty_form : Settings.Form
	empty_form = {
		image: "",
		bio: "",
		email: "",
		password: "",
		serial: 0,
		submitted_body: "",
		logout_serial: 0,
	}

	update_body : Settings.Form -> Str
	update_body = |form|
		Json.to_str(
			{
				user: {
					image: form.image,
					bio: form.bio,
					email: form.email,
					password: form.password,
				},
			},
		)

	submit_form : Settings.Form -> Settings.Form
	submit_form = |form| {
		{ ..form, serial: form.serial + 1, submitted_body: update_body(form) }
	}

	page : Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	page = |session, _intent| {
		Ui.component(
			|| {
				Ui.state(
					empty_form,
					|form| {
						task = Http.request_task("settings")
						form_signal : Signal.Signal(Settings.Form)
						form_signal = form.signal()
						token = session.map(|value| Session.token_of(value))

						result : Signal.Signal(Api.AuthResult)
						result = Signal.fold_task(
							task,
							AuthIdle,
							Api.classify_auth,
							|err| AuthErrored("Request failed: ${Http.error_text(err)}"),
						)
						submission_inputs = { form: form_signal, token: token }.Signal

						submission : Signal.Signal({ serial : U64, body : Str, token : Str })
						submission = submission_inputs.map(|value| { serial: value.form.serial, body: value.form.submitted_body, token: value.token })

						logout : Signal.Signal(U64)
						logout = form_signal.map(|value| value.logout_serial)

						saved : Signal.Signal(Str)
						saved = result.map(saved_text)

						errors : Signal.Signal(List(Str))
						errors = result.map(Auth.error_lines)

						username = session.map(|value| Session.username_of(value))
						signed_in_text = username.map(|name| "Signed in as ${name}")

						image : Signal.Signal(Str)
						image = form_signal.map(|value| value.image)

						bio : Signal.Signal(Str)
						bio = form_signal.map(|value| value.bio)

						email : Signal.Signal(Str)
						email = form_signal.map(|value| value.email)

						password : Signal.Signal(Str)
						password = form_signal.map(|value| value.password)

						Html.section(
							"Settings",
							[Html.class_attr("mx-auto max-w-md px-4 py-6")],
							[
								Ui.on_change(
									submission,
									|snapshot|
										if snapshot.serial == 0 {
											Signal.noop
										} else {
											Http.start(task, Api.put_request("/api/user", snapshot.body, snapshot.token))
										},
								),
								Ui.on_change(
									logout,
									|serial| if serial == 0 {
										Signal.noop
									} else {
										Session.clear_token
									},
								),
								Ui.on_change(
									logout,
									|serial| if serial == 0 {
										Signal.noop
									} else {
										Session.clear_username
									},
								),
								Html.heading("Settings"),
								Html.text_s(signed_in_text),
								Auth.error_list(errors),
								Html.paragraph_s(saved),
								Html.form(
									[Html.on_submit_prevent_default(form.on_unit(submit_form))],
									[
										Html.text_input_attrs(
											"Profile picture URL",
											image,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, image: text }),
										),
										Html.textarea_attrs(
											"Bio",
											bio,
											[Html.class_attr(Auth.field_class)],
											form.on_str(|value, text| { ..value, bio: text }),
										),
										Html.text_input_attrs(
											"Email",
											email,
											[Html.class_attr(Auth.field_class), Html.attr("type", "email")],
											form.on_str(|value, text| { ..value, email: text }),
										),
										Html.text_input_attrs(
											"New password",
											password,
											[Html.class_attr(Auth.field_class), Html.attr("type", "password")],
											form.on_str(|value, text| { ..value, password: text }),
										),
										Html.button_attrs(
											"Update Settings",
											[Html.class_attr("rounded bg-emerald-600 px-4 py-2 text-white"), Html.attr("type", "submit")],
											form.on_unit(submit_form),
										),
									],
								),
								Html.button_attrs(
									"Sign out",
									[Html.class_attr("mt-4 rounded border border-red-600 px-4 py-2 text-red-600"), Html.attr("type", "button")],
									form.on_unit(|value| { ..value, logout_serial: value.logout_serial + 1 }),
								),
							],
						)
					},
				)
			},
		)
	}

	saved_text : Api.AuthResult -> Str
	saved_text = |result|
		match result {
			AuthAccepted(_) => "Settings saved."
			_ => ""
		}

}
