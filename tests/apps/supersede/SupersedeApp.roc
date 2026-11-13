import pf.Engine exposing [Elem, In, Root, Signal, State]
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
##   row-local `state`) and inside a panel that a `when` opens and closes,
##   so its disposal is observable.
## - A flood: 100 rows that each fetch at mount, far past the in-flight
##   bound of 32, so one turn queues 68 refusals; each reaction counts its
##   answer at the top level.
## - A deluge, offered only at the address `/?offers=deluge`: 5000 rows
##   that each fetch at mount, so one turn queues thousands of refusals,
##   more follow-up turns than the breadth bound allows one call. The bound
##   counts only the follow-ups that follow-ups queue, so the turn
##   completes. The rows and the tally of their answers are two local
##   states of the deluge's own, so a refusal's turn writes the tally and
##   never reads the list.
## - A `state` below a `derive` and below a `resource`, mounted with the
##   page, and layers that exist only in a branch mounted after the first
##   (two `when`s that start closed, a `switch` that starts on a plain case, and a `when`
##   inside that branch): a `state`, a `state` below a `derive` and below a
##   `resource`, the `resource`'s own answers, and two states nested two
##   deep. Writes to them, outside any row, must still reach their
##   readers.
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
		solo : Bool,
		late : Bool,
		inner : Bool,
		case : Str,
		flood : List(Str),
		refused : U64,
		answered : U64,
	}

	Ctx : In(Root, S)

	## An item's asynchronous view: the item being fetched (empty when none
	## is), the last answer and the one before it, and whether the request
	## has taken longer than its slow-answer timer.
	Load : { pending : Str, answer : Str, previous : Str, slow : Bool }

	idle : Load
	idle = { pending: "", answer: "none", previous: "none", slow: False }

	initial : S
	initial = { query: "", results: "", rate: 0, ticks: 0, item: "", rows: [], panel: False, picked: "1", solo: False, late: False, inner: False, case: "plain", flood: [], refused: 0, answered: 0 }

	answer_of : Str, Engine.Result -> Str
	answer_of = |id, res| match Engine.http_text(res) {
		Ok(body) => "${id}:${body}"
		Err(e) => "${id}:${Str.inspect(e)}"
	}

	## The resource configuration every item view uses: a request and a 2 s
	## slow-answer timer per item. The timer's tick after the answer changes
	## nothing, so its fold returns the layer unchanged and readers prune.
	item_cfg : { init : Load, pending : (Load, Str -> Load), plan : (Str -> List(Engine.Request)), resolve : (Load, Str, Engine.Result -> Load) }
	item_cfg = {
		init: SupersedeApp.idle,
		pending: |s, id| { ..s, pending: id, slow: False },
		plan: |id| if (id == "") [] else [Engine.http({ url: "/item/${id}", timeout: Ms(1000) }), Timer(2000)],
		resolve: |s, id, res| match res {
			Fired(_) => if (s.pending == "") s else { ..s, slow: True }
			_ => { pending: "", answer: SupersedeApp.answer_of(id, res), previous: s.answer, slow: False }
		},
	}

	show : Load -> Str
	show = |l| {
		head = if (l.pending == "") "ready" else "loading ${l.pending}"
		slow = if (l.slow) " (slow)" else ""
		"${head}${slow}; showing ${l.answer}; before ${l.previous}"
	}

	item_view : Signal(ctx, Str), Str -> Elem(ctx)
	item_view = |item, id| Engine.resource(item, SupersedeApp.item_cfg, |l| Html.p_s(l.map(SupersedeApp.show), [Engine.test_id(id)]))

	## The panel: the picked item's view.
	panel : Signal(ctx, Str) -> Elem(ctx)
	panel = |picked| Engine.element("div", [], [SupersedeApp.item_view(picked, "panel")])

	## One row: a reload counter and the row's resource over (key, version).
	row_view : Signal(In(Engine.Row(Ctx, Str), U64), Str), State(In(Engine.Row(Ctx, Str), U64), U64) -> Elem(In(Engine.Row(Ctx, Str), U64))
	row_view = |key, ver| Engine.element(
		"span",
		[],
		[
			Engine.element("button", [Html.aria_label_s(key.map(|k| "Reload ${k}")), Engine.on_click(ver.update(|v| v + 1))], [Engine.text("Reload")]),
			Engine.resource(
				key.map2(ver.signal(), |k, v| (k, v)),
				{
					init: "",
					pending: |_, (k, v)| "loading ${k}/${v.to_str()}",
					plan: |(k, v)| [Engine.http({ url: "/row/${k}/${v.to_str()}" })],
					resolve: |_, (k, v), res| SupersedeApp.answer_of("${k}/${v.to_str()}", res),
				},
				|l| Html.span_s(l, [Engine.test_id_s(key.lift().map(|k| "row ${k}"))]),
			),
		],
	)

	## A counter state with its button and its text, for the late branches.
	counter : Str -> Elem(ctx)
	counter = |name| Engine.state(
		0.U64,
		|c| Engine.element(
			"span",
			[],
			[
				Html.button("Inc ${name}", [], c.update(|n| n + 1)),
				Html.p_s(c.signal().map(|n| "${name} ${n.to_str()}"), [Engine.test_id(name)]),
			],
		),
	)

	## The only content of the branch the "solo" `when` mounts second: a
	## state, its text and an effect site reading it.
	solo_branch : {} -> Elem(Ctx)
	solo_branch = |_| Engine.state(
		0.U64,
		|c| Engine.element(
			"span",
			[],
			[
				Html.button("Inc late", [], c.update(|n| n + 1)),
				Html.p_s(c.signal().map(|n| "late ${n.to_str()}"), [Engine.test_id("late")]),
				Engine.watch_changes(c.signal(), |n| [Title("late ${n.to_str()}")], Engine.ignore({})),
			],
		),
	)

	## The branch the "late" `when` mounts second: every layer here is created
	## after the `when` reported its reads.
	late_branch : State(Ctx, S) -> Elem(Ctx)
	late_branch = |st| Engine.element(
		"div",
		[],
		[
			Engine.derive(Engine.const(2.U64), |_| SupersedeApp.counter("derived")),
			Engine.resource(
				Engine.const("r"),
				{ init: 0.U64, pending: |n, _| n, plan: |_| [Timer(50)], resolve: |n, _, _| n + 1 },
				|l| Engine.element(
					"div",
					[],
					[
						Html.p_s(l.map(|n| "answers ${n.to_str()}"), [Engine.test_id("answers")]),
						SupersedeApp.counter("below resource"),
					],
				),
			),
			Html.button("Toggle inner", [], st.update(|s| { ..s, inner: !s.inner })),
			Engine.when(
				st.signal().map(|s| s.inner),
				|| Engine.state(
					0.U64,
					|a| Engine.state(
						0.U64,
						|b| Engine.element(
							"span",
							[],
							[
								Html.button("Inc outer", [], a.lift().update(|n| n + 1)),
								Html.button("Inc inner", [], b.update(|n| n + 1)),
								Html.p_s(a.signal().lift().map2(b.signal(), |x, y| "nested ${x.to_str()}/${y.to_str()}"), [Engine.test_id("nested")]),
							],
						),
					),
				),
				|| Engine.text("inner closed"),
			),
		],
	)

	## `n` row keys, built at run time.
	flood_keys : U64 -> List(Str)
	flood_keys = |n| {
		var $keys = []
		var $k = 0.U64
		while $k < n {
			$keys = $keys.append("f${$k.to_str()}")
			$k = $k + 1
		}
		$keys
	}

	## What the page offers, chosen by the address it boots at. The deluge is
	## offered at `/?offers=deluge` alone: once its 5000 rows are drawn, every
	## later step of a walk would check 5000 rows, and a walk mounts at `/`.
	Offer : [Standard, WithDeluge]

	offer_at : Str -> Offer
	offer_at = |url| if (url == "/?offers=deluge") WithDeluge else Standard

	## How many rows a deluge draws: with 32 requests admitted, more refusals
	## than the breadth bound's 4096 follow-up turns.
	deluge_size : U64
	deluge_size = 5000

	## The deluge: its rows' keys in one local state and, below it, the
	## tally of their answers in another, which each row's reaction writes.
	deluge : {} -> Elem(Ctx)
	deluge = |_| Engine.state(
		[],
		|keys| Engine.state(
			{ refused: 0.U64, answered: 0.U64 },
			|tally| Engine.element(
				"div",
				[],
				[
					Html.button("Deluge", [], keys.lift().update(|_| SupersedeApp.flood_keys(SupersedeApp.deluge_size))),
					Html.p_s(tally.signal().map(|t| "refused ${t.refused.to_str()}, answered ${t.answered.to_str()}"), [Engine.test_id("deluge")]),
					Html.ul(
						[],
						[
							Engine.each(
								keys.signal().lift(),
								|k| k,
								|row| Html.li(
									[],
									[
										Engine.watch(
											row.key(),
											|k| [Engine.http({ url: "/deluge/${k}" })],
											tally.lift_row().on_result(
												|t, _, r| match r {
													Refused => { ..t, refused: t.refused + 1 }
													_ => { ..t, answered: t.answered + 1 }
												},
											),
										),
										Engine.text_s(row.key()),
									],
								),
							),
						],
					),
				],
			),
		),
	)

	view : State(Ctx, S), Offer -> Elem(Ctx)
	view = |st, offer| {
		v = st.signal()
		Html.div(
			"supersede",
			[
				# Latest wins: one search request at a time.
				Html.button("Search A", [], st.update(|s| { ..s, query: "a" })),
				Html.button("Search B", [], st.update(|s| { ..s, query: "b" })),
				Html.button("Clear", [], st.update(|s| { ..s, query: "" })),
				Engine.watch_latest(
					v.map(|s| s.query),
					|q| if (q == "") [] else [Engine.http({ url: "/search?q=${q}", timeout: Ms(1000) })],
					st.on_result(|s, q, r| { ..s, results: SupersedeApp.answer_of(q, r) }),
				),
				Html.p_s(v.map(|s| s.results), [Engine.test_id("results")]),
				# Latest wins for a subscription: one ticker interval at a time.
				Html.button("Fast", [], st.update(|s| { ..s, rate: 100 })),
				Html.button("Slow", [], st.update(|s| { ..s, rate: 1000 })),
				Html.button("Pause", [], st.update(|s| { ..s, rate: 0 })),
				Engine.watch_latest(
					v.map(|s| s.rate),
					|r| if (r == 0) [] else [Interval(r)],
					st.on_result(|s, _, _| { ..s, ticks: s.ticks + 1 }),
				),
				Html.p_s(v.map(|s| s.ticks.to_str()), [Engine.test_id("ticks")]),
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
				# The same layer inside a panel that a branch owns.
				Html.button("Open panel", [], st.update(|s| { ..s, panel: True })),
				Html.button("Close panel", [], st.update(|s| { ..s, panel: False })),
				Html.button("Pick 1", [], st.update(|s| { ..s, picked: "1" })),
				Html.button("Pick 2", [], st.update(|s| { ..s, picked: "2" })),
				# A state below a derive and below a resource, mounted with the page.
				Engine.derive(Engine.const(1.U64), |_| SupersedeApp.counter("early derived")),
				Engine.resource(Engine.const("e"), { init: 0.U64, pending: |n, _| n, plan: |_| [], resolve: |n, _, _| n }, |_| SupersedeApp.counter("early resource")),
				# Layers mounted only in a later branch.
				# A flood of rows fetching at mount.
				Html.button("Flood", [], st.update(|s| { ..s, flood: SupersedeApp.flood_keys(100) })),
				Html.p_s(v.map(|s| "refused ${s.refused.to_str()}, answered ${s.answered.to_str()}"), [Engine.test_id("flood")]),
				Html.ul(
					[],
					[
						Engine.each(
							v.map(|s| s.flood),
							|k| k,
							|row| Html.li(
								[],
								[
									Engine.watch(
										row.key(),
										|k| [Engine.http({ url: "/flood/${k}" })],
										st.lift_row().on_result(
											|s, _, r| match r {
												Refused => { ..s, refused: s.refused + 1 }
												_ => { ..s, answered: s.answered + 1 }
											},
										),
									),
									Engine.text_s(row.key()),
								],
							),
						),
					],
				),
				match offer {
					WithDeluge => SupersedeApp.deluge({})
					Standard => Engine.text("")
				},
				Html.button("Toggle solo", [], st.update(|s| { ..s, solo: !s.solo })),
				Engine.when(v.map(|s| s.solo), || SupersedeApp.solo_branch({}), || Engine.text("solo closed")),
				Html.button("Toggle late", [], st.update(|s| { ..s, late: !s.late })),
				Engine.when(v.map(|s| s.late), || SupersedeApp.late_branch(st), || Engine.text("late closed")),
				Html.button("Counting case", [], st.update(|s| { ..s, case: "counting" })),
				Engine.switch(
					v.map(|s| s.case),
					["plain", "counting"],
					|k| if (k == "plain") Engine.text("plain case") else SupersedeApp.counter("case"),
				),
				Engine.when(
					v.map(|s| s.panel),
					|| SupersedeApp.panel(v.map(|s| s.picked)),
					|| Engine.text(""),
				),
			],
		)
	}

	## The program both hosts run.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [], max_inflight: 32 }, |boot| Engine.state(SupersedeApp.initial, |st| SupersedeApp.view(st, SupersedeApp.offer_at(boot.url))))
}
