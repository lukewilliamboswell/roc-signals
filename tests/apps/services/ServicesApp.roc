import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Browser-services test app: one control per Phase 3 service, each with a
## spec in `specs/` run natively and in Chrome.
## - A running clock (`when`) owns a 1 s interval and a named cleanup whose
##   run sets the document title.
## - While the page is visible a 5 s poll interval is live; connectivity and
##   visibility are shown from boot and kept current by subscriptions, and
##   whether local storage is available is shown from boot.
## - A radio group, a checkbox and a button that logs mouse and focus events
##   (real clicks); a form whose submit counts; two selects, one with
##   options mounted by an `each`; and a fetch whose result is shown as text
##   or as its inspected `Engine.HttpError`.
## - A text box that trims what is typed into it: its rewritten value waits
##   for blur while it has focus (controlled inputs).
ServicesApp := [].{
	S : {
		online : Bool,
		visible : Bool,
		storage_available : Bool,
		running : Bool,
		ticks : U64,
		polls : U64,
		size : Str,
		agree : Bool,
		presses : List(Str),
		submitted : U64,
		note : Str,
		fruit : Str,
		shade : Str,
		fetches : U64,
		fetched : Str,
		trimmed : Str,
	}

	Ctx : In(Root, S)

	initial : Engine.Boot -> S
	initial = |boot| {
		online: boot.online,
		visible: boot.visible,
		storage_available: boot.storage_available,
		running: False,
		ticks: 0,
		polls: 0,
		size: "s",
		agree: False,
		presses: [],
		submitted: 0,
		note: "",
		fruit: "apple",
		shade: "teal",
		fetches: 0,
		fetched: "",
		trimmed: "",
	}

	press : State(Ctx, S), Str -> Engine.Attr(Ctx)
	press = |st, ev| Engine.on(ev, st.update(|s| { ..s, presses: s.presses.append(ev) }))

	shown : Engine.Res -> Str
	shown = |r| match Engine.http_text(r) {
		Ok(body) => "ok:${body}"
		Err(e) => Str.inspect(e)
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"services",
			[
				Engine.watch(
					Engine.const({}),
					|_| [OnlineChanges],
					st.on_result(
						|s, _, r| match r {
							Online(on) => { ..s, online: on }
							_ => s
						},
					),
				),
				Engine.watch(
					Engine.const({}),
					|_| [VisibilityChanges],
					st.on_result(
						|s, _, r| match r {
							Visible(vis) => { ..s, visible: vis }
							_ => s
						},
					),
				),
				Html.p_v(v.map(|s| if (s.online) "online" else "offline"), [Engine.test_id("online")]),
				Html.p_v(v.map(|s| if (s.visible) "visible" else "hidden"), [Engine.test_id("visible")]),
				Html.p_v(v.map(|s| if (s.storage_available) "storage available" else "storage unavailable"), [Engine.test_id("storage")]),
				Engine.when(
					v.map(|s| s.visible),
					|| Engine.element("span", [], [Engine.watch(Engine.const({}), |_| [Interval(5000)], st.on_result(|s, _, _| { ..s, polls: s.polls + 1 }))]),
					|| Engine.text(""),
				),
				Html.p_v(v.map(|s| s.polls.to_str()), [Engine.test_id("polls")]),
				# The clock
				Html.button("Start", [], st.update(|s| { ..s, running: True })),
				Html.button("Stop", [], st.update(|s| { ..s, running: False })),
				Engine.when(
					v.map(|s| s.running),
					|| Engine.element(
						"span",
						[Engine.test_id("clock")],
						[
							Engine.watch(Engine.const({}), |_| [Interval(1000)], st.on_result(|s, _, _| { ..s, ticks: s.ticks + 1 })),
							Engine.on_cleanup("clock cleanup", v.map(|s| s.ticks), |t| [Title("stopped at ${t.to_str()}")]),
							Engine.text("running"),
						],
					),
					|| Engine.text(""),
				),
				Html.p_v(v.map(|s| s.ticks.to_str()), [Engine.test_id("ticks")]),
				# Real clicks
				Html.radio("Small", "size", "s", v.map(|s| s.size), [], st.update(|s| { ..s, size: "s" })),
				Html.radio("Medium", "size", "m", v.map(|s| s.size), [], st.update(|s| { ..s, size: "m" })),
				Html.p_v(v.map(|s| s.size), [Engine.test_id("size")]),
				Html.checkbox(Engine.const("Agree"), v.map(|s| s.agree), [], st.set_value(|s, p| { ..s, agree: p == "true" })),
				Engine.element("button", [Html.aria_label("Press"), ServicesApp.press(st, "focus"), ServicesApp.press(st, "mousedown"), ServicesApp.press(st, "mouseup"), ServicesApp.press(st, "click")], [Engine.text("Press")]),
				Html.p_v(v.map(|s| Str.join_with(s.presses, ",")), [Engine.test_id("presses")]),
				# A form
				Html.form(
					"Order",
					[Html.on_submit(st.update(|s| { ..s, submitted: s.submitted + 1 }))],
					[
						Html.text_input(Engine.const("Note"), "text", v.map(|s| s.note), [], st.set_value(|s, t| { ..s, note: t })),
						Html.submit_button("Place order", []),
					],
				),
				Html.p_v(v.map(|s| s.submitted.to_str()), [Engine.test_id("submitted")]),
				# Selects: static options, and options an `each` mounts after
				# the select's value is set.
				Html.select(Engine.const("Fruit"), v.map(|s| s.fruit), [], [Html.option("apple", "Apple"), Html.option("pear", "Pear")], st.set_value(|s, f| { ..s, fruit: f })),
				Html.p_v(v.map(|s| s.fruit), [Engine.test_id("fruit")]),
				Html.select(
					Engine.const("Shade"),
					v.map(|s| s.shade),
					[],
					[Engine.each(Engine.const(["amber", "teal", "plum"]), |k| k, |row| Engine.element("option", [Engine.attr_v("value", row.key())], [Engine.text_v(row.key())]))],
					st.set_value(|s, c| { ..s, shade: c }),
				),
				# HTTP results as typed errors
				Html.button("Fetch", [], st.update(|s| { ..s, fetches: s.fetches + 1 })),
				Engine.on_change(
					v.map(|s| s.fetches),
					|n| [Http({ method: "GET", url: "/api/item/${n.to_str()}", headers: [], body: "", timeout_ms: 100 })],
					st.on_result(|s, _, r| { ..s, fetched: ServicesApp.shown(r) }),
				),
				Html.p_v(v.map(|s| s.fetched), [Engine.test_id("fetched")]),
				# A controlled input whose value the app rewrites (trimmed):
				# the rewrite waits for blur while the control has focus.
				Html.text_input(Engine.const("Trimmed"), "text", v.map(|s| s.trimmed), [], st.set_value(|s, t| { ..s, trimmed: t.trim() })),
				Html.p_v(v.map(|s| s.trimmed), [Engine.test_id("trimmed")]),
			],
		)
	}

	## The program both hosts run.
	program : Engine.Program(Engine.App)
	program = Engine.program_boot(
		{ storage_keys: [], max_inflight: 8 },
		|boot|
			if boot.url.ends_with("#limit-children") {
				ServicesApp.too_wide({})
			} else {
				Engine.state(ServicesApp.initial(boot), |st| ServicesApp.view(st))
			},
	)

	## A row template whose element has 256 children, one more than the
	## template encoding's one-byte count: mounting it is a resource limit
	## (the runtime contract test boots this view by its URL).
	too_wide : {} -> Elem(Root)
	too_wide = |_| Engine.each(
		Engine.const(["only"]),
		|k| k,
		|_| Engine.element("ul", [], List.repeat(Engine.element("li", [], []), 256)),
	)
}
