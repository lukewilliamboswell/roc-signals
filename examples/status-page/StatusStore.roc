import pf.Engine exposing [Cell, Signal]
import Status

## The Status Page's store: what the checks last said, held at the root and
## read from any depth with no `lift`, and every transition over it as a
## pure function that returns its writes.
##
## - `serial`: which refresh is the current one. The mount is refresh 0;
##   each check is a `latest` site on this cell, so a new refresh cancels
##   the checks of the one before it.
## - `requests`: how many refreshes the reader asked for with the button.
## - `visible`: whether the page is showing. Polling and the live feed
##   stop while it is not.
## - `checks`: each service's latest check, a cell each, so an answer
##   wakes its own card and the rollup and no other card.
## - `feed`: the incident feed as last answered.
## - `history`: each refresh's uptime for each service, the newest last.
##
## The live latency panel's state is not here: only that panel reads it,
## so it is local to it (`Live`).
StatusStore := [StatusPage].{

	store = Engine.store(
		StatusStore.StatusPage,
		{
			serial: Engine.cell(0.U64),
			requests: Engine.cell(0.U64),
			visible: Engine.cell(Bool.True),
			checks: {
				api: Engine.cell(Status.pending_check),
				web: Engine.cell(Status.pending_check),
				database: Engine.cell(Status.pending_check),
				notifications: Engine.cell(Status.pending_check),
			}.Engine.Cells,
			feed: Engine.cell(Status.loading_feed),
			history: Engine.cell(Status.first_history),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = StatusStore.store.handles()

	## The store a page starts with: showing or hidden, as the browser says.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| StatusStore.store.with_initial(StatusStore.h.visible, boot.visible)

	## The cell that holds a service's latest check.
	cell_of : Status.Service -> Cell(_, Status.Check)
	cell_of = |service|
		match service {
			Api => StatusStore.h.checks.api
			Web => StatusStore.h.checks.web
			Database => StatusStore.h.checks.database
			Notifications => StatusStore.h.checks.notifications
		}

	## The four checks as one rollup. The banner, the counts and the overall
	## uptime all read this one value, so the page can never show "All
	## systems operational" beside a red component.
	totals : {} -> Signal(ctx, Status.Tally)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	totals = |{}| {
		tally = |service| StatusStore.cell_of(service).signal().map(Status.tally_of)
		tally(Api).map2(tally(Web), Status.add_tally).map2(tally(Database).map2(tally(Notifications), Status.add_tally), Status.add_tally)
	}

	## The next refresh starts, and with it a round of the uptime history:
	## an interval tick, or the page showing again.
	refreshed : List(Engine.Write(_))
	refreshed = [
		StatusStore.h.serial.change(|serial| serial + 1),
		StatusStore.h.history.change(Status.start_round),
	]

	## The reader pressed "Refresh now": a refresh, counted.
	requested : List(Engine.Write(_))
	requested = StatusStore.refreshed.concat([StatusStore.h.requests.change(|count| count + 1)])

	## A service's check answered: its card shows it, and the current round
	## of the history records its uptime.
	answered : Status.Service, Status.Check -> List(Engine.Write(_))
	answered = |service, check| [
		StatusStore.cell_of(service).put(check),
		StatusStore.h.history.change(|history| Status.record_uptime(history, service, check)),
	]

	## The page's visibility changed from `was` to `now`. Becoming visible
	## refreshes at once.
	shown : Bool, Bool -> List(Engine.Write(_))
	shown = |was, now| {
		seen = [StatusStore.h.visible.put(now)]
		if (now and !was) seen.concat(StatusStore.refreshed) else seen
	}
}

## A refresh moves the serial on and starts a round awaiting its answers;
## one the reader asked for is counted too.
expect {
	ticked = StatusStore.store.after(StatusStore.refreshed)
	pressed = ticked.after(StatusStore.requested)
	actual =
		\\serial: ${ticked.read(StatusStore.h.serial).to_str()}, ${pressed.read(StatusStore.h.serial).to_str()}
		\\requests: ${ticked.read(StatusStore.h.requests).to_str()}, ${pressed.read(StatusStore.h.requests).to_str()}
		\\rounds: ${ticked.read(StatusStore.h.history).len().to_str()}, ${pressed.read(StatusStore.h.history).len().to_str()}
	expected =
		\\serial: 1, 2
		\\requests: 0, 1
		\\rounds: 2, 3
	actual == expected
}

## A check's answer lands on its own service's card and in the current
## round of the history, and on no other card.
expect {
	degraded = Status.parse_check("degraded|97.40")
	after = StatusStore.store.after(StatusStore.refreshed).after(StatusStore.answered(Web, degraded))
	actual =
		\\web: ${Status.health_text(after.read(StatusStore.h.checks.web).health)} ${Status.uptime_text(after.read(StatusStore.h.checks.web))}
		\\api: ${Status.health_text(after.read(StatusStore.h.checks.api).health)}
		\\history: ${Str.inspect(after.read(StatusStore.h.history).map(|round| round.web))}
	expected =
		\\web: Degraded 97.40%
		\\api: Awaiting first check
		\\history: [Awaiting, Measured(9740)]
	actual == expected
}

## Becoming visible refreshes at once; hiding, or a repeated report of the
## same visibility, starts nothing.
expect {
	hidden = StatusStore.store.after(StatusStore.shown(Bool.True, Bool.False))
	back = hidden.after(StatusStore.shown(Bool.False, Bool.True))
	again = back.after(StatusStore.shown(Bool.True, Bool.True))
	actual =
		\\visible: ${Str.inspect(hidden.read(StatusStore.h.visible))}, ${Str.inspect(back.read(StatusStore.h.visible))}, ${Str.inspect(again.read(StatusStore.h.visible))}
		\\serial: ${hidden.read(StatusStore.h.serial).to_str()}, ${back.read(StatusStore.h.serial).to_str()}, ${again.read(StatusStore.h.serial).to_str()}
	expected =
		\\visible: False, True, True
		\\serial: 0, 1, 1
	actual == expected
}
