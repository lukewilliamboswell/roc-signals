## Home page: banner, global feed with pagination and tag filtering, and the
## popular-tags sidebar. Fetches are scope-owned: they start when this page
## mounts and re-issue when the route's feed parameters change; leaving the
## page disposes the scope and cancels anything in flight.
import Api
import Feed
import Nav
import Route
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Home := {}.{
	page : Signal.Signal(Route), Ui.State(Nav.RouteIntent) -> Elem
	page = |route, intent| {
		Ui.component(
			|_| {
				feed_task = Http.get_text_task("feed")
				tags_task = Http.get_text_task("tags")
				feed_state = Signal.fold_task(feed_task, Loading, Api.decode_feed, Api.request_failed)
				tags_state = Signal.fold_task(tags_task, Loading, Api.decode_tags, Api.request_failed)
				feed = Signal.map(route, |value| Route.feed_of(value))
				feed_uri = Signal.map(feed, |value| Api.feed_uri(value))
				feed_label = Signal.map(feed, feed_heading)

				Html.section(
					"Home",
					[Html.class_attr("px-4 py-6")],
					[
						Ui.on_change_initial(feed_uri, |uri| Http.get_text(feed_task, uri)),
						Ui.on_mount(|_| Http.get_text(tags_task, Api.tags_uri)),
						Html.heading("conduit"),
						Html.paragraph("A place to share your knowledge."),
						Html.div_c(
							"flex gap-6",
							[
								Html.div_c(
									"grow",
									[
										Html.paragraph_s_c(feed_label, "font-medium text-emerald-700"),
										Feed.view(feed_state, intent),
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
		match feed.tag {
			Tagged(tag) => "Tag: ${tag}"
			AllTags => "Global Feed"
		}

	tags_sidebar : Signal.Signal(Api.Remote(List(Str))), Ui.State(Nav.RouteIntent) -> Elem
	tags_sidebar = |tags_state, intent| {
		is_loading = Signal.map(tags_state, tags_loading)
		is_failed = Signal.map(tags_state, tags_failed)
		tags = Signal.map(tags_state, tags_of)
		Elem.Element(
			{
				tag: "aside",
				attrs: [Html.class_attr("w-40 shrink-0 rounded bg-zinc-100 p-3")],
				children: [
					Html.paragraph_c("Popular Tags", "font-medium"),
					Ui.when(
						is_loading,
						|_| Html.paragraph("Loading tags..."),
						|_|
							Ui.when(
								is_failed,
								|_| Html.paragraph_c("Tags are unavailable.", "text-red-700"),
								|_|
									Html.div_c(
										"flex flex-wrap gap-1",
										[Ui.each_str(tags, |tag| tag, |tag, _| sidebar_tag(tag, intent))],
									),
							),
					),
				],
			},
		)
	}

	sidebar_tag : Str, Ui.State(Nav.RouteIntent) -> Elem
	sidebar_tag = |tag, intent|
		Nav.link(tag, "rounded bg-zinc-500 px-2 text-xs text-white", Route.feed_location({ page: 1, tag: Tagged(tag) }), intent)

	tags_loading : Api.Remote(List(Str)) -> Bool
	tags_loading = |remote|
		match remote {
			Loading => True
			_ => False
		}

	tags_failed : Api.Remote(List(Str)) -> Bool
	tags_failed = |remote|
		match remote {
			Failed(_) => True
			_ => False
		}

	tags_of : Api.Remote(List(Str)) -> List(Str)
	tags_of = |remote|
		match remote {
			Ready(tags) => tags
			_ => []
		}
}
