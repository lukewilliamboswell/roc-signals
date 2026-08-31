## Home page: banner, global feed with pagination and tag filtering, and the
## popular-tags sidebar. Fetches are scope-owned: they start when this page
## mounts and re-issue when the route's feed parameters change; leaving the
## page disposes the scope and cancels anything in flight.
import Api
import Feed
import Nav
import Route
import Session
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Home := {}.{
	page : Signal.Signal(Route), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	page = |route, session, intent| {
		Ui.component(
			|| {
				feed_task = Http.request_task("feed")
				tags_task = Http.get_text_task("tags")
				feed_state = Api.response_state(feed_task).map(Api.decode_feed_response)
				tags_state : Signal.Signal(Api.Remote(List(Str)))
				tags_state = Signal.fold_task(tags_task, Loading, Api.decode_tags, Api.request_failed)
				feed = route.map(|value| Route.feed_of(value))
				fetch_inputs = { feed: feed, session: session }.Signal
				fetch_params = fetch_inputs.map(|value| { feed: value.feed, token: Session.token_of(value.session) })
				feed_label = feed.map(feed_heading)
				signed_in = session.map(|value| Session.is_signed_in(value))

				Html.section(
					"Home",
					[Html.class_attr("pb-12")],
					[
						Ui.on_change_initial(fetch_params, |params| Http.start(feed_task, Api.feed_request(params.feed, params.token))),
						Ui.on_mount(|| Http.get_text(tags_task, Api.tags_uri)),
						Html.div_c(
							"bg-emerald-700 px-5 py-12 text-center text-white shadow-inner sm:py-16",
							[
								Html.heading_c("conduit", "text-5xl font-bold tracking-normal text-white sm:text-6xl"),
								Html.paragraph_c("A place to share your knowledge.", "mt-3 text-lg text-emerald-50 sm:text-xl"),
							],
						),
						Html.div_c(
							"mx-auto grid w-full max-w-6xl gap-8 px-5 py-10 sm:px-8 lg:grid-cols-[minmax(0,1fr)_16rem]",
							[
								Html.div_c(
									"min-w-0",
									[
										feed_tabs(feed, signed_in, intent),
										Html.paragraph_s_c(feed_label, "font-medium text-emerald-700"),
										Feed.view(feed_state, session, intent),
										Feed.pagination(feed_state, feed, intent),
									],
								),
								tags_sidebar(tags_state, intent),
							],
						),
					],
				)
			},
		)
	}

	feed_heading : Route.Feed -> Str
	feed_heading = |feed|
		match feed.source {
			Yours => "Your Feed"
			Global =>
				match feed.tag {
					Tagged(tag) => "Tag: ${tag}"
					AllTags => "Global Feed"
				}
			}

	feed_tabs : Signal.Signal(Route.Feed), Signal.Signal(Bool), Ui.State(Nav.RouteIntent) -> Elem
	feed_tabs = |feed, signed_in, intent| {
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline hover:no-underline"
		idle = "px-4 py-3 text-zinc-500 no-underline hover:no-underline"
		yours_class = feed.map(
			|value|
				match value.source {
					Yours => active
					Global => idle
				},
		)
		global_class = feed.map(
			|value|
				match value.source {
					Yours => idle
					Global =>
						match value.tag {
							AllTags => active
							Tagged(_) => idle
						}
					},
		)
		Elem.Element(
			{
				tag: "nav",
				attrs: [Html.attr("aria-label", "Feed tabs"), Html.class_attr("mb-4 flex border-b border-zinc-200")],
				children: [
					Ui.when(
						signed_in,
						|| Nav.link_c("Your Feed", yours_class, Route.feed_location({ page: 1, tag: AllTags, source: Yours }), intent),
						|| Html.text(""),
					),
					Nav.link_c("Global Feed", global_class, Route.home_location, intent),
				],
			},
		)
	}

	tags_sidebar : Signal.Signal(Api.Remote(List(Str))), Ui.State(Nav.RouteIntent) -> Elem
	tags_sidebar = |tags_state, intent| {
		is_loading : Signal.Signal(Bool)
		is_loading = tags_state.map(Api.is_loading)

		is_failed : Signal.Signal(Bool)
		is_failed = tags_state.map(Api.is_failed)

		tags : Signal.Signal(List(Str))
		tags = tags_state.map(tags_of)

		Elem.Element(
			{
				tag: "aside",
				attrs: [Html.class_attr("h-fit rounded-xl border border-zinc-200 bg-zinc-100 p-5")],
				children: [
					Html.paragraph_c("Popular Tags", "mb-3 font-semibold text-zinc-900"),
					Ui.when(
						is_loading,
						|| Html.paragraph("Loading tags..."),

						|| Ui.when(
							is_failed,
							|| Html.paragraph_c("Tags are unavailable.", "text-red-700"),

							|| Html.div_c(
								"flex flex-wrap gap-1",
								[Ui.each(tags, |tag| tag, |each_row| sidebar_tag(each_row.key(), intent))],
							),
						),
					),
				],
			},
		)
	}

	sidebar_tag : Str, Ui.State(Nav.RouteIntent) -> Elem
	sidebar_tag = |tag, intent|
		Nav.link(tag, "rounded-full bg-zinc-600 px-3 py-1 text-xs font-medium text-white no-underline hover:bg-emerald-700 hover:text-white hover:no-underline", Route.feed_location({ page: 1, tag: Tagged(tag), source: Global }), intent)



	tags_of : Api.Remote(List(Str)) -> List(Str)
	tags_of = |remote|
		match remote {
			Ready(tags) => tags
			_ => []
		}
}
