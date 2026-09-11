## Settings page: update the current user over PUT /api/user (auth header
## required) and sign out. Each submission runs an HTTP effect; only the latest
## submission may publish its result. Sign-out clears the namespaced session
## keys, and the route guard redirects to sign-in. The form displays the session
## username and leaves editable fields blank; it does not fetch a user profile.
import Api
import Auth
import Nav
import Session
import Styles
import pf.Elem exposing [Elem]
import pf.Html
import pf.Action
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
		Json.to_str({
			user: {
				image: form.image,
				bio: form.bio,
				email: form.email,
				password: form.password,
			},
		})

	submit_form : Settings.Form -> Settings.Form
	submit_form = |form| {
		{ ..form, serial: form.serial + 1, submitted_body: update_body(form) }
	}

	page : Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	page = |session, _intent| {
		Ui.state(
			{ serial: 0.U64, result: AuthIdle },
			|response| {
				Ui.component(
					|| {
						Ui.state(
							empty_form,
							|form| {
								form_signal : Signal.Signal(Settings.Form)
								form_signal = form.signal()
								token = session.map(|value| Session.token_of(value))

								result : Signal.Signal(Api.AuthResult)
								result = response.signal().map(|value| value.result)
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
									[Html.class_attr(Styles.narrow_page)],
									[
										Action.on_change(
											Action.sampled(form_signal.map(|value| value.serial), submission),
											|snapshot| if snapshot.serial == 0 {
												Action.none
											} else {
												Action.then(
													[response.set({ serial: snapshot.serial, result: AuthIdle })],
													|read| save!(response, read),
												)
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
										Html.heading_c("Settings", "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
										Html.paragraph_s_c(signed_in_text, "mb-7 mt-2 text-center text-sm text-zinc-500"),
										Auth.error_list(errors),
										Html.paragraph_s_c(saved, "font-medium text-emerald-700"),
										Html.form(
											[Html.class_attr(Styles.form), Html.on_submit_prevent_default(form.update(submit_form))],
											[
												Html.text_input_attrs(
													"Profile picture URL",
													image,
													[Html.class_attr(Auth.field_class)],
													form.update_str(|value, text| { ..value, image: text }),
												),
												Html.textarea_attrs(
													"Bio",
													bio,
													[Html.class_attr(Auth.field_class)],
													form.update_str(|value, text| { ..value, bio: text }),
												),
												Html.text_input_attrs(
													"Email",
													email,
													[Html.class_attr(Auth.field_class), Html.attr("type", "email")],
													form.update_str(|value, text| { ..value, email: text }),
												),
												Html.text_input_attrs(
													"New password",
													password,
													[Html.class_attr(Auth.field_class), Html.attr("type", "password")],
													form.update_str(|value, text| { ..value, password: text }),
												),
												Html.button_attrs(
													"Update Settings",
													[Html.class_attr(Styles.primary_button), Html.attr("type", "submit")],
													form.update(submit_form),
												),
											],
										),
										Html.button_attrs(
											"Sign out",
											[Html.class_attr("mt-8 ${Styles.danger_button}"), Html.attr("type", "button")],
											form.update(|value| { ..value, logout_serial: value.logout_serial + 1 }),
										),
									],
								)
							},
						)
					},
				)
			},
		)
	}

	Submission : { serial : U64, body : Str, token : Str }
	ResponseState : { serial : U64, result : Api.AuthResult }

	save! : Ui.State(Settings.ResponseState), Settings.Submission => Action(Settings.Submission)
	save! = |response, read| {
		result = Api.classify_auth(Api.send_response!(Api.put_request("/api/user", read.body, read.token)))
		Action.update([
			response.write(
				|current| if current.serial == read.serial {
					{ ..current, result }
				} else {
					current
				},
			),
		])
	}

	saved_text : Api.AuthResult -> Str
	saved_text = |result|
		match result {
			AuthAccepted(_) => "Settings saved."
			_ => ""
		}

}
