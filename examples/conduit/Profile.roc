## Profile page: fetches the public profile plus the author's articles (or
## favorited articles on the favorites tab). Tab links are route links, so
## deep links and back/forward cover the tabs for free.
import Api
import Feed
import Nav
import Route
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Profile := {}.{
	page : Signal.Signal(Route), Bool, Ui.State(Nav.RouteIntent) -> Elem
	page = |route, favorites, intent| {
		Ui.component(
			|_| {
				profile_task = Http.get_text_task("profile")
				articles_task = Http.get_text_task("profile-articles")
				profile_state = Signal.fold_task(profile_task, Loading, Api.decode_profile, Api.request_failed)
				articles_state = Signal.fold_task(articles_task, Loading, Api.decode_feed, Api.request_failed)
				username = Signal.map(route, |value| Route.profile_username(value))
				articles_uri = Signal.map(
					username,
					|value|
						if favorites {
							Api.favorited_articles_uri(value)
						} else {
							Api.author_articles_uri(value)
						},
				)
				is_loading = Signal.map(profile_state, profile_loading)
				is_failed = Signal.map(profile_state, profile_failed)
				message = Signal.map(profile_state, profile_message)
				name_text = Signal.map(profile_state, profile_name)
				bio_text = Signal.map(profile_state, profile_bio)
				tab_rows = Signal.map(username, |value| if Str.is_empty(value) { [] } else { [value] })

				Html.section(
					"Profile",
					[Html.class_attr("px-4 py-6")],
					[
						Ui.on_change_initial(
							username,
							|value|
								if Str.is_empty(value) {
									Signal.noop
								} else {
									Http.get_text(profile_task, Api.profile_uri(value))
								},
						),
						Ui.on_change_initial(articles_uri, |uri| Http.get_text(articles_task, uri)),
						Ui.when(
							is_loading,
							|_| Html.paragraph("Loading profile..."),
							|_|
								Ui.when(
									is_failed,
									|_| Html.paragraph_s_c(message, "text-red-700"),
									|_|
										Html.div(
											[Html.attr("data-conduit", "profile")],
											[
												Elem.Element({ tag: "h2", attrs: [Html.class_attr("text-xl font-bold")], children: [Html.text_s(name_text)] }),
												Html.paragraph_s_c(bio_text, "text-zinc-500"),
											],
										),
								),
						),
						Elem.Element(
							{
								tag: "nav",
								attrs: [Html.attr("aria-label", "Profile tabs"), Html.class_attr("flex gap-3 border-b border-zinc-200 py-2")],
								children: [
									Ui.each_str(tab_rows, |name| name, |name, _| tab_links(name, favorites, intent)),
								],
							},
						),
						Feed.view(articles_state, intent),
					],
				)
			},
		)
	}

	tab_links : Str, Bool, Ui.State(Nav.RouteIntent) -> Elem
	tab_links = |username, favorites, intent| {
		active = "border-b-2 border-emerald-600 font-medium text-emerald-700"
		idle = "text-zinc-500"
		Html.div_c(
			"flex gap-3",
			[
				Nav.link(
					"My Articles",
					if favorites { idle } else { active },
					Route.profile_location(username),
					intent,
				),
				Nav.link(
					"Favorited Articles",
					if favorites { active } else { idle },
					Route.profile_favorites_location(username),
					intent,
				),
			],
		)
	}

	profile_loading : Api.Remote(Api.Profile) -> Bool
	profile_loading = |remote|
		match remote {
			Loading => True
			_ => False
		}

	profile_failed : Api.Remote(Api.Profile) -> Bool
	profile_failed = |remote|
		match remote {
			Failed(_) => True
			_ => False
		}

	profile_message : Api.Remote(Api.Profile) -> Str
	profile_message = |remote|
		match remote {
			Failed(message) => message
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
