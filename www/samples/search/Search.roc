import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## A search box. Submitting the form fetches results over HTTP; while
## auto-refresh is checked, a 30 s interval fetches them again.
Search := [].{

	## What the results line shows.
	Status : [Idle, Loading, Found(Str), Failed(Engine.HttpError)]

	## `round` counts searches and refreshes, so repeating a query refetches.
	S : { draft : Str, query : Str, round : U64, live : Bool, status : Status }

	Ctx : In(Root, S)

	## The program both platforms run.
	program : Engine.Program
	program = Engine.program(|| Engine.state({ draft: "", query: "", round: 0, live: Bool.False, status: Idle }, Search.view))

	# region requests
	## One GET per search or refresh; nothing before the first search.
	requests : { query : Str, round : U64 } -> List(Engine.Ask(Str, Engine.HttpError))
	requests = |{ query, .. }|
		if query == "" {
			[]
		} else {
			[Engine.http_body({ url: "/api/search?q=${query}", timeout: Ms(5000) })]
		}

	## Keep the body of a successful response, or the typed failure.
	answered : S, { query : Str, round : U64 }, Try(Str, Engine.HttpError) -> S
	answered = |s, _, res|
		match res {
			Ok(body) => { ..s, status: Found(body) }
			Err(err) => { ..s, status: Failed(err) }
		}
	# endregion requests

	shown : Status -> Str
	shown = |status|
		match status {
			Idle => ""
			Loading => "Searching…"
			Found(body) => body
			Failed(err) => "Search failed: ${Str.inspect(err)}"
		}

	# region view
	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"search",
			[
				Html.form(
					"Search",
					[Html.on_submit(st.update(|s| { ..s, query: s.draft, round: s.round + 1, status: Loading }))],
					[
						Html.text_input(Engine.const("Query"), "search", v.map(|s| s.draft), [], st.set_value(|s, t| { ..s, draft: t })),
						Html.submit_button("Search", []),
					],
				),
				Html.checkbox(Engine.const("Auto-refresh"), v.map(|s| s.live), [], st.set_value(|s, p| { ..s, live: p == "true" })),
				Engine.when(
					v.map(|s| s.live),
					|| Engine.watch(Engine.const({}), |_| [Engine.interval(30000)], st.on_result(|s, _, _| { ..s, round: s.round + 1 })),
					|| Engine.text(""),
				),
				Engine.watch_changes(v.map(|s| { query: s.query, round: s.round }), Search.requests, st.on_result(Search.answered)),
				Html.p_s(v.map(|s| Search.shown(s.status)), [Engine.test_id("results")]),
			],
		)
	}
	# endregion view
}
