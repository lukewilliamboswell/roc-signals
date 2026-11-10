import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import plume.Axis
import plume.Bar
import plume.Chart
import plume.Color
import plume.Coordinate
import plume.Layout
import plume.Title
import Status

## Status Page on the Roc-owned engine: ported from the previous engine.
## Four independent service checks fan in to one rollup.
##
## Each refresh issues one HTTP check per service plus the incident feed.
## Refreshes are numbered (`serial`): the mount is refresh 0, and every
## interval tick, "Refresh now" click and return to visibility starts the
## next. A result applies only while its refresh is still the latest, so a
## late answer to a superseded refresh is ignored. The 5 s interval lives
## inside the visible branch, so hiding the page disposes it; requests
## already admitted stay in flight.
##
## The four checks collapse into one `Tally` (a memoised `derive`), and the
## banner, the metrics and the counts are read from that one value, so the
## page can never show "All systems operational" beside a red component.
## The incident feed is a fifth result rendered as a timeline: incidents are
## keyed rows, each with its keyed updates.
##
## The uptime chart is a `plume-chart` custom element (defined by
## `examples/shared/plume-chart.mjs`, which the page loads) whose `data-figure` attribute carries a Plotly
## figure built with Plume. To the engine it is an ordinary element with an
## ordinary attribute.
StatusApp := [].{
	Board : {
		serial : U64,
		refreshes : U64,
		visible : Bool,
		api : Status.Check,
		web : Status.Check,
		database : Status.Check,
		notifications : Status.Check,
		feed : Status.Feed,
	}

	C1 : In(Root, Board)
	C2 : In(C1, Status.Tally)

	initial : Bool -> Board
	initial = |visible| {
		serial: 0,
		refreshes: 0,
		visible,
		api: Status.pending_check,
		web: Status.pending_check,
		database: Status.pending_check,
		notifications: Status.pending_check,
		feed: Status.loading_feed,
	}

	## Start the next refresh.
	next : Board -> Board
	next = |b| { ..b, serial: b.serial + 1 }

	## The page's visibility changed; becoming visible refreshes at once.
	set_visible : Board, Bool -> Board
	set_visible = |b, visible| if (visible and !b.visible) StatusApp.next({ ..b, visible }) else { ..b, visible }

	totals_of : Board -> Status.Tally
	totals_of = |b| Status.add_tally(Status.add_tally(Status.tally_of(b.api), Status.tally_of(b.web)), Status.add_tally(Status.tally_of(b.database), Status.tally_of(b.notifications)))

	page_class = "app-shell"

	panel_class = "panel grid gap-4 p-5"

	service_row_class = "card flex flex-wrap items-center justify-between gap-3"

	incident_card_class = "card grid gap-2"

	visibility_text : Bool -> Str
	visibility_text = |visible| if (visible) "Auto refresh every 5s" else "Auto refresh paused while the page is hidden"

	refresh_count_text : U64 -> Str
	refresh_count_text = |count| "Refreshes requested: ${count.to_str()}"

	## One label-and-number metric. The `test_id` sits on the value, so a spec
	## reads the number the page shows rather than a sentence built for the
	## spec.
	metric : Str, Str, Val(ctx, Str) -> Elem(ctx)
	metric = |id, label, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value numeric"), Engine.test_id(id), Html.aria_label(label)])])

	## One service's check: issued for every refresh, applied while that
	## refresh is the latest.
	poll : State(ctx, Board), Str, (Board, Try(Str, Engine.HttpError) -> Board) -> Elem(ctx)
	poll = |board, url, apply| Engine.watch(
		board.val().map(|b| b.serial),
		|_| [Http({ method: "GET", url, headers: [], body: "", timeout_ms: 0 })],
		board.on_result(|b, serial, res| if (serial == b.serial) apply(b, Engine.http_text(res)) else b),
	)

	## One component row: name on the left, uptime and a state badge on the
	## right. Its holes read only its own check, so a neighbour degrading
	## changes nothing here.
	service_card : { id : Str, name : Str, detail : Str }, Val(ctx, Status.Check) -> Elem(ctx)
	service_card = |{ id, name, detail }, check| Html.section(
		name,
		StatusApp.service_row_class,
		[
			Html.div("grid min-w-0 gap-0.5", [Html.p(name, "card-title"), Html.p_v(check.map(|c| Status.check_detail(detail, c)), [Engine.class("hint")])]),
			Html.div(
				"flex items-center gap-3",
				[
					Html.p_v(check.map(Status.uptime_text), [Engine.class("numeric hint"), Engine.test_id("service-${id}-uptime"), Html.aria_label("${name} uptime")]),
					Html.p_v(check.map(|c| Status.health_text(c.health)), [Engine.class_v(check.map(|c| Status.health_badge_class(c.health))), Engine.test_id("service-${id}-status"), Html.aria_label("${name} status")]),
				],
			),
		],
	)

	## A service's uptime as a bar height, in percent. A service that has not
	## reported draws no bar rather than a guessed one.
	reported_uptime : Status.Check -> F64
	reported_uptime = |check|
		match check.health {
			Unknown => 0
			CheckFailed(_) => 0
			_ => check.uptime_bps.to_f64() / 100
		}

	## A bar's fill, in the tone of the service's status badge.
	health_color : Status.Health -> Color
	health_color = |health|
		match health {
			Operational => Color.rgb({ red: 5, green: 150, blue: 105 })
			Degraded => Color.rgb({ red: 217, green: 119, blue: 6 })
			Outage => Color.rgb({ red: 220, green: 38, blue: 38 })
			Unknown => Color.rgb({ red: 161, green: 161, blue: 170 })
			CheckFailed(_) => Color.rgb({ red: 217, green: 119, blue: 6 })
		}

	## Uptime per service as one bar trace on a 0-100% axis, each bar in its
	## service's health tone.
	uptime_chart : Board -> Try(Chart, _)
	uptime_chart = |b| {
		var $points = []
		for { name, check } in [{ name: "API", check: b.api }, { name: "Web app", check: b.web }, { name: "Database", check: b.database }, { name: "Notifications", check: b.notifications }] {
			$points = $points.append({ x: Coordinate.from_text(name), y: Coordinate.from_number(StatusApp.reported_uptime(check))?, color: StatusApp.health_color(check.health) })
		}
		bars = Bar.new({ data: $points, name: "Uptime" })?
		uptime_axis = Axis.new({ title: Title.new({ text: "Uptime (%)" }), type: Linear, range: Bounds({ min: 0, max: 100 }) })?
		Ok(Chart.new({ traces: [Bar(bars)], layout: Layout.new({ y_axis: uptime_axis }) }))
	}

	## The chart's Plotly figure JSON. Uptimes are finite and the bar width is
	## Plume's default, so construction cannot fail; were it ever to, the
	## attribute is empty and the element draws nothing.
	uptime_figure : Board -> Str
	uptime_figure = |b|
		match StatusApp.uptime_chart(b) {
			Ok(chart) => chart.to_json()
			Err(_) => ""
		}

	render_update : RowRef(Row(C2, Status.Incident), Status.Update) -> Elem(Row(Row(C2, Status.Incident), Status.Update))
	render_update = |row| {
		key = row.key()
		Html.section_v(
			key,
			"flex gap-3 border-l-2 border-zinc-200 pl-3",
			[
				Html.p_v(row.field(|u| u.time), [Engine.class("numeric hint w-12 shrink-0")]),
				Html.p_v(row.field(|u| u.body), [Engine.class("min-w-0 text-sm text-zinc-700"), Engine.test_id_v(key.map(|k| "update-${k}"))]),
			],
		)
	}

	render_incident : RowRef(C2, Status.Incident) -> Elem(Row(C2, Status.Incident))
	render_incident = |row| {
		key = row.key()
		severity = row.field(|i| i.severity)
		Html.section_v(
			key.map(|k| "Incident ${k}"),
			StatusApp.incident_card_class,
			[
				Html.div(
					"flex flex-wrap items-baseline justify-between gap-2",
					[
						Html.p_v(row.field(|i| i.title), [Engine.class("card-title min-w-0"), Engine.test_id_v(key.map(|k| "incident-${k}-title"))]),
						Html.p_v(severity.map(Status.Severity.label), [Engine.class_v(severity.map(Status.severity_badge_class)), Engine.test_id_v(key.map(|k| "incident-${k}-severity")), Html.aria_label("Severity")]),
					],
				),
				Html.p_v(row.field(|i| i.latest), [Engine.class("muted"), Engine.test_id_v(key.map(|k| "incident-${k}-latest"))]),
				Engine.each(row.field(|i| i.updates), |u| u.key, StatusApp.render_update),
			],
		)
	}

	incidents_panel : Val(C2, Status.Feed) -> Elem(C2)
	incidents_panel = |feed| {
		items = feed.map(|f| f.items)
		Html.section(
			"Incidents",
			StatusApp.panel_class,
			[
				Html.div(
					"flex flex-wrap items-baseline justify-between gap-2",
					[
						Html.h2("Incident history", "panel-title"),
						Html.p_v(feed.map(|f| f.status), [Engine.class("hint"), Engine.test_id("incident-feed-status")]),
					],
				),
				Html.div("stat-grid", [StatusApp.metric("open-incident-count", "Open incidents", items.map(|l| l.len().to_str()))]),
				Engine.when(
					items.map(|l| !l.is_empty()),
					|| Html.section("Incident timeline", "grid gap-3", [Engine.each(items, |i| i.id, StatusApp.render_incident)]),
					|| Html.section("Incident timeline", "grid gap-3", [Html.p("No incidents reported in the last 90 days.", "empty-state")]),
				),
			],
		)
	}

	page : State(C2, Board), Val(C2, Status.Tally) -> Elem(C2)
	page = |board, totals| {
		bv = board.val()
		visible = bv.map(|b| b.visible)
		Html.div(
			StatusApp.page_class,
			[
				Html.section(
					"Status Page",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Acme Cloud Status")]),
						Html.p("Public service health, rolled up from independent per-service checks that refresh on an interval and pause while the page is hidden.", "app-subtitle"),
					],
				),
				# The banner is the whole point of a status page: one
				# unmistakable line, in the tone the rollup earned.
				Html.div_v(
					totals.map(Status.banner_class),
					[
						Html.p_v(totals.map(Status.rollup_text), [Engine.class("text-lg font-semibold"), Engine.test_id("overall-rollup")]),
						Html.p_v(totals.map(Status.reporting_text), [Engine.class("text-sm")]),
					],
				),
				Html.section(
					"Overall status",
					StatusApp.panel_class,
					[
						Html.h2("Current status", "panel-title"),
						Html.div_attrs(
							[Engine.class("stat-grid"), Engine.test_id("status-breakdown")],
							[
								StatusApp.metric("count-operational", "Operational", totals.map(|t| t.operational.to_str())),
								StatusApp.metric("count-degraded", "Degraded", totals.map(|t| t.degraded.to_str())),
								StatusApp.metric("count-outage", "Outage", totals.map(|t| t.outage.to_str())),
								StatusApp.metric("count-awaiting", "Awaiting check", totals.map(|t| t.unknown.to_str())),
								StatusApp.metric("overall-uptime", "Overall uptime", totals.map(Status.overall_uptime_text)),
							],
						),
						Html.div(
							"toolbar justify-between border-t border-zinc-200 pt-4",
							[
								Html.div(
									"grid gap-0.5",
									[
										Html.p_v(visible.map(StatusApp.visibility_text), [Engine.class("hint"), Engine.test_id("refresh-mode")]),
										Html.p_v(bv.map(|b| StatusApp.refresh_count_text(b.refreshes)), [Engine.class("hint numeric"), Engine.test_id("refresh-count")]),
									],
								),
								Html.button("Refresh now", [Engine.class("button-primary")], board.update(|b| StatusApp.next({ ..b, refreshes: b.refreshes + 1 }))),
							],
						),
					],
				),
				Html.section(
					"Services",
					StatusApp.panel_class,
					[
						Html.h2("Components", "panel-title"),
						StatusApp.service_card({ id: "api", name: "API", detail: "api.acme.cloud — REST and GraphQL" }, bv.map(|b| b.api)),
						StatusApp.service_card({ id: "web", name: "Web app", detail: "app.acme.cloud — dashboard and console" }, bv.map(|b| b.web)),
						StatusApp.service_card({ id: "database", name: "Database", detail: "Primary Postgres cluster, eu-west-1" }, bv.map(|b| b.database)),
						StatusApp.service_card({ id: "notifications", name: "Notifications", detail: "Email, SMS and outbound webhooks" }, bv.map(|b| b.notifications)),
						Engine.element("plume-chart", [Engine.class("block"), Engine.attr("role", "img"), Html.aria_label("Uptime by service"), Engine.test_id("uptime-chart"), Engine.attr_v("data-figure", bv.map(StatusApp.uptime_figure))], []),
					],
				),
				StatusApp.incidents_panel(bv.map(|b| b.feed)),
				# Polling lives inside the visible branch, so hiding the page
				# disposes the interval. Already-admitted checks finish.
				Engine.when(
					visible,
					|| Html.div("hidden", [Engine.watch(Engine.const({}), |_| [Interval(5000)], board.on_result(|b, _, _| StatusApp.next(b)))]),
					|| Html.div("hidden", []),
				),
				StatusApp.poll(board, "/api/status/api", |b, r| { ..b, api: Status.check_of(r) }),
				StatusApp.poll(board, "/api/status/web", |b, r| { ..b, web: Status.check_of(r) }),
				StatusApp.poll(board, "/api/status/database", |b, r| { ..b, database: Status.check_of(r) }),
				StatusApp.poll(board, "/api/status/notifications", |b, r| { ..b, notifications: Status.check_of(r) }),
				StatusApp.poll(board, "/api/status/incidents", |b, r| { ..b, feed: Status.feed_of(r) }),
				Engine.watch(
					Engine.const({}),
					|_| [VisibilityChanges],
					board.on_result(
						|b, _, r| match r {
							Visible(v) => StatusApp.set_visible(b, v)
							_ => b
						},
					),
				),
				Engine.cleanup("status page cleanup"),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives on the fuzz platform.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [], max_inflight: 32 }, |boot| StatusApp.main(boot.visible))

	main : Bool -> Elem(Root)
	main = |visible| Engine.state(
		StatusApp.initial(visible),
		|board| Engine.derive(board.val().map(StatusApp.totals_of), |totals| StatusApp.page(board.lift(), totals)),
	)
}
