## Profile page: fetches the public profile plus the author's articles (or
## favorited articles on the favorites tab). Follow/unfollow is
## server-confirmed and refetches the profile before the button changes.
import Api
import Feed
import Nav
import Route
import Session
import Styles
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Profile := {}.{
	State : { follow_serial : U64 }

	FollowResult : [FollowIdle, FollowAccepted(Api.Profile), FollowRejected(Str)]

	initial_state : Profile.State
	initial_state = { follow_serial: 0 }

	page : Signal.Signal(Route), Signal.Signal(Session), Bool, Ui.State(Nav.RouteIntent) -> Elem
	page = |route, session, favorites, intent| {
		Ui.component(
			|| {
				Ui.state(
					initial_state,
					|model| {
						profile_task = Http.get_text_task("profile")
						articles_task = Http.get_text_task("profile-articles")
						follow_task = Http.request_task("profile-follow")

						profile_state : Signal.Signal(Api.Remote(Api.Profile))
						profile_state = Signal.fold_task(profile_task, Loading, Api.decode_profile, Api.request_failed)

						articles_state : Signal.Signal(Api.Remote(Api.FeedPage))
						articles_state = Signal.fold_task(articles_task, Loading, Api.decode_feed, Api.request_failed)

						follow_result : Signal.Signal(Profile.FollowResult)
						follow_result = Api.response_state(follow_task).map(classify_follow)

						username : Signal.Signal(Str)
						username = route.map(|value| Route.profile_username(value))

						token = session.map(|value| Session.token_of(value))
						model_signal = model.signal()

						follow_inputs = { model: model_signal, profile: profile_state, token: token }.Signal
						follow_request = follow_inputs.map(
							|value| {
								serial: value.model.follow_serial,
								username: profile_username(value.profile),
								following: profile_following(value.profile),
								token: value.token,
							},
						)

						follow_refetch = { result: follow_result, username: username }.Signal

						articles_uri : Signal.Signal(Str)
						articles_uri = username.map(
							|value|
								if favorites {
									Api.favorited_articles_uri(value)
								} else {
									Api.author_articles_uri(value)
								},
						)

						is_loading : Signal.Signal(Bool)
						is_loading = profile_state.map(Api.is_loading)

						is_failed : Signal.Signal(Bool)
						is_failed = profile_state.map(Api.is_failed)

						message : Signal.Signal(Str)
						message = profile_state.map(Api.failure_message)

						name_text : Signal.Signal(Str)
						name_text = profile_state.map(profile_name)

						bio_text : Signal.Signal(Str)
						bio_text = profile_state.map(profile_bio)

						can_follow_inputs = { profile: profile_state, session: session }.Signal
						can_follow = can_follow_inputs.map(|value| can_follow_profile(value.profile, value.session))
						follow_label = profile_state.map(follow_button_label)
						follow_error = follow_result.map(follow_message_of)

						tab_rows : Signal.Signal(List(Str))
						tab_rows = username.map(
							|value| if value.is_empty() {
								[]
							} else {
								[value]
							},
						)

						Html.section(
							"Profile",
							[Html.class_attr(Styles.page)],
							[
								Ui.on_change_initial(
									username,
									|value|
										if value.is_empty() {
											Signal.noop
										} else {
											Http.get_text(profile_task, Api.profile_uri(value))
										},
								),
								Ui.on_change_initial(articles_uri, |uri| Http.get_text(articles_task, uri)),
								Ui.on_change(
									follow_request,
									|request|
										if request.serial == 0 or request.username.is_empty() {
											Signal.noop
										} else if request.following {
											Http.start(follow_task, Api.delete_request(Api.follow_uri(request.username), request.token))
										} else {
											Http.start(follow_task, Api.post_request(Api.follow_uri(request.username), "", request.token))
										},
								),
								Ui.on_change(
									follow_refetch,
									|request|
									match request.result {
										FollowAccepted(_) => if request.username.is_empty() {
											Signal.noop
										} else {
											Http.get_text(profile_task, Api.profile_uri(request.username))
										}
										_ => Signal.noop
									},
								),
								Ui.when(
									is_loading,
									|| Html.paragraph_c("Loading profile...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
									|| Ui.when(
										is_failed,
										|| Html.paragraph_s_c(message, Styles.status_error),
										|| Html.div(
											[Html.attr("data-conduit", "profile"), Html.class_attr("mb-8 rounded-2xl border border-zinc-200 bg-white p-6 text-center shadow-sm sm:p-8")],
											[
												Elem.Element({ tag: "h2", attrs: [Html.class_attr("text-3xl font-semibold tracking-normal text-zinc-950")], children: [Html.text_s(name_text)] }),
												Html.paragraph_s_c(bio_text, "mx-auto mt-2 max-w-2xl leading-7 text-zinc-600"),
												Ui.when(
													can_follow,
													|| Html.action_button_attrs(
														follow_label,
														follow_label.map(|_| False),
														[Html.class_attr("mt-4 rounded-lg border border-emerald-500 bg-white px-4 py-2 text-sm font-medium text-emerald-700 shadow-sm transition hover:bg-emerald-50")],
														model.on_unit(|value| { follow_serial: value.follow_serial + 1 }),
													),
													|| Html.text(""),
												),
												Html.paragraph_s_c(follow_error, "text-red-700"),
											],
										),
									),
								),
								Elem.Element(
									{
										tag: "nav",
								attrs: [Html.attr("aria-label", "Profile tabs"), Html.class_attr("flex border-b border-zinc-200")],
										children: [
											Ui.each(tab_rows, |name| name, |each_row| tab_links(each_row.key(), favorites, intent)),
										],
									},
								),
								Feed.view(articles_state, session, intent),
							],
						)
					},
				)
			},
		)
	}

	classify_follow : Api.ResponseState -> Profile.FollowResult
	classify_follow = |response| {
		if !response.ready {
			FollowIdle
		} else if !response.error.is_empty() {
			FollowRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_profile(response.body) {
				Ready(profile) => FollowAccepted(profile)
				Failed(message) => FollowRejected(message)
				Loading => FollowRejected("The server returned an empty profile response.")
			}
		} else if response.status == 401 {
			FollowRejected("Please sign in to follow profiles.")
		} else if response.status == 404 {
			FollowRejected("Profile was not found.")
		} else {
			FollowRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	tab_links : Str, Bool, Ui.State(Nav.RouteIntent) -> Elem
	tab_links = |username, favorites, intent| {
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline hover:no-underline"
		idle = "px-4 py-3 text-zinc-500 no-underline hover:no-underline"
		Html.div_c(
			"flex",
			[
				Nav.link(
					"My Articles",
					if favorites {
						idle
					} else {
						active
					},
					Route.profile_location(username),
					intent,
				),
				Nav.link(
					"Favorited Articles",
					if favorites {
						active
					} else {
						idle
					},
					Route.profile_favorites_location(username),
					intent,
				),
			],
		)
	}

	can_follow_profile : Api.Remote(Api.Profile), Session -> Bool
	can_follow_profile = |remote, session|
		match remote {
			Ready(profile) => Session.is_signed_in(session) and profile.username != Session.username_of(session)
			_ => False
		}

	profile_username : Api.Remote(Api.Profile) -> Str
	profile_username = |remote|
		match remote {
			Ready(profile) => profile.username
			_ => ""
		}

	profile_following : Api.Remote(Api.Profile) -> Bool
	profile_following = |remote|
		match remote {
			Ready(profile) => profile.following
			_ => False
		}

	follow_button_label : Api.Remote(Api.Profile) -> Str
	follow_button_label = |remote|
		match remote {
			Ready(profile) =>
				if profile.following {
					"Unfollow ${profile.username}"
				} else {
					"Follow ${profile.username}"
				}
			_ => "Follow"
		}

	follow_message_of : Profile.FollowResult -> Str
	follow_message_of = |result|
		match result {
			FollowRejected(message) => message
			_ => ""
		}




	profile_name : Api.Remote(Api.Profile) -> Str
	profile_name = |remote|
		match remote {
			Ready(profile) => "@${profile.username}"
			_ => ""
		}

	profile_bio : Api.Remote(Api.Profile) -> Str
	profile_bio = |remote|
		match remote {
			Ready(profile) => profile.bio
			_ => ""
		}
}
