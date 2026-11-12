import pf.Engine
import pf.Port
import plume.Time

## The live p95 latency feed: the port it arrives on, the readings it
## carries, and the bounded window of them the page keeps and draws. The
## panel that follows the feed is `Live`.
##
## The feed is a subscription. Its JavaScript, `ports.mjs` beside this
## module, is a seeded simulation of a metrics stream: a reading of every
## service's p95 latency every 250 ms, with a scripted incident in which
## the API's latency climbs well past its objective and recovers. Each
## reading is one message, and each message is one turn of the app.
##
## Why `Every(16)` and not `Latest`: every reading is a point of the
## series, so a reading replaced before the page saw it would be a hole in
## the chart that nothing reports. `Latest` suits a value whose newest
## state is all that matters (a revision, a status), which a time series
## is not. `Every(16)` lets up to 16 readings (four seconds of the feed)
## wait while the page is busy, bounds what waits, and tells the
## JavaScript when the page is full: `emit` returns `false`. The
## simulation then holds the readings back and offers them again on the
## next animation frame, so a backlog drains at the page's pace instead of
## being lost; only when its own buffer of 64 readings overflows does it
## drop the oldest, and it says how many in every reading (`dropped`).
Latency := [].{

	## Each service's p95 latency over one interval, in whole milliseconds.
	P95 : { api : U32, web : U32, database : U32, notifications : U32 }

	## One message of the feed: its sequence number (consecutive while
	## nothing is lost), when the interval ended (milliseconds since the Unix
	## epoch, UTC), each service's p95, and how many readings the feed has
	## dropped since this subscription began because neither the page nor
	## its own buffer had room for them.
	Reading : { seq : U32, at_ms : I64, p95_ms : P95, dropped : U32 }

	## The live feed. The argument seeds the simulation, so a seed always
	## tells the same story.
	readings : Port.Subscription({ seed : U32 }, Reading)
	readings = Port.subscription({ name: Latency.readings_name, delivery: Every(16) })

	## The feed's port name, which the page also gives the element that
	## shows the runtime's monitor record for it.
	readings_name : Str
	readings_name = "roc-signals.example/status-page/latency"

	## Tell the feed to lose its connection for `seconds` and then replay
	## what it buffered meanwhile: a burst the page's bound pushes back on.
	disconnect : Port.Command({ seconds : U32 })
	disconnect = Port.command({ name: "roc-signals.example/status-page/disconnect" })

	## The program's entry for `Program.with_ports`: both ports, once.
	registrations : List(Engine.PortRegistration)
	registrations = [Latency.readings.registration(), Latency.disconnect.registration()]

	## The seed the page subscribes with.
	seed : U32
	seed = 2026

	## How long the page lets the connection drop when asked.
	outage_seconds : U32
	outage_seconds = 20

	## How many readings the page keeps: 30 seconds of the feed. A reading
	## beyond it lets the oldest go, so the window and the chart drawn from
	## it stay this size however long the page is open.
	window_limit : U64
	window_limit = 120

	## The API's latency objective: its p95 should stay at or under this.
	slo_ms : U32
	slo_ms = 300

	## A reading the page kept: its instant on the chart's time axis, and
	## whether a reading is missing just before it (`Gap`), so the line
	## breaks there rather than drawing across the hole.
	Point : { seq : U32, at : Time, p95_ms : P95, from_previous : [Connected, Gap] }

	## The window with a reading added at the door, letting the oldest go
	## beyond `window_limit`. A reading is refused when its sequence number
	## is not after the newest kept, or its time is outside what a chart can
	## show.
	taken : List(Point), Reading -> Try(List(Point), [OutOfOrder, TimeOutOfRange(I64)])
	taken = |window, reading| {
		point = admit(window, reading)?
		grown = window.append(point)
		if grown.len() > Latency.window_limit {
			Ok(grown.drop_first(grown.len() - Latency.window_limit))
		} else {
			Ok(grown)
		}
	}

	## The stretches of the window where the API's p95 is over its
	## objective, each from its first reading over to the first reading
	## back under (or the newest reading, while it lasts). A missing reading
	## ends a stretch: the page cannot say what happened in the hole.
	breaches : List(Point) -> List({ start : Time, end : Time })
	breaches = |window| {
		var $bands = []
		var $open = Closed
		for point in window {
			over = point.p95_ms.api > Latency.slo_ms
			$open =
				match $open {
					Open({ start, last }) =>
						if point.from_previous == Gap {
							$bands = $bands.append({ start, end: last })
							if (over) Open({ start: point.at, last: point.at }) else Closed
						} else if over {
							Open({ start, last: point.at })
						} else {
							$bands = $bands.append({ start, end: point.at })
							Closed
						}
					Closed => if (over) Open({ start: point.at, last: point.at }) else Closed
				}
		}
		match $open {
			Open({ start, last }) => $bands.append({ start, end: last })
			Closed => $bands
		}
	}
}

## A reading as a point of the window.
admit : List(Latency.Point), Latency.Reading -> Try(Latency.Point, [OutOfOrder, TimeOutOfRange(I64)])
admit = |window, reading| {
	at = Time.from_epoch_millis(reading.at_ms)?
	match window.last() {
		Ok(newest) if reading.seq <= newest.seq => Err(OutOfOrder)
		Ok(newest) => Ok({ seq: reading.seq, at, p95_ms: reading.p95_ms, from_previous: if (reading.seq == newest.seq + 1) Connected else Gap })
		Err(_) => Ok({ seq: reading.seq, at, p95_ms: reading.p95_ms, from_previous: Connected })
	}
}

reading : U32, U32 -> Latency.Reading
reading = |seq, api| { seq, at_ms: 1_762_852_800_000 + seq.to_i64() * 250, p95_ms: { api, web: 140, database: 110, notifications: 180 }, dropped: 0 }

## The window after `readings` arrive in turn, skipping any the door refuses.
window_of : List(Latency.Reading) -> List(Latency.Point)
window_of = |readings| readings.fold([], |window, message| Latency.taken(window, message) ?? window)

## Consecutive readings join; a missing sequence number breaks the line;
## a reading that does not come after the newest is refused at the door.
expect {
	window = window_of([reading(1, 120), reading(2, 130), reading(5, 140)])
	actual =
		\\kept: ${Str.inspect(window.map(|p| p.seq))}
		\\joins: ${Str.inspect(window.map(|p| p.from_previous))}
		\\late: ${Str.inspect(Latency.taken(window, reading(4, 150)).map_ok(|w| w.len()))}
	expected =
		\\kept: [1, 2, 5]
		\\joins: [Connected, Connected, Gap]
		\\late: Err(OutOfOrder)
	actual == expected
}

## The window keeps the newest `window_limit` readings, so it stops growing.
expect {
	var $window = []
	for seq in 1.U32..=200 {
		$window = Latency.taken($window, reading(seq, 120)) ?? $window
	}
	actual = "${$window.len().to_str()} from ${Str.inspect($window.first().map_ok(|p| p.seq))}"
	actual == "120 from Ok(81)"
}

## A stretch over the objective is a band from its first reading over to
## the first back under; a gap ends one; one still open ends at the newest.
expect {
	window = window_of([reading(1, 120), reading(2, 400), reading(3, 500), reading(4, 200), reading(6, 450), reading(8, 600), reading(9, 700)])
	actual = Latency.breaches(window).map(|band| "${band.start.to_str()}..${band.end.to_str()}")
	actual
		== [
			"2025-11-11 09:20:00.500..2025-11-11 09:20:01",
			"2025-11-11 09:20:01.500..2025-11-11 09:20:01.500",
			"2025-11-11 09:20:02..2025-11-11 09:20:02.250",
		]
}
