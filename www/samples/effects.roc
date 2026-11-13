app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Clipboard

# region boot
## Declared storage keys are read before mount and arrive in `Boot`, with the
## URL and whether the browser is online and the page visible.
main : Engine.Program
main = Engine.program_boot(
	{ storage_keys: ["query"], session_keys: ["query.draft"], max_inflight: 32 },
	|boot| Engine.state(initial(boot), page),
)

initial : Engine.Boot -> Model
initial = |boot| { query: Engine.boot_session(boot, "query.draft") ?? (Engine.boot_storage(boot, "query") ?? ""), results: Idle, url: boot.url, nav: Engine.outbox({}), saving: Engine.outbox({}), saved: [], online: boot.online, ticks: 0, drafts: Engine.outbox({}), copies: Engine.outbox({}), copy_status: "", paste_status: "", draft_status: if (boot.session_available) "" else "Drafts cannot survive a reload" }

# endregion boot

# region model
Results : [Idle, Loading, Loaded(Str), Failed(Engine.HttpError)]

## `url` is where the browser is; `nav` is an outbox of the places the app
## asks to go. They are separate so that following the back button does not
## push a new history entry. `saving` is an outbox of the searches the user
## asks to save, and `saved` those the server has kept.
Model : { query : Str, results : Results, url : Str, nav : Engine.Outbox(Str), saving : Engine.Outbox(Str), saved : List(Str), online : Bool, ticks : U64, drafts : Engine.Outbox({}), copies : Engine.Outbox({}), copy_status : Str, paste_status : Str, draft_status : Str }

Ctx : In(Root, Model)

# endregion model

# region http
## Issue a request whenever the query changes. The reaction receives the
## query the request was issued for, so a late answer to an old query is
## recognised and ignored.
search : State(Ctx, Model) -> Elem(Ctx)
search = |model|
	Engine.watch_changes(
		model.signal().map(|m| m.query),
		|q| [Engine.http_body({ url: "/api/search?q=${q}", timeout: Ms(5000) })],
		model.on_result(
			|m, q, res|
				if q != m.query {
					m
				} else {
					match res {
						Ok(body) => { ..m, results: Loaded(body) }
						Err(err) => { ..m, results: Failed(err) }
					}
				},
		),
	)

# endregion http

# region post
## The click posts the query to an outbox in the state, and the `on_post`
## site sends it in the same turn. Saving the same query twice is two
## requests, and each answer arrives with the query it was posted with.
save : State(Ctx, Model) -> List(Elem(Ctx))
save = |model| [
	Html.button("Save search", [], model.update(|m| { ..m, saving: m.saving.post(m.query) })),
	Engine.on_post(
		model.signal().map(|m| m.saving),
		|q| [Engine.http_body({ method: "POST", url: "/api/saved", body: q, timeout: Ms(5000) })],
		model.on_result(
			|m, q, res|
				match res {
					Ok(_) => { ..m, saved: m.saved.append(q) }
					Err(_) => m
				},
		),
	),
]

# endregion post

# region commands
## Commands are emitted and forgotten: the title follows the query, and the
## query is saved for the next visit.
commands : State(Ctx, Model) -> List(Elem(Ctx))
commands = |model| {
	query = model.signal().map(|m| m.query)
	[
		Engine.watch(query, |q| [Engine.command(Title(if (q.is_empty()) "Search" else "Search: ${q}"))], Engine.ignore({})),
		Engine.watch_changes(query, |q| [Engine.command(StorageSet("query", q))], Engine.ignore({})),
	]
}

# endregion commands

# region routing
## Navigation is a pair of effects: `Push` when the app navigates, and a
## `Popstate` subscription for the back and forward buttons.
go : Model, Str -> Model
go = |m, url| { ..m, url, nav: m.nav.post(url) }

routing : State(Ctx, Model) -> List(Elem(Ctx))
routing = |model| [
	Engine.on_post(model.signal().map(|m| m.nav), |url| [Engine.command(Push(url))], Engine.ignore({})),
	Html.button("Settings", [], model.update(|m| go(m, "/settings"))),
	Engine.watch(
		Engine.const({}),
		|_| [Engine.popstate({})],
		model.on_result(
			|m, _, res|
				match res {
					Ok(url) => { ..m, url }
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
		|_| [Engine.online_changes({})],
		model.on_result(
			|m, _, res|
				match res {
					Ok(online) => { ..m, online }
					_ => m
				},
		),
	),
	Engine.when(
		model.signal().map(|m| m.online),
		|| Engine.watch(Engine.const({}), |_| [Engine.interval(30000)], model.on_result(|m, _, _| { ..m, ticks: m.ticks + 1 })),
		|| Engine.text(""),
	),
]

# endregion subscriptions

# region focus
## Focus is a command on a named reference. Here every change of the query
## keeps the search box focused.
search_box : State(Ctx, Model) -> List(Elem(Ctx))
search_box = |model| {
	query = model.signal().map(|m| m.query)
	[
		Html.text_input(Engine.const("Search"), "search", query, [Engine.ref("search")], model.set_value(|m, q| { ..m, query: q, results: Loading, draft_status: "", drafts: m.drafts.post({}) })),
		Engine.watch_changes(query, |_| [Engine.command(Focus("search"))], Engine.ignore({})),
	]
}

# endregion focus

# region cleanup
## A cleanup runs when its scope is disposed. Its plan returns commands, a
## list of `Engine.Command`: a request that awaits a result does not compile
## there.
leaving : State(Ctx, Model) -> Elem(Ctx)
leaving = |model| Engine.on_cleanup("restore title", model.signal(), |_| [Title("Search")])

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
			.concat([search(model), leaving(model), Html.p_s(model.signal().map(|m| status(m.results)), [Engine.test_id("results")])])
			.concat(save(model))
			.concat(commands(model))
			.concat(routing(model))
			.concat(subscriptions(model))
			.concat(drafts(model))
			.concat(copy_search(model))
			.concat([paste_search(model), progress_search({})]),
	)

# region scroll
## Explicit scroll commands run in stream order after the batch. Focus in
## place then moves keyboard focus without asking the browser to scroll.
reveal_problem : Engine.Signal(Ctx, Bool) -> Elem(Ctx)
reveal_problem = |invalid| Engine.watch_changes(
	invalid,
	|has_problem| if has_problem {
		[Engine.command(Engine.scroll_into_view("problem", { block: Center, behavior: Instant })), Engine.command(FocusInPlace("problem"))]
	} else {
		[]
	},
	Engine.ignore({}),
)

## The narrow scroll tag also fits cleanup's command-only plan.
restore_scroll : Engine.Signal(Ctx, {}) -> Elem(Ctx)
restore_scroll = |signal| Engine.on_cleanup("restore page position", signal, |_| [Engine.scroll_into_view("search", {}), ScrollTo("search", { top: Start, left: Keep, behavior: Auto })])

# endregion scroll

# region session
## The tab keeps its own draft. A failed write becomes a visible message;
## the failure subscription also hears refused writes to local storage.
drafts : State(Ctx, Model) -> List(Elem(Ctx))
drafts = |model| [
	Engine.on_post_by(model.signal().map(|m| m.drafts), model.signal().map(|m| m.query), |query, _| [Engine.command(SessionStorageSet("query.draft", query))], Engine.ignore({})),
	Engine.watch(
		Engine.const({}),
		|_| [Engine.storage_write_failures({})],
		model.on_result(
			|m, _, result| match result {
				Ok({ store: _, key, reason: Quota }) => { ..m, draft_status: "Not kept: ${key} is over the storage quota" }
				Ok({ store: _, key, reason: Unavailable }) => { ..m, draft_status: "Not kept: storage for ${key} is unavailable" }
				Err(Refused) => { ..m, draft_status: "Storage failures cannot be reported" }
				_ => m
			},
		),
	),
	Html.p_s(model.signal().map(|m| m.draft_status), []),
]

# endregion session

# region guard
## Pass the editor's dirty signal, usually a comparison of two revision
## numbers. Its live true guards jointly request one leave warning.
leave_warning : Engine.Signal(Ctx, Bool) -> Elem(Ctx)
leave_warning = |dirty| Engine.guard_leave(dirty)

# endregion guard

# region clipboard
## Post a small marker and read the text only when issuing its request.
## The site retains the marker, so it does not keep an old copy of the query.
## Issuing in the button's turn retains that gesture's activation.
copy_search : State(Ctx, Model) -> List(Elem(Ctx))
copy_search = |model| [
	Html.button("Copy search", [], model.update(|m| { ..m, copies: m.copies.post({}) })),
	Engine.on_post_by(
		model.signal().map(|m| m.copies),
		model.signal().map(|m| m.query),
		|text, _| [Clipboard.text(text)],
		model.on_result(
			|m, _, result| {
				copy_status = match result {
					Ok(_) => "Copied"
					Err(NotAllowed) => "Copy blocked by the browser"
					Err(Unavailable) => "The clipboard is unavailable"
					Err(Refused) => "Too many requests to copy now"
				}
				{ ..m, copy_status }
			},
		),
	),
	Html.p_s(model.signal().map(|m| m.copy_status), []),
]

# endregion clipboard

# region paste
## This focusable zone imports plain text and prevents the ordinary paste.
## Oversized text changes only the message, preserving the query.
paste_search : State(Ctx, Model) -> Elem(Ctx)
paste_search = |model| Html.div_attrs(
	[
		Engine.attr("tabindex", "0"),
		Engine.attr("aria-label", "Paste a search"),
		Html.on_paste_text(
			model.set_value(
				|m, pasted| match pasted {
					Text(text) => { ..m, query: text, results: Loading, paste_status: "Search imported", draft_status: "", drafts: m.drafts.post({}) }
					TooLarge => { ..m, paste_status: "Pasted text is too large" }
				},
			),
		),
	],
	[Engine.text("Paste a search here"), Html.p_s(model.signal().map(|m| m.paste_status), [])],
)

# endregion paste

# region progress
## Attaching this handler asks for sampled progress on the site's transfers.
## Reports update the caption; only the final result answers the request.
progress_search : {} -> Elem(ctx)
progress_search = |_| Engine.state(
	{ sent: Engine.outbox({}), caption: "Not started" },
	|state| Html.div(
		"transfer",
		[
			Html.button("Download report", [], state.update(|s| { ..s, sent: s.sent.post({}), caption: "Starting…" })),
			Engine.on_post(
				state.signal().map(|s| s.sent),
				|_| [Engine.http_body({ url: "/api/report", cache: NoStore, credentials: Include, timeout: Ms(30000) })],
				state.on_result(
					|s, _, result| {
						..s,
						caption: match result {
							Ok(_) => "Report received"
							Err(error) => "Report failed: ${Str.inspect(error)}"
						},
					},
				).with_progress(
					{ every_ms: 250 },
					state.on_progress(
						|s, _, transfer| {
							..s,
							caption: match transfer.total {
								Known(total) => "Received ${transfer.done.to_str()} of ${total.to_str()} bytes"
								Unknown => "Received ${transfer.done.to_str()} bytes"
							},
						},
					),
				),
			),
			Html.p_s(state.signal().map(|s| s.caption), []),
		],
	),
)

# endregion progress

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
