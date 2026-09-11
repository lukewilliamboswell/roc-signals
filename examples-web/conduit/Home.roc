## Home page: banner, global feed with pagination and tag filtering, and the
## popular-tags sidebar. Results belong to the page scope. Admitted effects
## finish independently; leaving the page retires their write targets.
import Api
import Feed
import Nav
import Route
import Session
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Action exposing [Action]
import pf.Signal
import pf.Ui

Home := {}.{
	page : Signal.Signal(Route), Signal.Signal(Session), Ui.State(Nav.RouteIntent) -> Elem
	page = |route, session, intent| Ui.state(Loading, |tags|
		Ui.state({ generation: 0.U64, value: Loading }, |feed_result| page_with_tags(route, session, intent, tags, feed_result)))

	FeedState : { generation : U64, value : Api.Remote(Api.FeedPage) }
	FeedParams : { feed : Route.Feed, token : Str }
	FeedRead : { params : Home.FeedParams, generation : U64 }

	page_with_tags : Signal.Signal(Route), Signal.Signal(Session), Ui.State(Nav.RouteIntent), Ui.State(Api.Remote(List(Str))), Ui.State(Home.FeedState) -> Elem
	page_with_tags = |route, session, intent, tags, feed_result| {
		Ui.component(
			|| {
				feed_state = feed_result.signal().map(|current| current.value)
				tags_state : Signal.Signal(Api.Remote(List(Str)))
				tags_state = tags.signal()
				feed = route.map(|value| Route.feed_of(value))
				fetch_inputs = { feed: feed, session: session }.Signal
				fetch_params = fetch_inputs.map(|value| { feed: value.feed, token: Session.token_of(value.session) })
				feed_label = feed.map(feed_heading)
				signed_in = session.map(|value| Session.is_signed_in(value))

				Html.section(
					"Home",
					[Html.class_attr("pb-12")],
					[
						Action.on_change_initial(Action.sampled(fetch_params, { params: fetch_params, generation: feed_result.signal().map(|current| current.generation) }.Signal), |read| start_feed(feed_result, read)),
						Action.on_change_initial(Signal.const({}), |_| Action.then([], |_| load_tags!(tags))),
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

	start_feed : Ui.State(Home.FeedState), Home.FeedRead -> Action(Home.FeedRead)
	start_feed = |state, read| {
		generation = read.generation + 1
		Action.then([state.write(|_current| { generation, value: Loading })], |_| load_feed!(state, read.params, generation))
	}

	load_feed! : Ui.State(Home.FeedState), Home.FeedParams, U64 => Action(Home.FeedRead)
	load_feed! = |state, params, generation| {
		response = Api.send_response!(Api.feed_request(params.feed, params.token))
		value = Api.decode_feed_response(response)
		Action.update([
			state.write(
				|current| if current.generation == generation {
					{ ..current, value }
				} else {
					current
				},
			),
		])
	}

	load_tags! : Ui.State(Api.Remote(List(Str))) => Action({})
	load_tags! = |tags| {
		response = Api.send_response!(Api.get_request(Api.tags_uri, ""))
		value = if !response.error.is_empty() {
			Api.request_failed(response.error)
		} else if response.status == 200 {
			Api.decode_tags(response.body)
		} else {
			Failed("The server responded with status ${response.status.to_str()}.")
		}
		Action.update([tags.write(|_current| value)])
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
		Elem.Element({
			namespace: Html,
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
		})
	}

	tags_sidebar : Signal.Signal(Api.Remote(List(Str))), Ui.State(Nav.RouteIntent) -> Elem
	tags_sidebar = |tags_state, intent| {
		is_loading : Signal.Signal(Bool)
		is_loading = tags_state.map(Api.is_loading)

		is_failed : Signal.Signal(Bool)
		is_failed = tags_state.map(Api.is_failed)

		tags : Signal.Signal(List(Str))
		tags = tags_state.map(tags_of)

		Elem.Element({
			namespace: Html,
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
							[Ui.each(Signal.map(tags, |rows_items| Rows.from_list(rows_items, |tag| tag) ?? crash "duplicate row key"), |each_row| sidebar_tag(each_row.key(), intent))],
						),
					),
				),
			],
		})
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
