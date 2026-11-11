import pf.Engine exposing [Elem, In, Root, State, Val]
import pf.Html
import pf.Worker
import Charts
import Explorer
import Feed
import Orders

## Million-Row Explorer: a year of a shop's orders, two million of them by
## default, split into four shards that live in four workers, with live
## orders arriving through a port.
##
## Two sites do the work. A `Worker.gather` asks every shard the current
## question at once; its body adds the shards' last complete answer to the
## live orders the page has folded in (`v.lift().map2`) and draws four
## charts from the sum. A `latest` site keeps the live feed's subscription
## while the feed is on, and folds each batch into a fixed-size tally.
## Everything else is ordinary view code. Two elements of the page's own
## JavaScript show what the runtime measured: `query-meter` (this
## example's `meter.mjs`) and `worker-pool-panel` (the shared pool panel).
ExplorerApp := [].{
	Ctx : In(Root, Explorer.S)

	view : State(Ctx, Explorer.S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"app-shell",
			[
				Html.section(
					"Million-Row Explorer",
					"app-header",
					[
						Html.h1("Million-Row Explorer", "app-title"),
						Html.p("A year of a shop's orders, generated inside four workers and never sent to the page. Every change of the question asks each worker for a few kilobytes of counts; the page adds them to the live orders arriving now and draws the charts.", "app-subtitle"),
					],
				),
				ExplorerApp.controls(st),
				Worker.gather(
					Explorer.summary,
					v.map(Explorer.questions),
					|g| Engine.derive(v.lift().map2(g, Explorer.board), ExplorerApp.results),
				),
				Html.section(
					"Measured",
					"grid gap-3",
					[
						Engine.element("query-meter", [Engine.attr("data-task", Explorer.summary.name()), Engine.attr("data-port", Feed.name), Engine.attr("data-shards", Explorer.shards.to_str())], []),
						Engine.element("worker-pool-panel", [], []),
					],
				),
				# A slider's question, asked when the timer fires: at most
				# every `sample_ms` while a slider is dragged.
				Engine.watch(
					v.map(Explorer.sampling),
					|sampling| match sampling {
						Waiting => [Timer(Explorer.sample_ms)]
						Asked => []
					},
					st.on_result(|s, _, _| Explorer.asking(s)),
				),
				# The live feed, for as long as it is on and at the pace
				# chosen: a new pace or pausing stops the old subscription.
				Engine.latest(
					v.map(|s| { flow: s.flow, rate: s.rate }),
					|{ flow, rate }| match flow {
						Live => [Feed.orders.subscribe({ per_second: rate })]
						Paused => []
					},
					st.on_result(|s, _, res| Explorer.received(s, Feed.orders.message(res))),
				),
			],
		)
	}

	## The question and the feed: the database's size, the categories, the
	## value range and the live feed's switch and pace.
	controls : State(Ctx, Explorer.S) -> Elem(Ctx)
	controls = |st| {
		v = st.val()
		Html.section(
			"Question",
			"panel grid gap-3 p-4",
			[
				Html.div(
					"toolbar",
					[
						Html.p_v(v.map(|s| "${Explorer.grouped(s.size)} orders. Generate"), [Engine.class("field-label"), Engine.test_id("size")]),
					]
						# Each size is a link: the page loads again at that size.
						.concat(Explorer.sizes.map(|size| Html.link(Explorer.grouped(size), "?orders=${size.to_str()}", [Engine.class("button button-sm")]))),
				),
				Html.div(
					"toolbar",
					Orders.categories.map(
						|category| {
							name = Orders.category_name(category)
							Engine.element(
								"label",
								[Engine.class("flex items-center gap-1 text-sm")],
								[
									Html.checkbox(Engine.const(name), v.map(|s| s.categories.contains(category)), [], st.set_value(|s, checked| Explorer.toggled(s, category, checked))),
									Engine.text(name),
								],
							)
						},
					),
				),
				Html.div(
					"toolbar",
					[
						Html.p_v(v.map(Explorer.range_text), [Engine.class("field-label numeric"), Engine.test_id("range")]),
						ExplorerApp.slider(st, "Lowest value", |s| s.lowest, Explorer.lowest_set),
						ExplorerApp.slider(st, "Highest value", |s| s.highest, Explorer.highest_set),
					],
				),
				Html.div(
					"toolbar",
					[
						Engine.element(
							"label",
							[Engine.class("flex items-center gap-1 text-sm")],
							[
								Html.checkbox(Engine.const("Live orders"), v.map(|s| s.flow == Live), [], st.set_value(Explorer.flowing)),
								Engine.text("Live orders"),
							],
						),
						Html.select(
							Engine.const("Live orders a second"),
							v.map(|s| s.rate.to_str()),
							[Engine.class("input")],
							Explorer.rates.map(|rate| Html.option(rate.to_str(), "${Explorer.grouped(rate.to_u64())} a second")),
							st.set_value(Explorer.paced),
						),
						Html.p_v(v.map(Explorer.live_text), [Engine.class("hint"), Engine.test_id("live")]),
					],
				),
				Html.p_v(v.map(|s| s.note), [Engine.class("hint"), Engine.test_id("note")]),
			],
		)
	}

	## A range slider over the value bins. It asks on every `input`, so a
	## drag asks as it goes, and on `change`, which is what a keyboard or a
	## spec sends.
	slider : State(Ctx, Explorer.S), Str, (Explorer.S -> U64), (Explorer.S, Str -> Explorer.S) -> Elem(Ctx)
	slider = |st, name, read, set| {
		handler = st.set_value(set)
		Html.text_input(
			Engine.const(name),
			"range",
			st.val().map(|s| read(s).to_str()),
			[Engine.attr("min", "0"), Engine.attr("max", (Orders.bins - 1).to_str()), Engine.attr("step", "1"), Html.on_change(handler)],
			handler,
		)
	}

	## What the question found: the headline figures, each shard's state,
	## and the four charts.
	results : Val(ctx, Explorer.Board) -> Elem(ctx)
	results = |b| Html.div(
		"grid gap-3",
		[
			Html.p_v(b.map(|board| board.status), [Engine.class("hint"), Engine.test_id("status")]),
			Html.div(
				"stat-grid",
				[
					ExplorerApp.stat(b, "Orders", "orders", |h| h.orders),
					ExplorerApp.stat(b, "Revenue", "revenue", |h| h.revenue),
					ExplorerApp.stat(b, "Average order", "average", |h| h.average),
				],
			),
			Html.div(
				"stat-grid",
				List.from_iter((0.U64..<Explorer.shards).iter()).map(
					|i| Html.div(
						"stat",
						[
							Html.p("Shard ${(i + 1).to_str()}", "stat-label"),
							Html.p_v(b.map(|board| board.shards.get(i) ?? ""), [Engine.class("stat-value numeric"), Engine.test_id("shard-${(i + 1).to_str()}")]),
						],
					),
				),
			),
			Html.div(
				"grid gap-3 lg:grid-cols-2",
				[
					ExplorerApp.chart(b, "Orders per day", |board| Charts.per_day(board.summary)),
					ExplorerApp.chart(b, "Order values", |board| Charts.values(board.summary, board.filter)),
					ExplorerApp.chart(b, "Revenue by category", |board| Charts.categories(board.summary)),
					ExplorerApp.chart(b, "Top regions by revenue", |board| Charts.regions(board.summary)),
				],
			),
		],
	)

	stat : Val(ctx, Explorer.Board), Str, Str, ({ orders : Str, revenue : Str, average : Str } -> Str) -> Elem(ctx)
	stat = |b, label, id, pick| Html.div(
		"stat",
		[
			Html.p(label, "stat-label"),
			Html.p_v(b.map(|board| pick(Explorer.headline(board.summary))), [Engine.class("stat-value numeric"), Engine.test_id(id)]),
		],
	)

	## A chart: a `plume-chart` element whose figure follows the board. Its
	## figure is rewritten only when it differs, so the live feed redraws
	## only the charts its orders change.
	chart : Val(ctx, Explorer.Board), Str, (Explorer.Board -> Str) -> Elem(ctx)
	chart = |b, label, draw| Engine.element(
		"plume-chart",
		[Engine.class("block panel"), Engine.attr("style", "height: 300px"), Engine.attr("role", "img"), Html.aria_label(label), Engine.attr_v("data-figure", b.map(draw))],
		[],
	)

	## The program `main.roc` binds for the browser module and the native
	## spec runner. The page passes `ports.mjs`'s handler for the feed.
	program : Engine.Program
	program =
		Engine.program_boot({ storage_keys: [], max_inflight: 32 }, |boot| Engine.state(Explorer.starting(boot.url), ExplorerApp.view))
			.with_workers([Explorer.shard.registration([Explorer.summary.registration()])])
			.with_ports(Feed.registrations)
}
