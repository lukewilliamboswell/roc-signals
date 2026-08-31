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
##
## Nothing downstream of a parser is stringly typed: `Health` and `Severity` are
## nominal tag unions with an `is_eq` (so they can be signal state) and a
## `from_str` that runs once, at the host boundary, on the payload the task
## returned. Every branch after that is a `match` on a tag.

import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Rows
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

	## The wire form a check payload arrives in. Anything unrecognised is
	## `Unknown`, so a garbled payload never claims a service is healthy.
	from_str : Str -> Health
	from_str = |text|
		if text == "operational" {
			Health.Operational
		} else if text == "degraded" {
			Health.Degraded
		} else if text == "outage" {
			Health.Outage
		} else {
			Health.Unknown
		}
}

## How bad one incident is. The wire sends `"major"` / `"minor"`; everything
## else is routine maintenance. Parsed once, in `parse_incident`.
Severity := [Major, Minor, Maintenance].{
	is_eq : Severity, Severity -> Bool
	is_eq = |left, right|
		match left {
			Major => match right {
				Major => True
				_ => False
			}
			Minor => match right {
				Minor => True
				_ => False
			}
			Maintenance => match right {
				Maintenance => True
				_ => False
			}
		}

	from_str : Str -> Severity
	from_str = |text|
		if text == "major" {
			Severity.Major
		} else if text == "minor" {
			Severity.Minor
		} else {
			Severity.Maintenance
		}

	## The badge caption.
	label : Severity -> Str
	label = |severity|
		match severity {
			Major => "Major"
			Minor => "Minor"
			Maintenance => "Maintenance"
		}
}

## One service's latest check: health plus uptime in basis points (9998 = 99.98%).
Check : { health : Health, uptime_bps : U64 }

## Fan-in accumulator. Every service contributes one of these; adding them is
## associative, so the rollup is a balanced `Signal.map2` tree.
Tally : { operational : U64, degraded : U64, outage : U64, unknown : U64, uptime_bps : U64, reporting : U64 }

## One published update on an incident. `time` and `body` are kept apart
## because the timeline draws them in separate columns; `update_summary` joins
## them back up for the places that want one line.
Update : { key : Str, time : Str, body : Str, text : Str }

Incident : { id : Str, severity : Severity, title : Str, latest : Str, updates : List(Update) }

Feed : { items : List(Incident), status : Str }

pending_check : Check
pending_check = { health: Health.Unknown, uptime_bps: 0 }

## `"degraded|97.40"` -> a `Check`.
parse_check : Str -> Check
parse_check = |payload|
	match payload.split_first("|") {
		Ok(split) => { health: Health.from_str(split.before), uptime_bps: parse_uptime(split.after) }
		Err(_) => { health: Health.from_str(payload), uptime_bps: 0 }
	}

parse_uptime : Str -> U64
parse_uptime = |text|
	match text.split_first(".") {
		Ok(split) => whole_number(split.before) * 100 + whole_number(split.after)
		Err(_) => whole_number(text) * 100
	}

whole_number : Str -> U64
whole_number = |text| U64.from_str(text).ok_or(0)

## A recognised wire word parses to the matching health tag.
expect Health.is_eq(Health.from_str("degraded"), Health.Degraded)

## An unrecognised payload becomes Unknown rather than claiming health.
expect Health.is_eq(Health.from_str("who knows"), Health.Unknown)

## A check payload takes its health from the part before the separator.
expect Health.is_eq(parse_check("degraded|97.40").health, Health.Degraded)

## A check payload's uptime is read as basis points, so 97.40 is 9740.
expect parse_check("degraded|97.40").uptime_bps == 9740

## A payload with no uptime field reports no uptime rather than guessing one.
expect parse_check("operational").uptime_bps == 0

## Uptime digits that are not a number contribute zero instead of failing.
expect whole_number("not a number") == 0

format_uptime : U64 -> Str
format_uptime = |bps| {
	rest = bps % 100
	pad = if rest < 10 { "0" } else { "" }
	"${(bps / 100).to_str()}.${pad}${rest.to_str()}%"
}

## Basis points render as a two-decimal percentage.
expect format_uptime(9740) == "97.40%"

## A remainder below ten keeps its leading zero, so 9905 is not "99.5%".
expect format_uptime(9905) == "99.05%"

## Full uptime renders as "100.00%", not a truncated "100%".
expect format_uptime(10000) == "100.00%"

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

## Before any service has reported, the banner says so instead of claiming health.
expect rollup_text(empty_tally) == "Checking services"

## A single operational service is enough to headline as all systems operational.
expect rollup_text(add_tally(tally_of({ health: Health.Operational, uptime_bps: 10000 }), empty_tally)) == "All systems operational"

## One degraded service downgrades the headline to degraded performance.
expect rollup_text(add_tally(tally_of({ health: Health.Degraded, uptime_bps: 9000 }), empty_tally)) == "Degraded performance"

## Any observed outage escalates the headline to a major outage.
expect rollup_text(add_tally(tally_of({ health: Health.Outage, uptime_bps: 0 }), empty_tally)) == "Major outage"

## A refresh that never came back contributes no uptime sample, so one broken
## check cannot drag the reported uptime down.
expect tally_of({ health: Health.CheckFailed("timeout"), uptime_bps: 9999 }).uptime_bps == 0

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

severity_badge_class : Severity -> Str
severity_badge_class = |severity| {
	tone =
		match severity {
			Major => "badge-danger"
			Minor => "badge-warn"
			Maintenance => "badge-info"
		}
	"badge ${tone} shrink-0"
}

## The wire word "major" reaches the badge as the Major caption.
expect Severity.label(Severity.from_str("major")) == "Major"

## The wire word "minor" reaches the badge as the Minor caption.
expect Severity.label(Severity.from_str("minor")) == "Minor"

## An empty severity field is treated as routine maintenance, not as an incident.
expect Severity.label(Severity.from_str("")) == "Maintenance"

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
	severity = Severity.from_str(field_at(parts, 1, "minor"))
	title = field_at(parts, 2, "Untitled incident")
	updates = parse_updates(id, field_at(parts, 3, ""))
	{ id, severity, title, latest: latest_body(updates), updates }
}

field_at : List(Str), U64, Str -> Str
field_at = |parts, index, fallback| parts.get(index) ?? fallback

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
## `"10:02@Investigating elevated 5xx responses"` -> one `Update`. An entry with
## no `@` has no timestamp and the whole entry is the body.
update_of = |id, seq, entry| {
	split =
		match entry.split_first("@") {
			Ok(parts) => parts
			Err(_) => { before: "", after: entry }
		}
	time = split.before
	body = split.after
	summary = update_summary({ time, body })
	{ key: "${id}#${seq.to_str()}", time, body, text: "${id} update ${seq.to_str()} - ${summary}" }
}

## The one-line form: `"10:02 - Investigating elevated 5xx responses"`. The
## timeline draws the two halves separately, so this is built where a joined
## line is wanted rather than stored and split apart again.
update_summary : { time : Str, body : Str } -> Str
update_summary = |update| "${update.time} - ${update.body}"

latest_body : List(Update) -> Str
latest_body = |updates|
	updates.fold("no updates yet", |_, update| update_summary({ time: update.time, body: update.body }))

## An empty payload is an empty timeline, not one blank incident.
expect parse_feed("") == []

## An incident takes its severity from the second field of the payload.
expect Severity.is_eq(parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified").severity, Severity.Major)

## The headline of an incident is its most recently published update.
expect parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified").latest == "10:20 - Identified"

## Every published update is kept, so the timeline shows the full history.
expect parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified").updates.len() == 2

## An update's list key pairs the incident id with the 1-based sequence number.
expect {
	update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating").updates.get(0)?
	update.key == "inc-42#1"
}

## The timestamp column holds only the part before the "@" separator.
expect {
	update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating").updates.get(0)?
	update.time == "10:02"
}

## The body column holds only the part after the "@" separator.
expect {
	update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating").updates.get(0)?
	update.body == "Investigating"
}

## The announcement text joins the sequence number back onto the one-line summary.
expect {
	update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating").updates.get(0)?
	update.text == "inc-42 update 1 - 10:02 - Investigating"
}

## A field the feed left out falls back rather than dropping the incident.
expect parse_incident("inc-7").title == "Untitled incident"

## An incident with no updates yet says so instead of showing an empty line.
expect latest_body([]) == "no updates yet"

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
##
## The three `Str`s are a record, not three positional arguments: `id`, `name`
## and `detail` are indistinguishable to the type checker, so a transposed call
## site would type-check and render nonsense.
service_card : { id : Str, name : Str, detail : Str }, Signal.Signal(Check) -> Elem
service_card = |{ id, name, detail }, check|
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
			Html.paragraph_s_c(update.map(|value| value.time), "numeric hint w-12 shrink-0"),
			Html.paragraph_s_attrs(
				update.map(|value| value.body),
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
						incident.map(|value| Severity.label(value.severity)),
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
			Ui.each(Signal.map(incident.map(|value| value.updates), |rows_items| Rows.from_list(rows_items, |value| value.key) ?? crash "duplicate row key"), |each_row| render_update(each_row.key(), each_row.signal())),
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
				|| Html.section_c("Incident timeline", "grid gap-3", [Ui.each(Signal.map(items, |rows_items| Rows.from_list(rows_items, |item| item.id) ?? crash "duplicate row key"), |each_row| render_incident(each_row.key(), each_row.signal()))]),
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
							service_card({ id: "api", name: "API", detail: "api.acme.cloud — REST and GraphQL" }, api),
							service_card({ id: "web", name: "Web app", detail: "app.acme.cloud — dashboard and console" }, web),
							service_card({ id: "database", name: "Database", detail: "Primary Postgres cluster, eu-west-1" }, database),
							service_card({ id: "notifications", name: "Notifications", detail: "Email, SMS and outbound webhooks" }, notifications),
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
