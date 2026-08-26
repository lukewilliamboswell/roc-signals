app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

card_class = "panel grid gap-1 p-3"

headline_class = "text-2xl font-semibold text-zinc-950"

line_class = "text-sm text-zinc-700"

strong_line_class = "text-sm font-medium text-zinc-900"

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

health_text : Health -> Str
health_text = |health|
	match health {
		Operational => "operational"
		Degraded => "degraded"
		Outage => "outage"
		Unknown => "awaiting first check"
		CheckFailed(err) => "check failed (${err})"
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

rollup_text : Tally -> Str
rollup_text = |tally| {
	known = tally.operational + tally.degraded + tally.outage
	if known == 0 {
		"Checking services"
	} else if tally.outage > 0 or tally.degraded >= 3 {
		"Major outage"
	} else if tally.degraded > 0 {
		"Degraded performance"
	} else {
		"All systems operational"
	}
}

breakdown_text : Tally -> Str
breakdown_text = |tally|
	"Operational ${tally.operational.to_str()}, degraded ${tally.degraded.to_str()}, outage ${tally.outage.to_str()}, awaiting ${tally.unknown.to_str()}"

overall_uptime_text : Tally -> Str
overall_uptime_text = |tally|
	if tally.reporting == 0 {
		"Overall uptime: not reported"
	} else {
		"Overall uptime: ${format_uptime(tally.uptime_bps / tally.reporting)}"
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

## One service card. It reads only its own check signal, so a neighbour
## degrading never touches this subtree.
service_card : Str, Signal.Signal(Check) -> Elem
service_card = |name, check|
	Html.section_c(
		name,
		card_class,
		[
			Html.paragraph_s_c(check.map(|value| "${name} status: ${health_text(value.health)}"), strong_line_class),
			Html.paragraph_s_c(check.map(|value| "${name} uptime: ${uptime_text(value)}"), line_class),
		],
	)

render_update : Str, Signal.Signal(Update) -> Elem
render_update = |key, update|
	Html.section_c(key, "text-sm text-zinc-600", [Html.text_s(update.map(|value| value.text))])

render_incident : Str, Signal.Signal(Incident) -> Elem
render_incident = |key, incident|
	Html.section_c(
		"Incident ${key}",
		card_class,
		[
			Html.paragraph_s_c(incident.map(|value| "${key} severity: ${severity_text(value.severity)}"), strong_line_class),
			Html.paragraph_s_c(incident.map(|value| "${key} title: ${value.title}"), line_class),
			Html.paragraph_s_c(incident.map(|value| "${key} latest: ${value.latest}"), line_class),
			Ui.each_str(incident.map(|value| value.updates), |value| value.key, render_update),
		],
	)

overview_panel : Signal.Signal(Tally), Signal.Signal(Str), Signal.Signal(Str), _ -> Elem
overview_panel = |totals, refresh_status, refresh_count, refresh_now|
	Html.section_c(
		"Overall status",
		panel_class,
		[
			Html.paragraph_s_c(totals.map(rollup_text), headline_class),
			Html.paragraph_s_c(totals.map(breakdown_text), line_class),
			Html.paragraph_s_c(totals.map(overall_uptime_text), strong_line_class),
			Html.paragraph_s_c(refresh_status, line_class),
			Html.paragraph_s_c(refresh_count, line_class),
			Html.button_c("Refresh now", "button-primary justify-self-start", refresh_now),
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
			Html.paragraph_s_c(feed.map(|value| value.status), strong_line_class),
			Html.paragraph_s_c(items.map(|list| "Open incidents: ${list.len().to_str()}"), line_class),
			Ui.when(
				has_items,
				|| Html.section_c("Incident timeline", "grid gap-3", [Ui.each_str(items, |item| item.id, render_incident)]),
				|| Html.section_c("Incident timeline", "grid gap-3", [Html.paragraph_c("No incidents reported", line_class)]),
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
						hero_class,
						[
							Html.heading_c("Status Page", "text-3xl font-semibold text-zinc-950"),
							Html.paragraph_c("Public service health, rolled up from independent per-service checks that refresh on an interval and pause while the page is hidden.", "max-w-3xl text-sm text-zinc-700"),
						],
					),
					overview_panel(totals, refresh_status, refresh_count, refreshes.on_unit(|n| n + 1)),
					Html.section_c(
						"Services",
						panel_class,
						[
							service_card("API", api),
							service_card("Web app", web),
							service_card("Database", database),
							service_card("Notifications", notifications),
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
