app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

# region boot
## Declared storage keys are read before mount and arrive in `Boot`, with the
## URL and whether the browser is online and the page visible.
main : Engine.Program
main = Engine.program_boot(
	{ storage_keys: ["query"], max_inflight: 32 },
	|boot| Engine.state(initial(boot), page),
)

initial : Engine.Boot -> Model
initial = |boot| { query: Engine.boot_storage(boot, "query") ?? "", results: Idle, url: boot.url, nav: { serial: 0, url: boot.url }, online: boot.online, ticks: 0 }

# endregion boot

# region model
Results : [Idle, Loading, Loaded(Str), Failed(Engine.HttpError)]

## `url` is where the browser is; `nav` is the app's latest request to go
## somewhere. They are separate so that following the back button does not
## push a new history entry.
Model : { query : Str, results : Results, url : Str, nav : { serial : U64, url : Str }, online : Bool, ticks : U64 }

Ctx : In(Root, Model)

# endregion model

# region http
## Issue a request whenever the query changes. The reaction receives the
## query the request was issued for, so a late answer to an old query is
## recognised and ignored.
search : State(Ctx, Model) -> Elem(Ctx)
search = |model|
	Engine.on_change(
		model.val().map(|m| m.query),
		|q| [Http({ method: "GET", url: "/api/search?q=${q}", headers: [], body: "", timeout_ms: 5000 })],
		model.on_result(
			|m, q, res|
				if q != m.query {
					m
				} else {
					match Engine.http_text(res) {
						Ok(body) => { ..m, results: Loaded(body) }
						Err(err) => { ..m, results: Failed(err) }
					}
				},
		),
	)

# endregion http

# region commands
## Commands are emitted and forgotten: the title follows the query, and the
## query is saved for the next visit.
commands : State(Ctx, Model) -> List(Elem(Ctx))
commands = |model| {
	query = model.val().map(|m| m.query)
	[
		Engine.watch(query, |q| [Title(if (q.is_empty()) "Search" else "Search: ${q}")], Engine.ignore({})),
		Engine.on_change(query, |q| [StorageSet("query", q)], Engine.ignore({})),
	]
}

# endregion commands

# region routing
## Navigation is a pair of effects: `Push` when the app navigates, and a
## `Popstate` subscription for the back and forward buttons.
go : Model, Str -> Model
go = |m, url| { ..m, url, nav: { serial: m.nav.serial + 1, url } }

routing : State(Ctx, Model) -> List(Elem(Ctx))
routing = |model| [
	Engine.on_change(model.val().map(|m| m.nav), |n| [Push(n.url)], Engine.ignore({})),
	Html.button("Settings", [], model.update(|m| go(m, "/settings"))),
	Engine.watch(
		Engine.const({}),
		|_| [Popstate],
		model.on_result(
			|m, _, res|
				match res {
					Location(url) => { ..m, url }
					_ => m
				},
		),
	),
]

# endregion routing

# region subscriptions
## Subscriptions deliver results until their site is disposed. This interval
## runs only while the page is online: going offline disposes the `when`
## branch, which cancels it.
subscriptions : State(Ctx, Model) -> List(Elem(Ctx))
subscriptions = |model| [
	Engine.watch(
		Engine.const({}),
		|_| [OnlineChanges],
		model.on_result(
			|m, _, res|
				match res {
					Online(online) => { ..m, online }
					_ => m
				},
		),
	),
	Engine.when(
		model.val().map(|m| m.online),
		|| Engine.watch(Engine.const({}), |_| [Interval(30000)], model.on_result(|m, _, _| { ..m, ticks: m.ticks + 1 })),
		|| Engine.text(""),
	),
]

# endregion subscriptions

# region focus
## Focus is a command on a named reference. Here every change of the query
## keeps the search box focused.
search_box : State(Ctx, Model) -> List(Elem(Ctx))
search_box = |model| {
	query = model.val().map(|m| m.query)
	[
		Html.text_input(Engine.const("Search"), "search", query, [Engine.ref("search")], model.set_value(|m, q| { ..m, query: q, results: Loading })),
		Engine.on_change(query, |_| [Focus("search")], Engine.ignore({})),
	]
}

# endregion focus

# region cleanup
## A cleanup runs when its scope is disposed, and may only issue commands.
leaving : State(Ctx, Model) -> Elem(Ctx)
leaving = |model| Engine.on_cleanup("restore title", model.val(), |_| [Title("Search")])

# endregion cleanup

status : Results -> Str
status = |results|
	match results {
		Idle => ""
		Loading => "Searching…"
		Loaded(body) => body
		Failed(Network(message)) => "Offline: ${message}"
		Failed(Timeout) => "The search timed out."
		Failed(Status(code)) => "The server answered ${code.to_str()}."
		Failed(Refused) => "Too many searches at once."
	}

page : State(Ctx, Model) -> Elem(Ctx)
page = |model|
	Html.div(
		"search",
		search_box(model)
			.concat([search(model), leaving(model), Html.p_v(model.val().map(|m| status(m.results)), [Engine.test_id("results")])])
			.concat(commands(model))
			.concat(routing(model))
			.concat(subscriptions(model)),
	)
