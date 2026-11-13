import pf.Engine exposing [Elem, Signal]
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
## The page's state is the store `Explorer` describes: the question the
## controls show, the question asked of the shards, the live feed's switch
## and pace, and the live orders folded in. The controls and the sites
## below read its cells where they stand, and every change to them is one
## of `Explorer`'s decisions.
##
## Two sites do the work. A `Worker.gather` asks every shard the current
## question at once; its body adds the shards' last complete answer to the
## live orders the page has folded in and draws four charts from the sum.
## A `latest` site keeps the live feed's subscription while the feed is
## on, and folds each batch into a fixed-size tally. Everything else is
## ordinary view code. Two elements of the page's own JavaScript show what
## the runtime measured: `query-meter` (this example's `meter.mjs`) and
## `worker-pool-panel` (the shared pool panel).
ExplorerApp := [].{

	view : Explorer.Setup -> Elem(Engine.StoreRoot(_))
	view = |setup| {
		cells = Explorer.cells
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
				ExplorerApp.controls(setup.size),
				Worker.gather(
					Explorer.summary,
					cells.asked.signal().map(|asked| Explorer.questions(setup.size, asked)),
					|gathered| Engine.derive(Explorer.answering(setup.size).map2(gathered, Explorer.board), ExplorerApp.results),
				),
				Html.section(
					"Measured",
					"grid gap-3",
					[
						Engine.element("query-meter", [Engine.attr("data-task", Explorer.summary.name()), Engine.attr("data-port", Feed.ports.orders.name()), Engine.attr("data-shards", Explorer.shards.to_str())], []),
						Engine.element("worker-pool-panel", [], []),
					],
				),
				# A slider's question, asked when the timer fires: at most
				# every `sample_ms` while a slider is dragged.
				Engine.watch(
					Explorer.question({}).map(Explorer.sampling),
					|sampling| match sampling {
						Waiting => [Engine.timer(Explorer.sample_ms)]
						Asked => []
					},
					Engine.react_by(cells.shown.signal(), |shown, _, _| Explorer.sampled(shown)),
				),
				# The live feed, for as long as it is on and at the pace
				# chosen: a new pace or pausing stops the old subscription.
				Engine.watch_latest(
					{ flow: cells.flow.signal(), rate: cells.rate.signal() }.Signal,
					|{ flow, rate }| match flow {
						Live => [Feed.ports.orders.ask({ per_second: rate })]
						Paused => []
					},
					Engine.react(|_, res| Explorer.received(res)),
				),
			],
		)
	}

	## The question and the feed: the database's size, the categories, the
	## value range and the live feed's switch and pace.
	controls : U64 -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	controls = |size| {
		cells = Explorer.cells
		shown = cells.shown.signal()
		Html.section(
			"Question",
			"panel grid gap-3 p-4",
			[
				Html.div(
					"toolbar",
					[
						Html.p_attrs("${Explorer.grouped(size)} orders. Generate", [Engine.class("field-label"), Engine.test_id("size")]),
					]
						# Each size is a link: the page loads again at that size.
						.concat(Explorer.sizes.map(|other| Html.link(Explorer.grouped(other), "?orders=${other.to_str()}", [Engine.class("button button-sm")]))),
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
									Html.checkbox(Engine.const(name), shown.map(|filter| filter.categories.contains(category)), [], Engine.handle_by(shown, |at, checked| Explorer.ticked(at, category, checked))),
									Engine.text(name),
								],
							)
						},
					),
				),
				Html.div(
					"toolbar",
					[
						Html.p_s(shown.map(Explorer.range_text), [Engine.class("field-label numeric"), Engine.test_id("range")]),
						ExplorerApp.slider("Lowest value", shown.map(|filter| filter.lowest), Lowest),
						ExplorerApp.slider("Highest value", shown.map(|filter| filter.highest), Highest),
					],
				),
				Html.div(
					"toolbar",
					[
						Engine.element(
							"label",
							[Engine.class("flex items-center gap-1 text-sm")],
							[
								Html.checkbox(Engine.const("Live orders"), cells.flow.signal().map(|flow| flow == Live), [], Engine.handle(Explorer.switched)),
								Engine.text("Live orders"),
							],
						),
						Html.select(
							Engine.const("Live orders a second"),
							cells.rate.signal(),
							Engine.const(Explorer.rates),
							{ key: |rate| rate.to_str(), label: |rate| "${Explorer.grouped(rate.to_u64())} a second" },
							[Engine.class("input")],
							Engine.handle(Explorer.paced),
						),
						Html.p_s({ flow: cells.flow.signal(), rate: cells.rate.signal(), live: cells.live.signal() }.Signal.map(Explorer.live_text), [Engine.class("hint"), Engine.test_id("live")]),
					],
				),
				Html.p_s(cells.note.signal(), [Engine.class("hint"), Engine.test_id("note")]),
			],
		)
	}

	## A range slider over the value bins, showing `bin`. It asks on every
	## `input`, so a drag asks as it goes, and on `change`, which is what a
	## keyboard or a spec sends.
	slider : Str, Signal(ctx, U64), Explorer.End -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	slider = |name, bin, which| {
		moved = Engine.handle(|text| Explorer.slid(which, text))
		Html.text_input(
			Engine.const(name),
			"range",
			bin.map(|at| at.to_str()),
			[Engine.attr("min", "0"), Engine.attr("max", (Orders.bins - 1).to_str()), Engine.attr("step", "1"), Html.on_change(moved)],
			moved,
		)
	}

	## What the question found: the headline figures, each shard's state,
	## and the four charts.
	results : Signal(ctx, Explorer.Board) -> Elem(ctx)
	results = |b| Html.div(
		"grid gap-3",
		[
			Html.p_s(b.map(|board| board.status), [Engine.class("hint"), Engine.test_id("status")]),
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
							Html.p_s(b.map(|board| board.shards.get(i) ?? ""), [Engine.class("stat-value numeric"), Engine.test_id("shard-${(i + 1).to_str()}")]),
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

	stat : Signal(ctx, Explorer.Board), Str, Str, ({ orders : Str, revenue : Str, average : Str } -> Str) -> Elem(ctx)
	stat = |b, label, id, pick| Html.div(
		"stat",
		[
			Html.p(label, "stat-label"),
			Html.p_s(b.map(|board| pick(Explorer.headline(board.summary))), [Engine.class("stat-value numeric"), Engine.test_id(id)]),
		],
	)

	## A chart: a `plume-chart` element whose figure follows the board. Its
	## figure is rewritten only when it differs, so the live feed redraws
	## only the charts its orders change.
	chart : Signal(ctx, Explorer.Board), Str, (Explorer.Board -> Str) -> Elem(ctx)
	chart = |b, label, draw| Engine.element(
		"plume-chart",
		[Engine.class("box-content block panel"), Engine.attr("style", "height: 300px"), Engine.attr("role", "img"), Html.aria_label(label), Engine.attr_s("data-figure", b.map(draw))],
		[],
	)

	## The program `main.roc` binds for the browser module and the native
	## spec runner. The page passes `ports.mjs`'s handler for the feed.
	program : Engine.Program
	program =
		Engine.program_store(
			{ storage_keys: [], max_inflight: 32 },
			|boot| Explorer.start(Explorer.setup_of(boot.url)),
			|boot| ExplorerApp.view(Explorer.setup_of(boot.url)),
		)
			.with_workers([Explorer.shard.registration([Explorer.summary.registration()])])
			.with_ports(Feed.registrations)
}
