app [main] { pf: platform "../../platform/main.roc" }

import Article
import Auth
import Editor
import Home
import Nav
import Profile
import Route
import Session
import Settings
import Styles
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# Conduit (RealWorld) evidence app. The complete routed application covers
# feeds, auth, profiles, articles, comments, settings, and server-confirmed
# mutations while keeping history, persisted session, and document title in
# sync through Signals descriptors.

header_view : Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
header_view = |session, intent| {
	signed_in : Signal.Signal(Bool)
	signed_in = session.map(|value| Session.is_signed_in(value))

	username_rows : Signal.Signal(List(Str))
	username_rows = session.map(
		|value|
			match value {
				SignedIn(user) => [user.username]
				Anonymous => []
			},
	)
	Elem.Element(
		{
			tag: "header",
		attrs: [Html.class_attr(Styles.header)],
			children: [
			Nav.link("conduit", "text-2xl font-bold tracking-normal text-emerald-600 no-underline hover:no-underline", Route.home_location, intent),
				Elem.Element(
					{
						tag: "nav",
					attrs: [Html.attr("aria-label", "Site"), Html.class_attr("flex flex-wrap items-center text-sm font-medium")],
						children: [
							Nav.link("Home", "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline", Route.home_location, intent),
							Ui.when(
								signed_in,

								|| Html.div_c(
									"inline-flex",
									[
										Nav.link("New Article", "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline", { path: "/editor", query: "", hash: "" }, intent),
										Nav.link("Settings", "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline", { path: "/settings", query: "", hash: "" }, intent),
										Ui.each_str(username_rows, |name| name, |name, _| Nav.link(name, "rounded-md px-3 py-2 text-emerald-700 no-underline hover:bg-emerald-50 hover:no-underline", Route.profile_location(name), intent)),
									],
								),

								|| Html.div_c(
									"inline-flex",
									[
										Nav.link("Sign in", "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline", Route.login_location, intent),
										Nav.link("Sign up", "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline", Route.register_location, intent),
									],
								),
							),
						],
					},
				),
			],
		},
	)
}

guard_target : Route, Session -> [Stay, Redirect(Browser.Location)]
guard_target = |route, session| {
	kind = Route.kind(route)
	signed_in = Session.is_signed_in(session)
	requires_auth = kind == "settings" or kind == "editor-new" or kind == "editor-edit"
	anonymous_only = kind == "login" or kind == "register"
	if requires_auth and !signed_in {
		Redirect(Route.login_location)
	} else if anonymous_only and signed_in {
		Redirect(Route.home_location)
	} else {
		Stay
	}
}

footer_view : Elem
footer_view = Elem.Element(
	{
		tag: "footer",
		attrs: [Html.class_attr(Styles.footer)],
		children: [
			Elem.Element({ tag: "span", attrs: [Html.class_attr("font-semibold text-emerald-600")], children: [Html.text("conduit")] }),
			Html.text(" - a RealWorld evidence app built on roc-signals."),
		],
	},
)

simple_page : Str, Str -> Elem
simple_page = |heading, note| {
	Ui.component(

		|| Html.section(
			heading,
			[Html.class_attr(Styles.page)],
			[
				Html.heading_c(heading, Styles.heading),
				Html.paragraph_c(note, "mt-3 leading-7 text-zinc-600"),
			],
		),
	)
}

not_found_page : Ui.State(Nav.RouteIntent) -> Elem
not_found_page = |intent| {
	Ui.component(

		|| Html.section(
			"Page not found",
			[Html.class_attr(Styles.page)],
			[
				Html.heading_c("Page not found", Styles.heading),
				Html.paragraph_c("This address does not match any conduit page.", "mt-3 text-zinc-600"),
				Html.div_c("mt-6", [Nav.link("Take me home", Styles.secondary_button, Route.home_location, intent)]),
			],
		),
	)
}

page_view : Signal.Signal(Route), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
page_view = |route, session, intent| {
	is_kind : Str -> Signal.Signal(Bool)
	is_kind = |name| route.map(|value| Route.kind(value) == name)

	home_page : Elem
	home_page = Home.page(route, session, intent)

	login_page : Elem
	login_page = Auth.page(False, intent)

	register_page : Elem
	register_page = Auth.page(True, intent)

	settings_page : Elem
	settings_page = Settings.page(session, intent)

	new_article_page : Elem
	new_article_page = Editor.create_page(session)

	edit_article_page : Elem
	edit_article_page = Editor.edit_page(route, session)

	article_page : Elem
	article_page = Article.page(route, session, intent)

	profile_page : Elem
	profile_page = Profile.page(route, session, False, intent)

	profile_favorites_page : Elem
	profile_favorites_page = Profile.page(route, session, True, intent)

	not_found : Elem
	not_found = not_found_page(intent)

	profile_favorites_or_not_found : Elem
	profile_favorites_or_not_found = Ui.when(
		is_kind("profile-favorites"),
		|| profile_favorites_page,
		|| not_found,
	)

	profile_or_rest : Elem
	profile_or_rest = Ui.when(
		is_kind("profile"),
		|| profile_page,
		|| profile_favorites_or_not_found,
	)

	article_or_rest : Elem
	article_or_rest = Ui.when(
		is_kind("article"),
		|| article_page,
		|| profile_or_rest,
	)

	edit_article_or_rest : Elem
	edit_article_or_rest = Ui.when(
		is_kind("editor-edit"),
		|| edit_article_page,
		|| article_or_rest,
	)

	new_article_or_rest : Elem
	new_article_or_rest = Ui.when(
		is_kind("editor-new"),
		|| new_article_page,
		|| edit_article_or_rest,
	)

	settings_or_rest : Elem
	settings_or_rest = Ui.when(
		is_kind("settings"),
		|| settings_page,
		|| new_article_or_rest,
	)

	register_or_rest : Elem
	register_or_rest = Ui.when(
		is_kind("register"),
		|| register_page,
		|| settings_or_rest,
	)

	login_or_rest : Elem
	login_or_rest = Ui.when(
		is_kind("login"),
		|| login_page,
		|| register_or_rest,
	)

	Ui.when(
		is_kind("home"),
		|| home_page,
		|| login_or_rest,
	)
}

main : () -> Elem
main = || {
	Ui.state(
		Nav.initial,
		|route_intent| {
				location = Browser.location()
			route = location.map(Route.from_location)
				session = Session.current()
			document_title = route.map(Route.title)
			guard_inputs = { route: route, session: session }.Signal
			guard = guard_inputs.map(|value| guard_target(value.route, value.session))

			Html.div_c(
			Styles.shell,
				[
					Ui.on_change(route_intent.signal(), |intent| Browser.push_state(Nav.location(intent))),
					Ui.on_change_initial(
						guard,
						|target|
							match target {
								Redirect(redirect_location) => Browser.replace_state(redirect_location)
								Stay => Signal.noop
							},
					),
					Ui.on_change_initial(document_title, Browser.set_title),
					header_view(session, route_intent),
				Elem.Element({ tag: "main", attrs: [Html.class_attr(Styles.main)], children: [page_view(route, session, route_intent)] }),
					footer_view,
				],
			)
		},
	)
}
