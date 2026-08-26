app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

## Status Page — four independent service checks fanning in to one rollup.
##
## Each service is its own `Signal.task_source`, polled on a 5s interval that
## only exists while the page is visible. The four checks collapse into a single
## `Tally` through a balanced `Signal.map2` tree, and the banner, the metrics and
## every per-service badge are derived from that one value, so the page can never
## show "All systems operational" beside a red component.
##
##     api ──> tally_of ─┐
##     web ──> tally_of ─┴─> front ─┐
##                                  ├─> totals ──> rollup / stats / badges
##     database ──────> tally_of ─┐ │
##     notifications ─> tally_of ─┴─┘ back
##
## The incident feed is a fifth, unrelated task source rendered as a timeline.

import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell"

panel_class = "panel grid gap-4 p-5"

service_row_class = "card flex flex-wrap items-center justify-between gap-3"

incident_card_class = "card grid gap-2"

## Health of one service check. `CheckFailed` is a refresh that did not come
## back; it is deliberately distinct from an observed outage.
Health := [Operational, Degraded, Outage, Unknown, CheckFailed(Str)].{
	is_eq : Health, Health -> Bool
	is_eq = |left, right|
		match left {
			Operational => match right {
				Operational => True
				_ => False
			}
			Degraded => match right {
				Degraded => True
				_ => False
			}
			Outage => match right {
				Outage => True
				_ => False
			}
			Unknown => match right {
				Unknown => True
				_ => False
			}
			CheckFailed(left_error) => match right {
				CheckFailed(right_error) => left_error == right_error
				_ => False
			}
		}
}

## One service's latest check: health plus uptime in basis points (9998 = 99.98%).
Check : { health : Health, uptime_bps : U64 }

## Fan-in accumulator. Every service contributes one of these; adding them is
## associative, so the rollup is a balanced `Signal.map2` tree.
Tally : { operational : U64, degraded : U64, outage : U64, unknown : U64, uptime_bps : U64, reporting : U64 }

Update : { key : Str, summary : Str, text : Str }

Incident : { id : Str, severity : Str, title : Str, latest : Str, updates : List(Update) }

Feed : { items : List(Incident), status : Str }

pending_check : Check
pending_check = { health: Health.Unknown, uptime_bps: 0 }

## `"degraded|97.40"` -> a `Check`.
parse_check : Str -> Check
parse_check = |payload|
	match payload.split_first("|") {
		Ok(split) => { health: parse_health(split.before), uptime_bps: parse_uptime(split.after) }
		Err(_) => { health: parse_health(payload), uptime_bps: 0 }
	}

parse_health : Str -> Health
parse_health = |text|
	if text == "operational" {
		Health.Operational
	} else if text == "degraded" {
		Health.Degraded
	} else if text == "outage" {
		Health.Outage
	} else {
		Health.Unknown
	}

parse_uptime : Str -> U64
parse_uptime = |text|
	match text.split_first(".") {
		Ok(split) => whole_number(split.before) * 100 + whole_number(split.after)
		Err(_) => whole_number(text) * 100
	}

whole_number : Str -> U64
whole_number = |text|
	match U64.from_str(text) {
		Ok(value) => value
		Err(_) => 0
	}

format_uptime : U64 -> Str
format_uptime = |bps| {
	rest = bps % 100
	pad = if rest < 10 { "0" } else { "" }
	"${(bps / 100).to_str()}.${pad}${rest.to_str()}%"
}

## The badge caption for a service. `CheckFailed` keeps its own wording: a
## refresh that never came back is not the same claim as an observed outage.
health_text : Health -> Str
health_text = |health|
	match health {
		Operational => "Operational"
		Degraded => "Degraded"
		Outage => "Outage"
		Unknown => "Awaiting first check"
		CheckFailed(_) => "Check failed"
	}

## The line under a service name. Normally the component's description; when a
## refresh failed it is the reason, because that is the useful thing to read.
check_detail : Str, Check -> Str
check_detail = |detail, check|
	match check.health {
		CheckFailed(err) => "Last refresh failed: ${err}"
		_ => detail
	}

uptime_text : Check -> Str
uptime_text = |check|
	match check.health {
		Unknown => "not reported"
		CheckFailed(_) => "not reported"
		_ => format_uptime(check.uptime_bps)
	}

empty_tally : Tally
empty_tally = { operational: 0, degraded: 0, outage: 0, unknown: 0, uptime_bps: 0, reporting: 0 }

## One service -> its contribution to the rollup. A failed refresh counts as
## degraded but contributes no uptime sample, so one broken check can never
## drag the reported uptime down.
tally_of : Check -> Tally
tally_of = |check|
	match check.health {
		Operational => { ..empty_tally, operational: 1, reporting: 1, uptime_bps: check.uptime_bps }
		Degraded => { ..empty_tally, degraded: 1, reporting: 1, uptime_bps: check.uptime_bps }
		Outage => { ..empty_tally, outage: 1, reporting: 1, uptime_bps: check.uptime_bps }
		Unknown => { ..empty_tally, unknown: 1 }
		CheckFailed(_) => { ..empty_tally, degraded: 1 }
	}

add_tally : Tally, Tally -> Tally
add_tally = |left, right| {
	operational: left.operational + right.operational,
	degraded: left.degraded + right.degraded,
	outage: left.outage + right.outage,
	unknown: left.unknown + right.unknown,
	uptime_bps: left.uptime_bps + right.uptime_bps,
	reporting: left.reporting + right.reporting,
}

## The headline and the colour of the banner come off this one value, so the
## wording and the tone can never disagree.
rollup_state : Tally -> [Checking, Healthy, Degraded, Major]
rollup_state = |tally| {
	known = tally.operational + tally.degraded + tally.outage
	if known == 0 {
		Checking
	} else if tally.outage > 0 or tally.degraded >= 3 {
		Major
	} else if tally.degraded > 0 {
		Degraded
	} else {
		Healthy
	}
}

rollup_text : Tally -> Str
rollup_text = |tally|
	match rollup_state(tally) {
		Checking => "Checking services"
		Major => "Major outage"
		Degraded => "Degraded performance"
		Healthy => "All systems operational"
	}

banner_class : Tally -> Str
banner_class = |tally| {
	tone =
		match rollup_state(tally) {
			Checking => "notice-info"
			Major => "notice-error"
			Degraded => "notice-warn"
			Healthy => "notice-ok"
		}
	"notice ${tone} flex flex-wrap items-baseline justify-between gap-2 px-4 py-3"
}

reporting_text : Tally -> Str
reporting_text = |tally| "${tally.reporting.to_str()} of 4 components reporting"

health_badge_class : Health -> Str
health_badge_class = |health| {
	tone =
		match health {
			Operational => "badge-ok"
			Degraded => "badge-warn"
			Outage => "badge-danger"
			Unknown => "badge-neutral"
			CheckFailed(_) => "badge-warn"
		}
	"badge ${tone} shrink-0"
}

severity_badge_class : Str -> Str
severity_badge_class = |severity| {
	tone =
		if severity == "major" {
			"badge-danger"
		} else if severity == "minor" {
			"badge-warn"
		} else {
			"badge-info"
		}
	"badge ${tone} shrink-0"
}

## A check that never came back contributes no uptime sample, so the average is
## over `reporting`, not over four.
overall_uptime_text : Tally -> Str
overall_uptime_text = |tally|
	if tally.reporting == 0 {
		"not reported"
	} else {
		format_uptime(tally.uptime_bps / tally.reporting)
	}

## `"inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified"`,
## incidents separated by `#`. An empty payload is an empty timeline.
parse_feed : Str -> List(Incident)
parse_feed = |payload|
	if payload == "" {
		[]
	} else {
		payload.split_on("#").map(parse_incident)
	}

parse_incident : Str -> Incident
parse_incident = |raw| {
	parts = raw.split_on("~")
	id = field_at(parts, 0, "unknown")
	severity = field_at(parts, 1, "minor")
	title = field_at(parts, 2, "Untitled incident")
	updates = parse_updates(id, field_at(parts, 3, ""))
	{ id, severity, title, latest: latest_body(updates), updates }
}

field_at : List(Str), U64, Str -> Str
field_at = |parts, index, fallback|
	match parts.get(index) {
		Ok(value) => value
		Err(_) => fallback
	}

## Updates arrive oldest first and keep that order; each row carries the
## 1-based sequence number it was published with.
parse_updates : Str, Str -> List(Update)
parse_updates = |id, raw|
	if raw == "" {
		[]
	} else {
		folded =
			raw.split_on("^").fold(
				{ seq: 0, items: [] },
				|state, entry| {
					seq = state.seq + 1
					{ seq, items: state.items.append(update_of(id, seq, entry)) }
				},
			)
		folded.items
	}

update_of : Str, U64, Str -> Update
update_of = |id, seq, entry| {
	split =
		match entry.split_first("@") {
			Ok(parts) => parts
			Err(_) => { before: "", after: entry }
		}
	summary = "${split.before} - ${split.after}"
	{ key: "${id}#${seq.to_str()}", summary, text: "${id} update ${seq.to_str()} - ${summary}" }
}

latest_body : List(Update) -> Str
latest_body = |updates|
	updates.fold("no updates yet", |_, update| update.summary)

## `summary` is `"10:02 - Investigating elevated 5xx responses"`. The timeline
## draws the two halves separately; the joined form is what the specs read.
update_time : Update -> Str
update_time = |update|
	match update.summary.split_first(" - ") {
		Ok(split) => split.before
		Err(_) => ""
	}

update_body : Update -> Str
update_body = |update|
	match update.summary.split_first(" - ") {
		Ok(split) => split.after
		Err(_) => update.summary
	}

severity_text : Str -> Str
severity_text = |severity|
	if severity == "major" {
		"Major"
	} else if severity == "minor" {
		"Minor"
	} else {
		"Maintenance"
	}

loading_feed : Feed
loading_feed = { items: [], status: "Incident feed: loading" }

ready_feed : List(Incident) -> Feed
ready_feed = |items| { items, status: "Incident feed: updated" }

failed_feed : Str -> Feed
failed_feed = |err| { items: [], status: "Incident feed unavailable (${err})" }

## Named on purpose: the `U64` annotation pins the type of the `Ui.state`
## literal below. Written as an unannotated inline closure, `0` infers as a
## `Frac` and renders "Refreshes requested: 0.0".
refresh_count_text : U64 -> Str
refresh_count_text = |count| "Refreshes requested: ${count.to_str()}"

visibility_text : Browser.Visibility -> Str
visibility_text = |visibility|
	match visibility {
		Visible => "Auto refresh every 5s"
		Hidden => "Auto refresh paused while the page is hidden"
	}

is_visible : Browser.Visibility -> Bool
is_visible = |visibility|
	match visibility {
		Visible => True
		Hidden => False
	}

## One label-and-number metric. The `test_id` sits on the value, so a spec reads
## the number the page shows rather than a sentence built for the spec.
metric : Str, Str, Signal.Signal(Str) -> Elem
metric = |id, label, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value numeric"), Html.test_id(id), Html.aria_label(label)]),
		],
	)

## One component row: name on the left, uptime and a state badge on the right.
## It reads only its own check signal, so a neighbour degrading never touches
## this subtree.
service_card : Str, Str, Str, Signal.Signal(Check) -> Elem
service_card = |id, name, detail, check|
	Html.section_c(
		name,
		service_row_class,
		[
			Html.div_c(
				"grid min-w-0 gap-0.5",
				[
					Html.paragraph_c(name, "card-title"),
					Html.paragraph_s_c(check.map(|value| check_detail(detail, value)), "hint"),
				],
			),
			Html.div_c(
				"flex items-center gap-3",
				[
					Html.paragraph_s_attrs(
						check.map(uptime_text),
						[Html.class_attr("numeric hint"), Html.test_id("service-${id}-uptime"), Html.aria_label("${name} uptime")],
					),
					Html.paragraph_s_attrs(
						check.map(|value| health_text(value.health)),
						[
							Html.class_attr_s(check.map(|value| health_badge_class(value.health))),
							Html.test_id("service-${id}-status"),
							Html.aria_label("${name} status"),
						],
					),
				],
			),
		],
	)

render_update : Str, Signal.Signal(Update) -> Elem
render_update = |key, update|
	Html.section_c(
		key,
		"flex gap-3 border-l-2 border-zinc-200 pl-3",
		[
			Html.paragraph_s_c(update.map(update_time), "numeric hint w-12 shrink-0"),
			Html.paragraph_s_attrs(
				update.map(update_body),
				[Html.class_attr("min-w-0 text-sm text-zinc-700"), Html.test_id("update-${key}")],
			),
		],
	)

render_incident : Str, Signal.Signal(Incident) -> Elem
render_incident = |key, incident|
	Html.section_c(
		"Incident ${key}",
		incident_card_class,
		[
			Html.div_c(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.paragraph_s_attrs(
						incident.map(|value| value.title),
						[Html.class_attr("card-title min-w-0"), Html.test_id("incident-${key}-title")],
					),
					Html.paragraph_s_attrs(
						incident.map(|value| severity_text(value.severity)),
						[
							Html.class_attr_s(incident.map(|value| severity_badge_class(value.severity))),
							Html.test_id("incident-${key}-severity"),
							Html.aria_label("Severity"),
						],
					),
				],
			),
			Html.paragraph_s_attrs(
				incident.map(|value| value.latest),
				[Html.class_attr("muted"), Html.test_id("incident-${key}-latest")],
			),
			Ui.each_str(incident.map(|value| value.updates), |value| value.key, render_update),
		],
	)

## The banner is the whole point of a status page: one unmistakable line, in the
## tone the rollup earned.
health_banner : Signal.Signal(Tally) -> Elem
health_banner = |totals|
	Html.div_sc(
		totals.map(banner_class),
		[
			Html.paragraph_s_attrs(
				totals.map(rollup_text),
				[Html.class_attr("text-lg font-semibold"), Html.test_id("overall-rollup")],
			),
			Html.paragraph_s_c(totals.map(reporting_text), "text-sm"),
		],
	)

overview_panel : Signal.Signal(Tally), Signal.Signal(Str), Signal.Signal(Str), _ -> Elem
overview_panel = |totals, refresh_status, refresh_count, refresh_now|
	Html.section_c(
		"Overall status",
		panel_class,
		[
			Html.heading_c("Current status", "panel-title"),
			# `status-breakdown` names the whole grid; the four counts it used to
			# spell out as a sentence are now the four metrics inside it.
			Html.div(
				[Html.class_attr("stat-grid"), Html.test_id("status-breakdown")],
				[
					metric("count-operational", "Operational", totals.map(|value| value.operational.to_str())),
					metric("count-degraded", "Degraded", totals.map(|value| value.degraded.to_str())),
					metric("count-outage", "Outage", totals.map(|value| value.outage.to_str())),
					metric("count-awaiting", "Awaiting check", totals.map(|value| value.unknown.to_str())),
					metric("overall-uptime", "Overall uptime", totals.map(overall_uptime_text)),
				],
			),
			Html.div_c(
				"toolbar justify-between border-t border-zinc-200 pt-4",
				[
					Html.div_c(
						"grid gap-0.5",
						[
							Html.paragraph_s_attrs(refresh_status, [Html.class_attr("hint"), Html.test_id("refresh-mode")]),
							Html.paragraph_s_attrs(refresh_count, [Html.class_attr("hint numeric"), Html.test_id("refresh-count")]),
						],
					),
					Html.button_c("Refresh now", "button-primary", refresh_now),
				],
			),
		],
	)

incidents_panel : Signal.Signal(Feed) -> Elem
incidents_panel = |feed| {
	items = feed.map(|value| value.items)
	has_items = items.map(|list| list.len() > 0)

	Html.section_c(
		"Incidents",
		panel_class,
		[
			Html.div_c(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.heading_c("Incident history", "panel-title"),
					Html.paragraph_s_attrs(feed.map(|value| value.status), [Html.class_attr("hint"), Html.test_id("incident-feed-status")]),
				],
			),
			Html.div_c(
				"stat-grid",
				[metric("open-incident-count", "Open incidents", items.map(|list| list.len().to_str()))],
			),
			Ui.when(
				has_items,
				|| Html.section_c("Incident timeline", "grid gap-3", [Ui.each_str(items, |item| item.id, render_incident)]),
				|| Html.section_c("Incident timeline", "grid gap-3", [Html.paragraph_c("No incidents reported in the last 90 days.", "empty-state")]),
			),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		0,
		|refreshes| {
			# `reset_on_start = False` keeps the last known result on screen while a
			# refresh is in flight, so a poll does not blank the board every 5s.
			api_task = Signal.task_source("check:api", parse_check, |err| err, False)
			web_task = Signal.task_source("check:web", parse_check, |err| err, False)
			database_task = Signal.task_source("check:database", parse_check, |err| err, False)
			notifications_task = Signal.task_source("check:notifications", parse_check, |err| err, False)
			feed_task = Signal.task_source("incidents", parse_feed, |err| err, False)

			check_of = |task| Signal.fold_task(task, pending_check, |value| value, |err| { health: Health.CheckFailed(err), uptime_bps: 0 })

			api = check_of(api_task)
			web = check_of(web_task)
			database = check_of(database_task)
			notifications = check_of(notifications_task)
			feed = Signal.fold_task(feed_task, loading_feed, ready_feed, failed_feed)

			# Fan-in: four independently-created service signals collapse into one
			# rollup through a balanced `Signal.map2` tree. `Signal.combine` cannot
			# do this today because it reads every input through the first input's
			# capability.
			front = Signal.map2(api.map(tally_of), web.map(tally_of), add_tally)
			back = Signal.map2(database.map(tally_of), notifications.map(tally_of), add_tally)
			totals = Signal.map2(front, back, add_tally)

			visibility = Browser.visibility()
			visible = visibility.map(is_visible)
			refresh_status = visibility.map(visibility_text)
			refresh_count = refreshes.signal().map(refresh_count_text)
			ticks = Signal.interval(5000)

			start_all = |trigger| [
				Ui.on_change(trigger, |_| Signal.start_str(api_task, "refresh")),
				Ui.on_change(trigger, |_| Signal.start_str(web_task, "refresh")),
				Ui.on_change(trigger, |_| Signal.start_str(database_task, "refresh")),
				Ui.on_change(trigger, |_| Signal.start_str(notifications_task, "refresh")),
				Ui.on_change(trigger, |_| Signal.start_str(feed_task, "refresh")),
			]

			mount_all = [
				Ui.on_mount(|| Signal.start_str(api_task, "refresh")),
				Ui.on_mount(|| Signal.start_str(web_task, "refresh")),
				Ui.on_mount(|| Signal.start_str(database_task, "refresh")),
				Ui.on_mount(|| Signal.start_str(notifications_task, "refresh")),
				Ui.on_mount(|| Signal.start_str(feed_task, "refresh")),
			]

			Html.div_c(
				page_class,
				[
					Html.section_c(
						"Status Page",
						"app-header",
						[
							Html.heading_c("Acme Cloud Status", "app-title"),
							Html.paragraph_c("Public service health, rolled up from independent per-service checks that refresh on an interval and pause while the page is hidden.", "app-subtitle"),
						],
					),
					health_banner(totals),
					overview_panel(totals, refresh_status, refresh_count, refreshes.on_unit(|n| n + 1)),
					Html.section_c(
						"Services",
						panel_class,
						[
							Html.heading_c("Components", "panel-title"),
							service_card("api", "API", "api.acme.cloud — REST and GraphQL", api),
							service_card("web", "Web app", "app.acme.cloud — dashboard and console", web),
							service_card("database", "Database", "Primary Postgres cluster, eu-west-1", database),
							service_card("notifications", "Notifications", "Email, SMS and outbound webhooks", notifications),
						],
					),
					incidents_panel(feed),
					# Polling lives inside the visible arm, so hiding the page disposes
					# the interval and cancels in-flight checks.
					Ui.when(
						visible,
						|| Html.div_c("hidden", mount_all.concat(start_all(ticks))),
						|| Html.div_c("hidden", []),
					),
					Html.div_c("hidden", start_all(refreshes.signal())),
					Ui.on_cleanup(Signal.cleanup("status page cleanup")),
				],
			)
		},
	)
