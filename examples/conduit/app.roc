app [main] { pf: platform "../../platform/main.roc" }

import Route
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# Conduit (RealWorld) evidence app. Phase 1: shell, history routing with
# per-route titles, deep links, and back/forward coverage. Pages are
# placeholders until their build phases (wip/REALWORLD_DEMO_PLAN.md).

RouteIntent : { serial : U64, path : Str, query : Str, hash : Str }

initial_intent : RouteIntent
initial_intent = { serial: 0, path: "/", query: "", hash: "" }

route_intent_for : RouteIntent, Browser.Location -> RouteIntent
route_intent_for = |current, target| {
	{
		serial: current.serial + 1,
		path: target.path,
		query: target.query,
		hash: target.hash,
	}
}

intent_location : RouteIntent -> Browser.Location
intent_location = |intent| { path: intent.path, query: intent.query, hash: intent.hash }

nav_link : Str, Str, Browser.Location, Ui.State(RouteIntent) -> Elem
nav_link = |label, classes, target, intent| {
	Html.link(
		label,
		[
			Html.class_attr(classes),
			Html.attr("href", target.path),
			Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| route_intent_for(current, target))),
		],
	)
}

header_view : Ui.State(RouteIntent) -> Elem
header_view = |intent| {
	Elem.Element(
		{
			tag: "header",
			attrs: [Html.class_attr("flex items-center justify-between px-4 py-3")],
			children: [
				nav_link("conduit", "text-xl font-bold text-emerald-600", Route.home_location, intent),
				Elem.Element(
					{
						tag: "nav",
						attrs: [Html.attr("aria-label", "Site")],
						children: [
							nav_link("Home", "px-2 text-zinc-600", Route.home_location, intent),
							nav_link("Sign in", "px-2 text-zinc-600", Route.login_location, intent),
							nav_link("Sign up", "px-2 text-zinc-600", Route.register_location, intent),
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

home_feed_text : Route -> Str
home_feed_text = |route| {
	feed = Route.feed_of(route)
	prefix =
		match feed.tag {
			Tagged(tag) => "Tag ${tag}"
			AllTags => "Global feed"
		}
	"${prefix} - page ${feed.page.to_str()}"
}

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

home_page : Signal.Signal(Route) -> Elem
home_page = |route| {
	Ui.component(
		|_|
			Html.section(
				"Home",
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading("conduit"),
					Html.paragraph("A place to share your knowledge."),
					Html.paragraph_s(Signal.map(route, home_feed_text)),
					Html.paragraph("Feeds arrive with the read-only phase (Phase 2)."),
				],
			),
	)
}

article_page : Signal.Signal(Route) -> Elem
article_page = |route| {
	Ui.component(
		|_|
			Html.section(
				"Article",
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading("Article"),
					Html.text_s(Signal.map(route, |value| "Slug: ${Route.article_slug(value)}")),
					Html.paragraph("Article content arrives with the read-only phase (Phase 2)."),
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

profile_page : Signal.Signal(Route), Bool -> Elem
profile_page = |route, favorites| {
	tab_note =
		if favorites {
			"Favorited articles"
		} else {
			"My articles"
		}
	Ui.component(
		|_|
			Html.section(
				"Profile",
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading("Profile"),
					Html.text_s(Signal.map(route, |value| "@${Route.profile_username(value)}")),
					Html.paragraph(tab_note),
					Html.paragraph("Profiles arrive with the read-only phase (Phase 2)."),
				],
			),
	)
}

not_found_page : Ui.State(RouteIntent) -> Elem
not_found_page = |intent| {
	Ui.component(
		|_|
			Html.section(
				"Page not found",
				[Html.class_attr("px-4 py-6")],
				[
					Html.heading("Page not found"),
					Html.paragraph("This address does not match any conduit page."),
					nav_link("Take me home", "text-emerald-600 underline", Route.home_location, intent),
				],
			),
	)
}

page_view : Signal.Signal(Route), Ui.State(RouteIntent) -> Elem
page_view = |route, intent| {
	is_kind = |name| Signal.map(route, |value| Route.kind(value) == name)
	Ui.when(
		is_kind("home"),
		|_| home_page(route),
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
														|_| article_page(route),
														|_|
															Ui.when(
																is_kind("profile"),
																|_| profile_page(route, False),
																|_|
																	Ui.when(
																		is_kind("profile-favorites"),
																		|_| profile_page(route, True),
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
		initial_intent,
		|route_intent| {
			location = Browser.location
			route = Signal.map(location, Route.from_location)
			document_title = Signal.map(route, Route.title)

			Html.div_c(
				"mx-auto flex min-h-screen max-w-3xl flex-col",
				[
					Ui.on_change(route_intent.signal(), |intent| Browser.push_state(intent_location(intent))),
					Ui.on_change_initial(document_title, Browser.set_title),
					header_view(route_intent),
					Elem.Element({ tag: "main", attrs: [Html.class_attr("grow")], children: [page_view(route, route_intent)] }),
					footer_view,
				],
			)
		},
	)
}
