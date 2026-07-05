app [main] { pf: platform "../../platform/main.roc" }

import Dashboard
import DashboardRemote
import DashboardTheme
import DashboardView
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Route : [RouteOverview, RouteService(Str), RouteUnknown]

RouteIntent : { serial : U64, path : Str, query : Str, hash : Str }

increment_u64 : U64 -> U64
increment_u64 = |current| current + 1

overview_location : Browser.Location
overview_location = { path: "/", query: "", hash: "" }

service_location : Str -> Browser.Location
service_location = |service_id| { path: "/services/${service_id}", query: "", hash: "" }

route_from_location : Browser.Location -> Route
route_from_location = |location|
	if location.path == "/" {
		RouteOverview
	} else if location.path == "/services/edge" {
		RouteService("edge")
	} else if location.path == "/services/api" {
		RouteService("api")
	} else if location.path == "/services/workers" {
		RouteService("workers")
	} else if location.path == "/services/database" {
		RouteService("database")
	} else if location.path == "/services/billing" {
		RouteService("billing")
	} else if location.path == "/services/search" {
		RouteService("search")
	} else if location.path == "/services/identity" {
		RouteService("identity")
	} else {
		RouteUnknown
	}

route_service_id : Route -> Str
route_service_id = |route|
	match route {
		RouteService(service_id) => service_id
		_ => ""
	}

route_shows_detail : Route -> Bool
route_shows_detail = |route|
	match route {
		RouteService(_) => True
		_ => False
	}

document_title_for_route : Route -> Str
document_title_for_route = |route|
	match route {
		RouteService(service_id) => "${service_id} service detail - Service Ops Center"
		_ => "Service Ops Center"
	}

canonical_location : Dashboard.State, Browser.Location -> Browser.Location
canonical_location = |state, location|
	match route_from_location(location) {
		RouteUnknown =>
			match state {
				Ready(_) => overview_location
				_ => location
			}
		_ => location
	}

route_intent_location : RouteIntent -> Browser.Location
route_intent_location = |intent| { path: intent.path, query: intent.query, hash: intent.hash }

route_intent_for : RouteIntent, Browser.Location -> RouteIntent
route_intent_for = |current, target| {
	{
		serial: current.serial + 1,
		path: target.path,
		query: target.query,
		hash: target.hash,
	}
}

route_link : Str, Str, Browser.Location, Ui.State(RouteIntent) -> Elem
route_link = |label, classes, target, intent| {
	Html.link(
		label,
		[
			Html.class_attr(classes),
			Html.attr("href", target.path),
			Html.on_event("click", Html.event_policy_prevent_default, intent.on_unit(|current| route_intent_for(current, target))),
		],
	)
}

field : Signal.Signal(r), (r -> a) -> Signal.Signal(a)
	where [
		a.is_eq : a, a -> Bool,
	]
field = |source, select| Signal.map(source, select)

select_remote : Signal.Signal(Dashboard.State), (Dashboard -> a) -> Signal.Signal(DashboardRemote(a))
	where [
		a.is_eq : a, a -> Bool,
	]
select_remote = |state, select| Signal.map(state, |value| DashboardRemote.from_state(value, select))

select_remote_with : Signal.Signal(Dashboard.State), Signal.Signal(b), (Dashboard, b -> a) -> Signal.Signal(DashboardRemote(a))
	where [
		a.is_eq : a, a -> Bool,
	]
select_remote_with = |state, extra, select| Signal.map2(state, extra, |value, detail| DashboardRemote.from_state_with(value, detail, select))

ready_list : Signal.Signal(DashboardRemote(List(a))) -> Signal.Signal(List(a))
	where [
		a.is_eq : a, a -> Bool,
	]
ready_list = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(items) => items
				_ => []
			},
	)

remote_is_ready = |remote| field(remote, DashboardRemote.is_ready)

remote_tone = |remote|
	field(
		remote,
		|value|
			if DashboardRemote.is_failed(value) {
				ToneError
			} else {
				ToneNeutral
			},
	)

remote_message = |label, remote| {
	message = field(remote, DashboardRemote.message)
	classes = field(remote_tone(remote), DashboardTheme.remote_inline_class)

	Html.div_sc(
		classes,
		[
			Html.div_c(DashboardTheme.metric_label_class, [Html.text(label)]),
			Html.div_c(DashboardTheme.metric_detail_class, [Html.text_s(message)]),
		],
	)
}

render_panel : Str, Str, List(Elem) -> Elem
render_panel = |region_label, heading, children|
	Html.section_c(
		region_label,
		DashboardTheme.panel_class,
		List.concat(
			[Html.heading_c(heading, DashboardTheme.section_heading_class)],
			children,
		),
	)

render_status_item : Str, Signal.Signal(DashboardView.StatusItem) -> Elem
render_status_item = |_key, item| {
	label = field(item, |row| row.label)
	value = field(item, |row| row.value)
	detail = field(item, |row| row.detail)

	Html.div_c(
		DashboardTheme.status_item_class,
		[
			Html.div_c(DashboardTheme.status_label_class, [Html.text_s(label)]),
			Html.div_c(DashboardTheme.status_value_class, [Html.text_s(value)]),
			Html.div_c(DashboardTheme.status_detail_class, [Html.text_s(detail)]),
		],
	)
}

render_metric : Str, Signal.Signal(DashboardView.Metric) -> Elem
render_metric = |_key, metric| {
	label = field(metric, |row| row.label)
	value = field(metric, |row| row.value)
	detail = field(metric, |row| row.detail)
	classes = field(metric, |row| DashboardTheme.metric_class(row.tone))

	Html.div_sc(
		classes,
		[
			Html.div_c(DashboardTheme.metric_label_class, [Html.text_s(label)]),
			Html.div_c(DashboardTheme.metric_value_class, [Html.text_s(value)]),
			Html.div_c(DashboardTheme.metric_detail_class, [Html.text_s(detail)]),
		],
	)
}

render_traffic_row : Str, Signal.Signal(DashboardView.TrafficRow) -> Elem
render_traffic_row = |_key, row| {
	label = field(row, |item| item.label)
	value = field(row, |item| item.value)
	bar = field(row, |item| item.bar)
	bar_class = field(bar, DashboardTheme.segment_fill_class)
	note = field(row, |item| item.note)

	Html.div_c(
		DashboardTheme.traffic_row_class,
		[
			Html.div_c(DashboardTheme.row_label_class, [Html.text_s(label)]),
			Html.div_c(DashboardTheme.row_value_class, [Html.text_s(value)]),
			Html.div_c(DashboardTheme.row_bar_shell_class, [Html.div_sc(bar_class, [])]),
			Html.div_c(DashboardTheme.row_bar_class, [Html.text_s(bar)]),
			Html.div_c(DashboardTheme.row_note_class, [Html.text_s(note)]),
		],
	)
}

render_service_cell : Str, Signal.Signal(DashboardView.ServiceRow) -> Elem
render_service_cell = |_key, service| {
	label = field(service, |row| row.label)
	state = field(service, |row| row.state)
	detail = field(service, |row| row.detail)
	classes = field(service, |row| DashboardTheme.service_class(row.tone))

	Html.div_sc(
		classes,
		[
			Html.div_c(
				DashboardTheme.row_header_class,
				[
					Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(label)]),
					Html.div_c(DashboardTheme.mono_xs_class, [Html.text_s(state)]),
				],
			),
			Html.div_c(DashboardTheme.text_sm_class, [Html.text_s(detail)]),
		],
	)
}

render_job_row : Str, Signal.Signal(DashboardView.JobRow) -> Elem
render_job_row = |_key, job| {
	label = field(job, |row| row.label)
	run_id = field(job, |row| row.run_id)
	state = field(job, |row| row.state)
	progress = field(job, |row| row.progress)
	age = field(job, |row| row.age)
	owner = field(job, |row| row.owner)
	classes = field(job, |row| DashboardTheme.job_class(row.tone))

	Html.div_sc(
		classes,
		[
			Html.div_c(
				DashboardTheme.wrap_row_header_class,
				[
					Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(label)]),
					Html.div_c(DashboardTheme.mono_xs_class, [Html.text_s(run_id)]),
				],
			),
			Html.div_c(
				DashboardTheme.job_detail_grid_class,
				[
					Html.div_c(DashboardTheme.text_sm_class, [Html.text_s(state)]),
					Html.div_c(DashboardTheme.mono_sm_class, [Html.text_s(progress)]),
					Html.div_c(DashboardTheme.text_sm_class, [Html.text_s(age)]),
					Html.div_c(DashboardTheme.text_sm_class, [Html.text_s(owner)]),
				],
			),
		],
	)
}

render_alert_row : Str, Signal.Signal(DashboardView.AlertRow) -> Elem
render_alert_row = |_key, alert| {
	severity = field(alert, |row| row.severity)
	service = field(alert, |row| row.service)
	state = field(alert, |row| row.state)
	age = field(alert, |row| row.age)
	summary = field(alert, |row| row.summary)
	classes = field(alert, |row| DashboardTheme.alert_class(row.tone))

	Html.div_sc(
		classes,
		[
			Html.div_c(
				DashboardTheme.inline_header_class,
				[
					Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(severity)]),
					Html.div_c(DashboardTheme.mono_xs_class, [Html.text_s(service)]),
					Html.div_c(DashboardTheme.text_xs_class, [Html.text_s(age)]),
				],
			),
			Html.div_c(DashboardTheme.text_sm_class, [Html.text_s(summary)]),
			Html.div_c(DashboardTheme.text_xs_class, [Html.text_s(state)]),
		],
	)
}

render_dependency_row : Str, Signal.Signal(Dashboard.ServiceDependency) -> Elem
render_dependency_row = |_key, dependency| {
	label = field(dependency, |row| row.label)
	state = field(dependency, |row| row.state)

	Html.div_c(
		DashboardTheme.detail_row_class,
		[
			Html.div_c(DashboardTheme.detail_label_class, [Html.text("Dependency")]),
			Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(label)]),
			Html.div_c(DashboardTheme.text_sm_muted_class, [Html.text_s(state)]),
		],
	)
}

render_contact_row : Str, Signal.Signal(Dashboard.ServiceContact) -> Elem
render_contact_row = |_key, contact| {
	team = field(contact, |row| row.team)
	channel = field(contact, |row| row.channel)

	Html.div_c(
		DashboardTheme.detail_row_class,
		[
			Html.div_c(DashboardTheme.detail_label_class, [Html.text("Contact")]),
			Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(team)]),
			Html.div_c(DashboardTheme.text_sm_muted_class, [Html.text_s(channel)]),
		],
	)
}

render_status_items : Signal.Signal(List(DashboardView.StatusItem)) -> Elem
render_status_items = |items| Ui.each_str(items, |item| item.id, render_status_item)

render_metrics : Signal.Signal(List(DashboardView.Metric)) -> Elem
render_metrics = |items| Ui.each_str(items, |item| item.id, render_metric)

render_traffic_rows : Signal.Signal(List(DashboardView.TrafficRow)) -> Elem
render_traffic_rows = |items| Ui.each_str(items, |item| item.id, render_traffic_row)

render_service_rows : Signal.Signal(List(DashboardView.ServiceRow)) -> Elem
render_service_rows = |items| Ui.each_str(items, |item| item.id, render_service_cell)

render_job_rows : Signal.Signal(List(DashboardView.JobRow)) -> Elem
render_job_rows = |items| Ui.each_str(items, |item| item.id, render_job_row)

render_alert_rows : Signal.Signal(List(DashboardView.AlertRow)) -> Elem
render_alert_rows = |items| Ui.each_str(items, |item| item.id, render_alert_row)

render_dependency_rows : Signal.Signal(List(Dashboard.ServiceDependency)) -> Elem
render_dependency_rows = |items| Ui.each_str(items, |item| item.id, render_dependency_row)

render_contact_rows : Signal.Signal(List(Dashboard.ServiceContact)) -> Elem
render_contact_rows = |items| Ui.each_str(items, |item| item.team, render_contact_row)

status_strip_items : Signal.Signal(DashboardRemote(DashboardView.StatusStrip)) -> Signal.Signal(List(DashboardView.StatusItem))
status_strip_items = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(strip) => strip.items
				_ => []
			},
	)

status_strip_tone : Signal.Signal(DashboardRemote(DashboardView.StatusStrip)) -> Signal.Signal(DashboardTheme.Tone)
status_strip_tone = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(strip) => strip.tone
				RemoteFailed(_) => ToneError
				_ => ToneNeutral
			},
	)

status_strip : Signal.Signal(DashboardRemote(DashboardView.StatusStrip)) -> Elem
status_strip = |status| {
	is_ready = remote_is_ready(status)
	items = status_strip_items(status)
	classes = field(status_strip_tone(status), DashboardTheme.status_strip_class)

	Ui.component(
		|_|
			Html.div_sc(
				classes,
				[
					Ui.when(
						is_ready,
						|_| render_status_items(items),
						|_| remote_message("Status", status),
					),
				],
			),
	)
}

metric_grid = |metrics| {
	is_ready = remote_is_ready(metrics)
	items = ready_list(metrics)

	Ui.component(
		|_|
			Ui.when(
				is_ready,
				|_| Html.div_c(DashboardTheme.metric_grid_class, [render_metrics(items)]),
				|_| Html.div_c(DashboardTheme.metric_grid_class, [remote_message("Metrics", metrics)]),
			),
	)
}

traffic_panel = |traffic| {
	is_ready = remote_is_ready(traffic)
	rows = ready_list(traffic)

	Ui.component(
		|_|
			render_panel(
				"Traffic",
				"Traffic and pressure",
				[
					Ui.when(
						is_ready,
						|_| render_traffic_rows(rows),
						|_| remote_message("Traffic", traffic),
					),
				],
			),
	)
}

chart_payload = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(model) => model.payload
				_ => ""
			},
	)

chart_headline = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(model) => model.headline
				_ => "Chart waiting for data"
			},
	)

chart_detail = |remote|
	field(
		remote,
		|value|
			match value {
				RemoteReady(model) => model.detail
				_ => DashboardRemote.message(value)
			},
	)

chart_panel = |chart| {
	Ui.state(
		"",
		|hovered_chart_point| {
			Ui.state(
				"",
				|selected_chart_point| {
					is_ready = remote_is_ready(chart)
					payload = chart_payload(chart)
					headline = chart_headline(chart)
					detail = chart_detail(chart)
					hovered = hovered_chart_point.signal()
					selected = selected_chart_point.signal()
					focus_inputs = { hovered: hovered, selected: selected }.Signal
					focus = Signal.map(focus_inputs, |inputs| DashboardView.chart_focus_text(inputs.hovered, inputs.selected))

					Ui.component(
						|_|
							Html.div(
								[
									Html.test_id("traffic-chart"),
									Html.on_custom("chart-hover", hovered_chart_point.on_detail(|_, value| value)),
									Html.on_custom("chart-select", selected_chart_point.on_detail(|_, value| value)),
								],
								[
									render_panel(
										"Traffic chart",
										"Interactive traffic chart",
										[
											Ui.when(
												is_ready,
												|_|
													Html.div_c(
														DashboardTheme.chart_shell_class,
														[
															Html.div_c(
																DashboardTheme.chart_copy_class,
																[
																	Html.div_c(DashboardTheme.strong_text_class, [Html.text_s(headline)]),
																	Html.div_c(DashboardTheme.text_sm_muted_class, [Html.text_s(detail)]),
																],
															),
															Html.div(
																[
																	Html.class_attr(DashboardTheme.chart_mount_class),
																	Html.behavior("ops-chart"),
																	Html.attr_s("data-ops-chart-points", payload),
																	Html.attr_s("data-ops-chart-selected", selected),
																	Html.attr("aria-label", "Interactive traffic chart"),
																],
																[Html.div_c(DashboardTheme.chart_loading_class, [Html.text("Preparing chart")])],
															),
														],
													),
												|_| remote_message("Chart", chart),
											),
											Html.div_c(DashboardTheme.chart_focus_class, [Html.text_s(focus)]),
										],
									),
								],
							),
					)
				},
			)
		},
	)
}

services_panel = |services| {
	is_ready = remote_is_ready(services)
	rows = ready_list(services)

	Ui.component(
		|_|
			render_panel(
				"Service health",
				"Service matrix",
				[
					Ui.when(
						is_ready,
						|_| Html.div_c(DashboardTheme.service_grid_class, [render_service_rows(rows)]),
						|_| remote_message("Services", services),
					),
				],
			),
	)
}

jobs_panel = |jobs| {
	is_ready = remote_is_ready(jobs)
	rows = ready_list(jobs)

	Ui.component(
		|_|
			render_panel(
				"Active jobs",
				"Active jobs",
				[
					Ui.when(
						is_ready,
						|_| render_job_rows(rows),
						|_| remote_message("Jobs", jobs),
					),
				],
			),
	)
}

alerts_panel = |alerts| {
	is_ready = remote_is_ready(alerts)
	rows = ready_list(alerts)

	Ui.component(
		|_|
			render_panel(
				"Alerts",
				"Incidents and alerts",
				[
					Ui.when(
						is_ready,
						|_| render_alert_rows(rows),
						|_| remote_message("Alerts", alerts),
					),
				],
			),
	)
}

detail_dependencies = |detail|
	field(
		detail,
		|value|
			match value {
				RemoteReady(model) => model.dependencies
				_ => []
			},
	)

detail_contacts = |detail|
	field(
		detail,
		|value|
			match value {
				RemoteReady(model) => model.contacts
				_ => []
			},
	)

service_detail_panel = |detail, route_intent| {
	is_ready = remote_is_ready(detail)
	title =
		field(
			detail,
			|value|
				match value {
					RemoteReady(model) => DashboardView.service_detail_title(model)
					_ => DashboardRemote.message(value)
				},
		)
	status =
		field(
			detail,
			|value|
				match value {
					RemoteReady(model) => DashboardView.service_detail_status(model)
					_ => DashboardRemote.message(value)
				},
		)
	summary =
		field(
			detail,
			|value|
				match value {
					RemoteReady(model) => DashboardView.service_detail_summary(model)
					_ => "Waiting for service detail"
				},
		)
	runbook =
		field(
			detail,
			|value|
				match value {
					RemoteReady(model) => DashboardView.service_detail_runbook(model)
					_ => "Runbook: waiting"
				},
		)
	dependency_count =
		field(
			detail,
			|value|
				match value {
					RemoteReady(model) => DashboardView.service_detail_dependency_count(model)
					_ => "0 dependencies watched"
				},
		)
	dependencies = detail_dependencies(detail)
	contacts = detail_contacts(detail)

	Ui.component(
		|_|
			render_panel(
				"Service detail",
				"Service detail",
				[
					Html.div_c(
						DashboardTheme.view_nav_class,
						[
							route_link("Back to overview", DashboardTheme.secondary_button_class, overview_location, route_intent),
						],
					),
					Html.div_c(DashboardTheme.metric_detail_class, [Html.text("This drill-down is URL-addressable; browser Back and Forward restore the selected service.")]),
					Ui.when(
						is_ready,
						|_|
							Html.div_c(
								DashboardTheme.detail_grid_class,
								[
									Html.div_c(
										DashboardTheme.detail_main_class,
										[
											Html.div_c(DashboardTheme.app_heading_class, [Html.text_s(title)]),
											Html.div_c(DashboardTheme.text_sm_muted_class, [Html.text_s(status)]),
											Html.div_c(DashboardTheme.metric_detail_class, [Html.text_s(summary)]),
											Html.div_c(DashboardTheme.mono_sm_class, [Html.text_s(runbook)]),
										],
									),
									Html.div_c(
										DashboardTheme.detail_side_class,
										[
											Html.div_c(DashboardTheme.detail_label_class, [Html.text_s(dependency_count)]),
											render_dependency_rows(dependencies),
											render_contact_rows(contacts),
										],
									),
								],
							),
						|_| remote_message("Service detail", detail),
					),
				],
			),
	)
}

service_nav = |route_intent|
	Html.div_c(
		DashboardTheme.view_nav_class,
		[
			route_link("Open api details", DashboardTheme.secondary_button_class, service_location("api"), route_intent),
			route_link("Open workers details", DashboardTheme.secondary_button_class, service_location("workers"), route_intent),
			route_link("Open database details", DashboardTheme.secondary_button_class, service_location("database"), route_intent),
		],
	)

is_visible : Browser.Visibility -> Bool
is_visible = |visibility|
	match visibility {
		Visible => True
		Hidden => False
	}

visibility_status_text : Browser.Visibility -> Str
visibility_status_text = |visibility|
	if is_visible(visibility) {
		"Auto refresh active"
	} else {
		"Auto refresh paused while tab is hidden"
	}

refresh_key : { tick : U64, manual : U64 } -> U64
refresh_key = |inputs|
	inputs.tick + inputs.manual

toolbar = |last_updated, manual_refresh_text, visibility_status, refresh_now, route_intent|
	Html.div_c(
		DashboardTheme.toolbar_class,
		[
			Html.div_c(
				DashboardTheme.toolbar_text_class,
				[
					Html.heading_c("Service Ops Center", DashboardTheme.app_heading_class),
					Html.div_c(DashboardTheme.toolbar_status_class, [Html.text_s(last_updated)]),
					Html.div_c(DashboardTheme.toolbar_status_class, [Html.text_s(visibility_status)]),
				],
			),
			Html.div_c(
				DashboardTheme.toolbar_actions_class,
				[
					route_link("Overview", DashboardTheme.secondary_button_class, overview_location, route_intent),
					Html.text_s(manual_refresh_text),
					Html.button_c("Refresh now", DashboardTheme.primary_button_class, refresh_now),
				],
			),
		],
	)

dashboard_page = |dashboard_state, route, selected_service, manual_refresh_text, visibility_status, refresh_now, route_intent, lifecycle| {
	last_updated = field(select_remote(dashboard_state, DashboardView.last_updated), DashboardRemote.text)
	status = select_remote(dashboard_state, DashboardView.status_strip)
	metrics = select_remote(dashboard_state, DashboardView.metrics)
	chart = select_remote(dashboard_state, DashboardView.chart_model)
	traffic = select_remote(dashboard_state, DashboardView.traffic_rows)
	services = select_remote(dashboard_state, DashboardView.service_rows)
	jobs = select_remote(dashboard_state, DashboardView.job_rows)
	alerts = select_remote(dashboard_state, DashboardView.alert_rows)
	selected_detail = select_remote_with(dashboard_state, selected_service, Dashboard.service_detail_for)
	show_detail = Signal.map(route, route_shows_detail)

	Ui.component(
		|_|
			Html.div_c(
				DashboardTheme.page_class,
				[
					Html.div_c(
						DashboardTheme.shell_class,
						List.concat(
							[
								toolbar(last_updated, manual_refresh_text, visibility_status, refresh_now, route_intent),
								Ui.when(
									show_detail,
									|_| service_detail_panel(selected_detail, route_intent),
									|_|
										Html.div_c(
											"grid gap-4",
											[
												status_strip(status),
												metric_grid(metrics),
												service_nav(route_intent),
												Html.div_c(
													DashboardTheme.main_grid_class,
													[
														Html.div_c(DashboardTheme.wide_column_class, [chart_panel(chart), traffic_panel(traffic), services_panel(services)]),
														Html.div_c(DashboardTheme.side_column_class, [jobs_panel(jobs), alerts_panel(alerts)]),
													],
												),
											],
										),
								),
							],
							lifecycle,
						),
					),
				],
			),
	)
}

main : {} -> Elem
main = |_| {
	Ui.state(
		0,
		|manual_refresh| {
			Ui.state(
				{ serial: 0, path: "/", query: "", hash: "" },
				|route_intent| {
					location = Browser.location
					visibility = Browser.visibility
					visible = Signal.map(visibility, is_visible)
					route = Signal.map(location, route_from_location)
					selected_service = Signal.map(route, route_service_id)
					tick = Signal.interval(2000)
					refresh_inputs = { tick: tick, manual: manual_refresh.signal() }.Signal
					refresh_request = Signal.map(refresh_inputs, refresh_key)

					dashboard_task = Http.get_text_task("dashboard")
					dashboard_state =
						Signal.fold_task(
							dashboard_task,
							Dashboard.loading,
							Dashboard.decode,
							Dashboard.request_failed,
						)
					canonical_inputs = { dashboard: dashboard_state, location }.Signal
					canonical_route = Signal.map(canonical_inputs, |inputs| canonical_location(inputs.dashboard, inputs.location))

					manual_refresh_text = field(manual_refresh.signal(), DashboardView.manual_refresh_text)
					visibility_status = Signal.map(visibility, visibility_status_text)
					document_title = Signal.map(route, document_title_for_route)
					dashboard_page(
						dashboard_state,
						route,
						selected_service,
						manual_refresh_text,
						visibility_status,
						manual_refresh.on_unit(increment_u64),
						route_intent,
						[
							Ui.when(
								visible,
								|_|
									Html.div_c(
										"hidden",
										[
											Ui.on_mount(|_| Http.get_text(dashboard_task, "/api/ops/dashboard")),
											Ui.on_change(refresh_request, |_| Http.get_text(dashboard_task, "/api/ops/dashboard")),
										],
									),
								|_|
									Html.div_c(
										"hidden",
										[
											Ui.on_change(manual_refresh.signal(), |_| Http.get_text(dashboard_task, "/api/ops/dashboard")),
										],
									),
							),
							Ui.on_change(route_intent.signal(), |intent| Browser.push_state(route_intent_location(intent))),
							Ui.on_change(canonical_route, Browser.replace_state),
							Ui.on_change_initial(document_title, Browser.set_title),
						],
					)
				},
			)
		},
	)
}
