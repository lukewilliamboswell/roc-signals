import pf.Engine exposing [Comp, Elem, In, Root, State, Val]
import pf.Html

## Supersession test app: the two explicit effect-site policies, each with
## specs in `specs/` run natively and in Chrome.
## - A search box whose `latest` site keeps only the newest query's request
##   (clearing the query is a pure cancel), and a ticker whose `latest` site
##   swaps one interval subscription for another.
## - An item view whose `resource` layer shows the request it is waiting for
##   in the turn that changes the item, keeps the previous answer, and marks
##   a slow answer with a timer whose late tick is an equal fold.
## - The same `resource` in each row of an `each` (reloaded through a
##   row-local `state`) and inside a component that a `when` opens and
##   closes, so its answers settle locally and its disposal is observable.
SupersedeApp := [].{
	S : {
		query : Str,
		results : Str,
		rate : U32,
		ticks : U64,
		item : Str,
		rows : List(Str),
		panel : Bool,
		picked : Str,
	}

	Ctx : In(Root, S)

	## An item's asynchronous view: the item being fetched (empty when none
	## is), the last answer and the one before it, and whether the request
	## has taken longer than its slow-answer timer.
	Load : { pending : Str, answer : Str, previous : Str, slow : Bool }

	idle : Load
	idle = { pending: "", answer: "none", previous: "none", slow: False }

	initial : S
	initial = { query: "", results: "", rate: 0, ticks: 0, item: "", rows: [], panel: False, picked: "1" }

	answer_of : Str, Engine.Res -> Str
	answer_of = |id, res| match Engine.http_text(res) {
		Ok(body) => "${id}:${body}"
		Err(e) => "${id}:${Str.inspect(e)}"
	}

	## The resource configuration every item view uses: a request and a 2 s
	## slow-answer timer per item. The timer's tick after the answer changes
	## nothing, so its fold returns the layer unchanged and readers prune.
	item_cfg : { init : Load, begin : (Load, Str -> Load), plan : (Str -> List(Engine.Req)), fold : (Load, Str, Engine.Res -> Load) }
	item_cfg = {
		init: SupersedeApp.idle,
		begin: |s, id| { ..s, pending: id, slow: False },
		plan: |id| if (id == "") [] else [Http({ method: "GET", url: "/item/${id}", headers: [], body: "", timeout_ms: 1000 }), Timer(2000)],
		fold: |s, id, res| match res {
			Fired => if (s.pending == "") s else { ..s, slow: True }
			_ => { pending: "", answer: SupersedeApp.answer_of(id, res), previous: s.answer, slow: False }
		},
	}

	show : Load -> Str
	show = |l| {
		head = if (l.pending == "") "ready" else "loading ${l.pending}"
		slow = if (l.slow) " (slow)" else ""
		"${head}${slow}; showing ${l.answer}; before ${l.previous}"
	}

	item_view : Val(ctx, Str), Str -> Elem(ctx)
	item_view = |item, id| Engine.resource(item, SupersedeApp.item_cfg, |l| Html.p_v(l.map(SupersedeApp.show), [Engine.test_id(id)]))

	## The component's body: the prop is the picked item.
	panel : Val(Comp(Str, {}), Str) -> Elem(Comp(Str, {}))
	panel = |picked| Engine.element("div", [], [SupersedeApp.item_view(picked, "panel")])

	## One row: a reload counter and the row's resource over (key, version).
	row_view : Val(In(Engine.Row(Ctx, Str), U64), Str), State(In(Engine.Row(Ctx, Str), U64), U64) -> Elem(In(Engine.Row(Ctx, Str), U64))
	row_view = |key, ver| Engine.element(
		"span",
		[],
		[
			Engine.element("button", [Html.aria_label_v(key.map(|k| "Reload ${k}")), Engine.on_click(ver.update(|v| v + 1))], [Engine.text("Reload")]),
			Engine.resource(
				key.map2(ver.val(), |k, v| (k, v)),
				{
					init: "",
					begin: |_, (k, v)| "loading ${k}/${v.to_str()}",
					plan: |(k, v)| [Http({ method: "GET", url: "/row/${k}/${v.to_str()}", headers: [], body: "", timeout_ms: 0 })],
					fold: |_, (k, v), res| SupersedeApp.answer_of("${k}/${v.to_str()}", res),
				},
				|l| Html.span_v(l, [Engine.test_id_v(key.lift().map(|k| "row ${k}"))]),
			),
		],
	)

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"supersede",
			[
				# Latest wins: one search request at a time.
				Html.button("Search A", [], st.update(|s| { ..s, query: "a" })),
				Html.button("Search B", [], st.update(|s| { ..s, query: "b" })),
				Html.button("Clear", [], st.update(|s| { ..s, query: "" })),
				Engine.latest(
					v.map(|s| s.query),
					|q| if (q == "") [] else [Http({ method: "GET", url: "/search?q=${q}", headers: [], body: "", timeout_ms: 1000 })],
					st.on_result(|s, q, r| { ..s, results: SupersedeApp.answer_of(q, r) }),
				),
				Html.p_v(v.map(|s| s.results), [Engine.test_id("results")]),
				# Latest wins for a subscription: one ticker interval at a time.
				Html.button("Fast", [], st.update(|s| { ..s, rate: 100 })),
				Html.button("Slow", [], st.update(|s| { ..s, rate: 1000 })),
				Html.button("Pause", [], st.update(|s| { ..s, rate: 0 })),
				Engine.latest(
					v.map(|s| s.rate),
					|r| if (r == 0) [] else [Interval(r)],
					st.on_result(|s, _, _| { ..s, ticks: s.ticks + 1 }),
				),
				Html.p_v(v.map(|s| s.ticks.to_str()), [Engine.test_id("ticks")]),
				# An asynchronous layer at the top level.
				Html.button("Item 1", [], st.update(|s| { ..s, item: "1" })),
				Html.button("Item 2", [], st.update(|s| { ..s, item: "2" })),
				Html.button("No item", [], st.update(|s| { ..s, item: "" })),
				SupersedeApp.item_view(v.map(|s| s.item), "item"),
				# The same layer in each row, reloaded by a row-local state.
				Html.button("Load rows", [], st.update(|s| { ..s, rows: ["a", "b"] })),
				Html.button("Drop a", [], st.update(|s| { ..s, rows: s.rows.drop_if(|k| k == "a") })),
				Html.ul(
					[],
					[
						Engine.each(
							v.map(|s| s.rows),
							|k| k,
							|row| Html.li([], [Engine.state(0.U64, |ver| SupersedeApp.row_view(row.key().lift(), ver))]),
						),
					],
				),
				# The same layer inside a component that a branch owns.
				Html.button("Open panel", [], st.update(|s| { ..s, panel: True })),
				Html.button("Close panel", [], st.update(|s| { ..s, panel: False })),
				Html.button("Pick 1", [], st.update(|s| { ..s, picked: "1" })),
				Html.button("Pick 2", [], st.update(|s| { ..s, picked: "2" })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.component(v.map(|s| s.picked), Engine.discard({}), |picked, _| SupersedeApp.panel(picked)),
					|| Engine.text(""),
				),
			],
		)
	}

	## The program both hosts run.
	program : Engine.Program
	program = Engine.program(|| Engine.state(SupersedeApp.initial, |st| SupersedeApp.view(st)))
}
