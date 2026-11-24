import pf.Engine

## Status Page domain: per-service health checks, their fan-in into one
## rollup `Tally`, and the incident feed. Every payload is parsed once, here,
## at the boundary where the HTTP result arrives; everything after is a
## `match` on a tag.
##
## Nothing in here builds markup; the badge and banner tones are derived from
## the same tags as their captions.
Status := [].{

	## Health of one service check. `CheckFailed` is a refresh that did not come
	## back; it is deliberately distinct from an observed outage.
	Health := [Operational, Degraded, Outage, Unknown, CheckFailed(Str)].{
		is_eq : _

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
		is_eq : _

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

	## The four services the page checks.
	Service : [Api, Web, Database, Notifications]

	## What one refresh learned of one service's uptime: nothing yet
	## (`Awaiting`: no answer has arrived, or the refresh was superseded
	## before one did), a figure in basis points (`Measured`), or no figure
	## because the check failed or its payload carried none (`Unmeasured`).
	Uptime : [Awaiting, Measured(U64), Unmeasured]

	## One refresh's uptime for each service: one step of the history.
	Round : { api : Uptime, web : Uptime, database : Uptime, notifications : Uptime }

	## How many refreshes the uptime history keeps: five minutes at one
	## refresh every five seconds. A new round beyond it lets the oldest go,
	## so the history, and the chart drawn from it, stay this size however
	## long the page is open.
	history_limit : U64
	history_limit = 60

	## The history at mount: the mount's own refresh, awaiting its answers.
	first_history : List(Round)
	first_history = [awaiting_round]

	## A new refresh starts a round awaiting its answers, letting the oldest
	## round go beyond `history_limit`.
	start_round : List(Round) -> List(Round)
	start_round = |history| {
		grown = history.append(awaiting_round)
		if grown.len() > history_limit {
			grown.drop_first(grown.len() - history_limit)
		} else {
			grown
		}
	}

	## A check's answer recorded in the current round, the last one. Answers
	## only ever arrive for the current refresh (each check is a `latest`
	## site), so an answer never lands in an older round.
	record_uptime : List(Round), Service, Check -> List(Round)
	record_uptime = |history, service, check|
		match history.last() {
			Ok(round) => history.drop_last(1).append(with_uptime(round, service, uptime_of(check)))
			Err(_) => crash "Status.record_uptime: the history always holds the current round"
		}

	## A service's uptime in one round.
	uptime_in : Round, Service -> Uptime
	uptime_in = |round, service|
		match service {
			Api => round.api
			Web => round.web
			Database => round.database
			Notifications => round.notifications
		}

	## Fan-in accumulator. Every service contributes one of these; adding them is
	## associative, so the rollup is a balanced tree of `map2`s.
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
		pad = if rest < 10 {
			"0"
		} else {
			""
		}
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
		"notice ${tone} grid gap-2 px-4 py-3 sm:flex sm:flex-wrap sm:items-baseline sm:justify-between"
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
	## The timeline draws incidents keyed by id, so a feed with an incident
	## that has no id, or with two incidents under one id, is malformed: it
	## is refused here, where it arrives, with what is wrong with it, rather
	## than drawn with an id the feed did not give.
	parse_feed : Str -> Try(List(Incident), Str)
	parse_feed = |payload| {
		if payload == "" {
			return Ok([])
		}
		var $seen = Set.empty()
		var $incidents = []
		for raw in payload.split_on("#") {
			incident = match parse_incident(raw) {
				Ok(parsed) => parsed
				Err(MissingId) => return Err("incident ${($incidents.len() + 1).to_str()} has no id")
			}
			if $seen.contains(incident.id) {
				return Err("two incidents share the id ${incident.id}")
			}
			$seen = $seen.insert(incident.id)
			$incidents = $incidents.append(incident)
		}
		Ok($incidents)
	}

	## One incident, or `MissingId` when its id field is absent or empty: an
	## incident's id is what the timeline knows it by, so none is made up.
	parse_incident : Str -> Try(Incident, [MissingId])
	parse_incident = |raw| {
		parts = raw.split_on("~")
		id = field_at(parts, 0, "")
		if id.is_empty() {
			return Err(MissingId)
		}
		severity = Severity.from_str(field_at(parts, 1, "minor"))
		title = field_at(parts, 2, "Untitled incident")
		updates = parse_updates(id, field_at(parts, 3, ""))
		Ok({ id, severity, title, latest: latest_body(updates), updates })
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
	expect parse_feed("").map_ok(List.len) == Ok(0)

	## An incident takes its severity from the second field of the payload.
	expect {
		incident = parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified")?
		Severity.is_eq(incident.severity, Severity.Major)
	}

	## The headline of an incident is its most recently published update.
	expect parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified").map_ok(|i| i.latest) == Ok("10:20 - Identified")

	## Every published update is kept, so the timeline shows the full history.
	expect parse_incident("inc-42~major~Elevated errors~10:02@Investigating^10:20@Identified").map_ok(|i| i.updates.len()) == Ok(2)

	## A feed whose incident has no id, or two incidents under one id, is
	## refused with what is wrong; distinct ids are read in order.
	expect {
		actual = (
			parse_feed("inc-1~minor~A#inc-2~major~B").map_ok(|list| list.map(|i| i.id)),
			parse_feed("inc-1~minor~A#inc-1~major~B").map_ok(|list| list.len()),
			parse_feed("inc-1~minor~A#~major~B").map_ok(|list| list.len()),
		)
		actual == (Ok(["inc-1", "inc-2"]), Err("two incidents share the id inc-1"), Err("incident 2 has no id"))
	}

	## An update's list key pairs the incident id with the 1-based sequence number.
	expect {
		update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating")?.updates.get(0)?
		update.key == "inc-42#1"
	}

	## The timestamp column holds only the part before the "@" separator.
	expect {
		update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating")?.updates.get(0)?
		update.time == "10:02"
	}

	## The body column holds only the part after the "@" separator.
	expect {
		update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating")?.updates.get(0)?
		update.body == "Investigating"
	}

	## The announcement text joins the sequence number back onto the one-line summary.
	expect {
		update = parse_incident("inc-42~major~Elevated errors~10:02@Investigating")?.updates.get(0)?
		update.text == "inc-42 update 1 - 10:02 - Investigating"
	}

	## A field the feed left out falls back rather than dropping the incident.
	expect parse_incident("inc-7").map_ok(|i| i.title) == Ok("Untitled incident")

	## An incident with no updates yet says so instead of showing an empty line.
	expect latest_body([]) == "no updates yet"

	loading_feed : Feed
	loading_feed = { items: [], status: "Incident feed: loading" }

	ready_feed : List(Incident) -> Feed
	ready_feed = |items| { items, status: "Incident feed: updated" }

	failed_feed : Str -> Feed
	failed_feed = |err| { items: [], status: "Incident feed unavailable (${err})" }

	malformed_feed : Str -> Feed
	malformed_feed = |why| { items: [], status: "Incident feed could not be read: ${why}" }

	## A check result: the parsed payload, or why the refresh did not come
	## back.
	check_of : Try(Str, Engine.HttpError) -> Check
	check_of = |result|
		match result {
			Ok(text) => parse_check(text)
			Err(err) => { health: Health.CheckFailed(Str.inspect(err)), uptime_bps: 0 }
		}

	## A feed result: the parsed timeline, or why it is unavailable.
	feed_of : Try(Str, Engine.HttpError) -> Feed
	feed_of = |result|
		match result {
			Ok(text) =>
				match parse_feed(text) {
					Ok(items) => ready_feed(items)
					Err(why) => malformed_feed(why)
				}
			Err(err) => failed_feed(Str.inspect(err))
		}

	## A malformed feed shows no timeline and says why.
	expect {
		feed = feed_of(Ok("inc-1~minor~A#inc-1~minor~B"))
		(feed.items.len(), feed.status) == (0, "Incident feed could not be read: two incidents share the id inc-1")
	}

	## A refresh that timed out is reported by its typed error.
	expect check_detail("", check_of(Err(Timeout))) == "Last refresh failed: Timeout"

	## Each answer lands in the current round as a figure, or as no figure
	## when the check failed or had nothing to say.
	expect {
		api = record_uptime(first_history, Api, parse_check("degraded|97.40"))
		web = record_uptime(api, Web, check_of(Err(Timeout)))
		history = record_uptime(web, Database, parse_check("garbled"))
		expected : List(Round)
		expected = [{ api: Measured(9740), web: Unmeasured, database: Unmeasured, notifications: Awaiting }]
		Str.inspect(history) == Str.inspect(expected)
	}

	## The history keeps the last `history_limit` rounds, newest last, so it
	## stops growing once full.
	expect {
		var $history = record_uptime(first_history, Api, parse_check("operational|99.00"))
		for _round in 0.U64..<history_limit {
			$history = start_round($history)
		}
		actual =
			\\length: ${$history.len().to_str()}
			\\oldest api: ${Str.inspect(($history.first() ?? awaiting_round).api)}
		expected =
			\\length: 60
			\\oldest api: Awaiting
		actual == expected
	}
}

awaiting_round : Status.Round
awaiting_round = { api: Awaiting, web: Awaiting, database: Awaiting, notifications: Awaiting }

## What a check says of the service's uptime: a figure only when the
## service reported a health it measured.
uptime_of : Status.Check -> Status.Uptime
uptime_of = |check|
	match check.health {
		Operational | Degraded | Outage => Measured(check.uptime_bps)
		Unknown | CheckFailed(_) => Unmeasured
	}

with_uptime : Status.Round, Status.Service, Status.Uptime -> Status.Round
with_uptime = |round, service, uptime|
	match service {
		Api => { ..round, api: uptime }
		Web => { ..round, web: uptime }
		Database => { ..round, database: uptime }
		Notifications => { ..round, notifications: uptime }
	}
