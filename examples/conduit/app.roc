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
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# Conduit (RealWorld) evidence app. Shell and history routing with
# per-route titles, deep links, and back/forward coverage; home, article,
# and profile pages are live read-only surfaces, while auth/editor pages
# stay placeholders until their build phases (wip/REALWORLD_DEMO_PLAN.md).

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
			attrs: [Html.class_attr("flex items-center justify-between px-4 py-3")],
			children: [
				Nav.link("conduit", "text-xl font-bold text-emerald-600", Route.home_location, intent),
				Elem.Element(
					{
						tag: "nav",
						attrs: [Html.attr("aria-label", "Site")],
						children: [
							Nav.link("Home", "px-2 text-zinc-600", Route.home_location, intent),
							Ui.when(
								signed_in,

								|| Html.div_c(
									"inline-flex",
									[
										Nav.link("New Article", "px-2 text-zinc-600", { path: "/editor", query: "", hash: "" }, intent),
										Nav.link("Settings", "px-2 text-zinc-600", { path: "/settings", query: "", hash: "" }, intent),
										Ui.each_str(username_rows, |name| name, |name, _| Nav.link(name, "px-2 text-emerald-700", Route.profile_location(name), intent)),
									],
								),

								|| Html.div_c(
									"inline-flex",
									[
										Nav.link("Sign in", "px-2 text-zinc-600", Route.login_location, intent),
										Nav.link("Sign up", "px-2 text-zinc-600", Route.register_location, intent),
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
		attrs: [Html.class_attr("px-4 py-3 text-sm text-zinc-500")],
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
			[Html.class_attr("px-4 py-6")],
			[
				Html.heading(heading),
				Html.paragraph(note),
			],
		),
	)
}

not_found_page : Ui.State(Nav.RouteIntent) -> Elem
not_found_page = |intent| {
	Ui.component(

		|| Html.section(
			"Page not found",
			[Html.class_attr("px-4 py-6")],
			[
				Html.heading("Page not found"),
				Html.paragraph("This address does not match any conduit page."),
				Nav.link("Take me home", "text-emerald-600 underline", Route.home_location, intent),
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
				"mx-auto flex min-h-screen max-w-3xl flex-col",
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
					Elem.Element({ tag: "main", attrs: [Html.class_attr("grow")], children: [page_view(route, session, route_intent)] }),
					footer_view,
				],
			)
		},
	)
}
