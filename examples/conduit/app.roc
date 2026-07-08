app [main] { pf: platform "../../platform/main.roc" }

import Article
import Home
import Nav
import Profile
import Route
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# Conduit (RealWorld) evidence app. Shell and history routing with
# per-route titles, deep links, and back/forward coverage; home, article,
# and profile pages are live read-only surfaces, while auth/editor pages
# stay placeholders until their build phases (wip/REALWORLD_DEMO_PLAN.md).


header_view : Ui.State(Nav.RouteIntent) -> Elem
header_view = |intent| {
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
							Nav.link("Sign in", "px-2 text-zinc-600", Route.login_location, intent),
							Nav.link("Sign up", "px-2 text-zinc-600", Route.register_location, intent),
						],
					},
				),
			],
		},
	)
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
		|_|
			Html.section(
				heading,
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading(heading),
					Html.paragraph(note),
				],
			),
	)
}

editor_edit_page : Signal.Signal(Route) -> Elem
editor_edit_page = |route| {
	Ui.component(
		|_|
			Html.section(
				"Edit article",
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading("Edit article"),
					Html.text_s(Signal.map(route, |value| "Editing: ${Route.article_slug(value)}")),
					Html.paragraph("The editor arrives with the write phase (Phase 4)."),
				],
			),
	)
}

not_found_page : Ui.State(Nav.RouteIntent) -> Elem
not_found_page = |intent| {
	Ui.component(
		|_|
			Html.section(
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

page_view : Signal.Signal(Route), Ui.State(Nav.RouteIntent) -> Elem
page_view = |route, intent| {
	is_kind = |name| Signal.map(route, |value| Route.kind(value) == name)
	Ui.when(
		is_kind("home"),
		|_| Home.page(route, intent),
		|_|
			Ui.when(
				is_kind("login"),
				|_| simple_page("Sign in", "The sign-in form arrives with sessions (Phase 3)."),
				|_|
					Ui.when(
						is_kind("register"),
						|_| simple_page("Sign up", "The sign-up form arrives with sessions (Phase 3)."),
						|_|
							Ui.when(
								is_kind("settings"),
								|_| simple_page("Settings", "Settings arrive with sessions (Phase 3)."),
								|_|
									Ui.when(
										is_kind("editor-new"),
										|_| simple_page("New article", "The editor arrives with the write phase (Phase 4)."),
										|_|
											Ui.when(
												is_kind("editor-edit"),
												|_| editor_edit_page(route),
												|_|
													Ui.when(
														is_kind("article"),
														|_| Article.page(route, intent),
														|_|
															Ui.when(
																is_kind("profile"),
																|_| Profile.page(route, False, intent),
																|_|
																	Ui.when(
																		is_kind("profile-favorites"),
																		|_| Profile.page(route, True, intent),
																		|_| not_found_page(intent),
																	),
															),
													),
											),
									),
							),
					),
			),
	)
}

main : {} -> Elem
main = |_| {
	Ui.state(
		Nav.initial,
		|route_intent| {
			location = Browser.location
			route = Signal.map(location, Route.from_location)
			document_title = Signal.map(route, Route.title)

			Html.div_c(
				"mx-auto flex min-h-screen max-w-3xl flex-col",
				[
					Ui.on_change(route_intent.signal(), |intent| Browser.push_state(Nav.location(intent))),
					Ui.on_change_initial(document_title, Browser.set_title),
					header_view(route_intent),
					Elem.Element({ tag: "main", attrs: [Html.class_attr("grow")], children: [page_view(route, route_intent)] }),
					footer_view,
				],
			)
		},
	)
}
