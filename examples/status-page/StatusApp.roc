import pf.Engine exposing [Elem, Row, RowRef, Signal]
import pf.Html
import Charts
import Latency
import Live
import Parts
import Status
import StatusStore

## Status Page: four independent service checks fan in to one rollup.
##
## What the checks last said is the page's store (`StatusStore`): each
## service's check, the incident feed and the uptime history are cells any
## part of the page reads where it draws them, and every change to them is
## one of the store's transitions.
##
## Each refresh issues one HTTP check per service plus the incident feed.
## Refreshes are numbered (the store's `serial`): the mount is refresh 0,
## and every interval tick, "Refresh now" click and return to visibility
## starts the next. Each check is a `latest` site on the serial, so a new
## refresh cancels the checks of the one before it and a late answer to a
## superseded refresh never arrives. The 5 s interval lives inside the
## visible branch, so hiding the page disposes it; requests already
## admitted stay in flight.
##
## The four checks collapse into one `Tally` (a memoised `derive`), and the
## banner, the metrics and the counts are read from that one value, so the
## page can never show "All systems operational" beside a red component.
## The incident feed is a fifth result rendered as a timeline: incidents are
## keyed rows, each with its keyed updates. Each answer replaces the whole
## feed, a short list that is a value, so the timeline is an `each`.
##
## Every refresh also starts a round of the uptime history, which the
## answers fill in, and the page keeps the last `Status.history_limit`
## rounds. The history is drawn as a `plume-chart` custom element (defined
## by `examples/shared/plume-chart.mjs`, which the page loads) whose
## `data-figure` attribute carries a Plotly figure built with Plume
## (`Charts.roc`). To the engine it is an ordinary element with an ordinary
## attribute.
##
## Below the services, a live p95 latency chart follows a port
## subscription (`Latency.roc`, answered by the example's `ports.mjs`). It
## is a component with a state of its own (`Live`), handed the one cell it
## reads.
StatusApp := [].{

	page_class = "app-shell"

	service_row_class = "card flex flex-wrap items-center justify-between gap-3"

	incident_card_class = "card grid gap-2"

	visibility_text : Bool -> Str
	visibility_text = |visible| if (visible) "Auto refresh every 5s" else "Auto refresh paused while the page is hidden"

	refresh_count_text : U64 -> Str
	refresh_count_text = |count| "Refreshes requested: ${count.to_str()}"

	## One check of `url`, issued for every refresh; `answered` decides what
	## its answer writes. A newer refresh cancels the check still in flight
	## for an older one (`latest` aborts its fetch), so only the current
	## refresh's answer is ever applied and a slow service never piles up
	## requests.
	poll : Str, (Try(Str, Engine.HttpError) -> List(Engine.Write(_))) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	poll = |url, answered| Engine.watch_latest(
		StatusStore.cells.serial.signal(),
		|_| [Engine.http_body({ url, cache: NoStore })],
		Engine.react(|_serial, res| answered(res)),
	)

	## One component row: name on the left, uptime and a state badge on the
	## right. Its holes read only its own check, so a neighbour degrading
	## changes nothing here.
	service_card : { id : Str, name : Str, detail : Str }, Signal(ctx, Status.Check) -> Elem(ctx)
	service_card = |{ id, name, detail }, check| Html.section(
		name,
		StatusApp.service_row_class,
		[
			Html.div("grid min-w-0 gap-0.5", [Html.p(name, "card-title"), Html.p_s(check.map(|c| Status.check_detail(detail, c)), [Engine.class("hint")])]),
			Html.div(
				"flex items-center gap-3",
				[
					Html.p_s(check.map(Status.uptime_text), [Engine.class("numeric hint"), Engine.test_id("service-${id}-uptime"), Html.aria_label("${name} uptime")]),
					Html.p_s(check.map(|c| Status.health_text(c.health)), [Engine.class_s(check.map(|c| Status.health_badge_class(c.health))), Engine.test_id("service-${id}-status"), Html.aria_label("${name} status")]),
				],
			),
		],
	)

	render_update : RowRef(ctx, Status.Update) -> Elem(Row(ctx, Status.Update))
	render_update = |row| {
		key = row.key()
		Html.section_s(
			key,
			"flex gap-3 border-l-2 border-zinc-200 pl-3",
			[
				Html.p_s(row.field(|u| u.time), [Engine.class("numeric hint w-12 shrink-0")]),
				Html.p_s(row.field(|u| u.body), [Engine.class("min-w-0 text-sm text-zinc-700"), Engine.test_id_s(key.map(|k| "update-${k}"))]),
			],
		)
	}

	render_incident : RowRef(ctx, Status.Incident) -> Elem(Row(ctx, Status.Incident))
	render_incident = |row| {
		key = row.key()
		severity = row.field(|i| i.severity)
		Html.section_s(
			key.map(|k| "Incident ${k}"),
			StatusApp.incident_card_class,
			[
				Html.div(
					"flex flex-wrap items-baseline justify-between gap-2",
					[
						Html.p_s(row.field(|i| i.title), [Engine.class("card-title min-w-0"), Engine.test_id_s(key.map(|k| "incident-${k}-title"))]),
						Html.p_s(severity.map(Status.Severity.label), [Engine.class_s(severity.map(Status.severity_badge_class)), Engine.test_id_s(key.map(|k| "incident-${k}-severity")), Html.aria_label("Severity")]),
					],
				),
				Html.p_s(row.field(|i| i.latest), [Engine.class("muted"), Engine.test_id_s(key.map(|k| "incident-${k}-latest"))]),
				Engine.each(row.field(|i| i.updates), |u| u.key, StatusApp.render_update),
			],
		)
	}

	incidents_panel : Signal(ctx, Status.Feed) -> Elem(ctx)
	incidents_panel = |feed| {
		items = feed.map(|f| f.items)
		Html.section(
			"Incidents",
			Parts.panel_class,
			[
				Html.div(
					"flex flex-wrap items-baseline justify-between gap-2",
					[
						Html.h2("Incident history", "panel-title"),
						Html.p_s(feed.map(|f| f.status), [Engine.class("hint"), Engine.test_id("incident-feed-status")]),
					],
				),
				Html.div("stat-grid", [Parts.metric("open-incident-count", "Open incidents", items.map(|l| l.len().to_str()))]),
				Engine.when(
					items.map(|l| !l.is_empty()),
					|| Html.section("Incident timeline", "grid gap-3", [Engine.each(items, |i| i.id, StatusApp.render_incident)]),
					|| Html.section("Incident timeline", "grid gap-3", [Html.p("No incidents reported in the last 90 days.", "empty-state")]),
				),
			],
		)
	}

	## The page, under the rollup of the four checks. Everything else it
	## draws it reads from the store's cells where it draws it.
	page : Signal(ctx, Status.Tally), Engine.Boot -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	page = |totals, boot| {
		cells = StatusStore.cells
		visible = cells.visible.signal()
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
				Html.div_s(
					totals.map(Status.banner_class),
					[
						Html.p_s(totals.map(Status.rollup_text), [Engine.class("text-lg font-semibold"), Engine.test_id("overall-rollup")]),
						Html.p_s(totals.map(Status.reporting_text), [Engine.class("text-sm")]),
					],
				),
				Html.section(
					"Overall status",
					Parts.panel_class,
					[
						Html.h2("Current status", "panel-title"),
						Html.div_attrs(
							[Engine.class("stat-grid"), Engine.test_id("status-breakdown")],
							[
								Parts.metric("count-operational", "Operational", totals.map(|t| t.operational.to_str())),
								Parts.metric("count-degraded", "Degraded", totals.map(|t| t.degraded.to_str())),
								Parts.metric("count-outage", "Outage", totals.map(|t| t.outage.to_str())),
								Parts.metric("count-awaiting", "Awaiting check", totals.map(|t| t.unknown.to_str())),
								Parts.metric("overall-uptime", "Overall uptime", totals.map(Status.overall_uptime_text)),
							],
						),
						Html.div(
							"toolbar justify-between border-t border-zinc-200 pt-4",
							[
								Html.div(
									"grid gap-0.5",
									[
										Html.p_s(visible.map(StatusApp.visibility_text), [Engine.class("hint"), Engine.test_id("refresh-mode")]),
										Html.p_s(cells.requests.signal().map(StatusApp.refresh_count_text), [Engine.class("hint numeric"), Engine.test_id("refresh-count")]),
									],
								),
								Html.button("Refresh now", [Engine.class("button-primary")], Engine.does(StatusStore.requested)),
							],
						),
					],
				),
				Html.section(
					"Services",
					Parts.panel_class,
					[
						Html.h2("Components", "panel-title"),
						StatusApp.service_card({ id: "api", name: "API", detail: "api.acme.cloud — REST and GraphQL" }, cells.checks.api.signal()),
						StatusApp.service_card({ id: "web", name: "Web app", detail: "app.acme.cloud — dashboard and console" }, cells.checks.web.signal()),
						StatusApp.service_card({ id: "database", name: "Database", detail: "Primary Postgres cluster, eu-west-1" }, cells.checks.database.signal()),
						StatusApp.service_card({ id: "notifications", name: "Notifications", detail: "Email, SMS and outbound webhooks" }, cells.checks.notifications.signal()),
						Html.h3("Uptime over the last ${Status.history_limit.to_str()} checks", "panel-title"),
						Engine.derive(
							cells.history.signal(),
							|history| Engine.element("plume-chart", [Engine.class("block"), Engine.attr("role", "img"), Html.aria_label("Uptime history by service"), Engine.test_id("uptime-chart"), Engine.attr_s("data-figure", history.map(Charts.uptime_history))], []),
						),
					],
				),
				Live.view({ visible: cells.visible, seed: boot.seed, initially_visible: boot.visible }),
				StatusApp.incidents_panel(cells.feed.signal()),
				# Polling lives inside the visible branch, so hiding the page
				# disposes the interval. Already-admitted checks finish.
				Engine.when(
					visible,
					|| Html.div("hidden", [Engine.watch(Engine.const({}), |_| [Engine.interval(5000)], Engine.react(|_, _| StatusStore.refreshed))]),
					|| Html.div("hidden", []),
				),
				StatusApp.poll("/api/status/api", |answer| StatusStore.answered(Api, Status.check_of(answer))),
				StatusApp.poll("/api/status/web", |answer| StatusStore.answered(Web, Status.check_of(answer))),
				StatusApp.poll("/api/status/database", |answer| StatusStore.answered(Database, Status.check_of(answer))),
				StatusApp.poll("/api/status/notifications", |answer| StatusStore.answered(Notifications, Status.check_of(answer))),
				StatusApp.poll("/api/status/incidents", |answer| [cells.feed.set(Status.feed_of(answer))]),
				Engine.watch(
					Engine.const({}),
					|_| [Engine.visibility_changes({})],
					Engine.react_by(
						visible,
						|was, _, res| match res {
							Ok(now) => StatusStore.shown(was, now)
							_ => []
						},
					),
				),
				Engine.cleanup("status page cleanup"),
			],
		)
	}

	## The page under one rollup of the checks, which every reader of the
	## rollup shares.
	view : Engine.Boot -> Elem(Engine.StoreRoot(_))
	view = |boot| Engine.derive(StatusStore.totals({}), |totals| StatusApp.page(totals, boot))

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, StatusStore.start, StatusApp.view).with_ports(Latency.registrations)
}
