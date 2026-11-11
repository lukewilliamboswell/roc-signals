import pf.Engine
import pf.Port
import plume.Time

## The live p95 latency feed: the port it arrives on, the readings it
## carries, and the bounded window of them the page keeps and draws.
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

	## Where the subscription stands: asked for and not yet heard from
	## (`Connecting`), delivering (`Streaming`), or ended by the feed or
	## refused by the page's in-flight bound (`Ended`).
	Feed : [Connecting, Streaming, Ended(Port.Error)]

	## What the reader chose: follow the feed, or stop it to read the chart.
	Mode : [Following, Paused]

	## The live panel's state. `window` holds the readings kept, and
	## `drawn` the copy the chart shows, which `draw` brings up to date on
	## the page's redraw tick: a backlog of readings drains as back-to-back
	## turns with no paint between them, and redrawing the chart for each
	## would cost a frame per reading. `received` counts the readings kept;
	## `dropped` is what the feed last said it dropped; `rejected` counts
	## messages the page refused at the door (unreadable, too large, or out
	## of order). `generation` changes to subscribe afresh after the feed
	## ended, and `outage` holds what the reader asked the feed to do.
	Live : {
		window : List(Point),
		drawn : List(Point),
		received : U64,
		dropped : U32,
		rejected : U64,
		feed : Feed,
		mode : Mode,
		generation : U64,
		outage : Engine.Outbox({ seconds : U32 }),
	}

	## The panel before the feed has said anything.
	initial : Live
	initial = { window: [], drawn: [], received: 0, dropped: 0, rejected: 0, feed: Connecting, mode: Following, generation: 0, outage: Engine.outbox({}) }

	## One message of the subscription, checked at the door. A reading is
	## kept only if its sequence number comes after the last one kept and its
	## time is one the chart can place; anything else is counted as
	## rejected, and so is a message the port could not read. `Closed` and
	## `Threw` end the feed; a subscription the in-flight bound refused never
	## began.
	receive : Live, Try(Reading, Port.Error) -> Live
	receive = |live, message|
		match message {
			Ok(reading) =>
				match admit(live.window, reading) {
					Ok(point) => { ..live, window: keep(live.window, point), received: live.received + 1, dropped: reading.dropped, feed: Streaming }
					Err(_) => { ..live, rejected: live.rejected + 1, feed: Streaming }
				}
			Err(Closed) => { ..live, feed: Ended(Closed) }
			Err(Threw(why)) => { ..live, feed: Ended(Threw(why)) }
			Err(Refused) => { ..live, feed: Ended(Refused) }
			Err(Undecodable(_)) | Err(TooLarge) | Err(Timeout) => { ..live, rejected: live.rejected + 1 }
		}

	## Follow the feed again after it ended: a new generation subscribes
	## afresh.
	reconnect : Live -> Live
	reconnect = |live| { ..live, feed: Connecting, generation: live.generation + 1 }

	## Pause or resume. Resuming subscribes afresh; the feed is live, so
	## the time spent paused is a gap in the chart.
	toggle_mode : Live -> Live
	toggle_mode = |live|
		match live.mode {
			Following => { ..live, mode: Paused, drawn: live.window }
			Paused => { ..live, mode: Following, feed: Connecting }
		}

	## How often the chart is redrawn from the window while following.
	redraw_ms : U32
	redraw_ms = 250

	## The chart catches up with the window.
	draw : Live -> Live
	draw = |live| { ..live, drawn: live.window }

	## Ask the feed to drop its connection for `outage_seconds`.
	drop_connection : Live -> Live
	drop_connection = |live| { ..live, outage: live.outage.post({ seconds: Latency.outage_seconds }) }

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

	## The status line over the chart.
	status_text : Live -> Str
	status_text = |live|
		match live.mode {
			Paused => "Paused: the feed is unsubscribed until you resume"
			Following =>
				match live.feed {
					Connecting => "Connecting to the latency feed"
					Streaming => "Live: a reading of every service's p95 every 250 ms"
					Ended(Closed) => "The feed closed"
					Ended(Threw(why)) => "The feed failed: ${why}"
					Ended(Refused) => "The feed could not start: too many requests were in flight"
					Ended(_) => "The feed ended"
				}
		}

	## Whether the feed has ended, so the page offers to reconnect.
	has_ended : Live -> Bool
	has_ended = |live|
		match live.feed {
			Ended(_) => live.mode == Following
			_ => Bool.False
		}

	## The newest reading of the API's p95, for the panel's figure.
	latest_api_text : Live -> Str
	latest_api_text = |live|
		match live.window.last() {
			Ok(point) => "${point.p95_ms.api.to_str()} ms"
			Err(_) => "no reading yet"
		}
}

## A reading as a point of the window: refused when its sequence number is
## not after the newest kept, or its time is outside what a chart can show.
admit : List(Latency.Point), Latency.Reading -> Try(Latency.Point, [OutOfOrder, TimeOutOfRange(I64)])
admit = |window, reading| {
	at = Time.from_epoch_millis(reading.at_ms)?
	match window.last() {
		Ok(newest) if reading.seq <= newest.seq => Err(OutOfOrder)
		Ok(newest) => Ok({ seq: reading.seq, at, p95_ms: reading.p95_ms, from_previous: if (reading.seq == newest.seq + 1) Connected else Gap })
		Err(_) => Ok({ seq: reading.seq, at, p95_ms: reading.p95_ms, from_previous: Connected })
	}
}

## The window with `point` added, letting the oldest go beyond the limit.
keep : List(Latency.Point), Latency.Point -> List(Latency.Point)
keep = |window, point| {
	grown = window.append(point)
	if grown.len() > Latency.window_limit {
		grown.drop_first(grown.len() - Latency.window_limit)
	} else {
		grown
	}
}

reading : U32, U32 -> Latency.Reading
reading = |seq, api| { seq, at_ms: 1_762_852_800_000 + seq.to_i64() * 250, p95_ms: { api, web: 140, database: 110, notifications: 180 }, dropped: 0 }

## Consecutive readings join; a missing sequence number breaks the line;
## a reading that does not come after the newest is refused at the door.
expect {
	var $live = Latency.initial
	for message in [Ok(reading(1, 120)), Ok(reading(2, 130)), Ok(reading(5, 140)), Ok(reading(4, 150)), Err(Undecodable("x"))] {
		$live = Latency.receive($live, message)
	}
	actual =
		\\kept: ${Str.inspect($live.window.map(|p| p.seq))}
		\\joins: ${Str.inspect($live.window.map(|p| p.from_previous))}
		\\received: ${$live.received.to_str()}
		\\rejected: ${$live.rejected.to_str()}
	expected =
		\\kept: [1, 2, 5]
		\\joins: [Connected, Connected, Gap]
		\\received: 3
		\\rejected: 2
	actual == expected
}

## The window keeps the newest `window_limit` readings, so it stops growing.
expect {
	var $live = Latency.initial
	for seq in 1.U32..=200 {
		$live = Latency.receive($live, Ok(reading(seq, 120)))
	}
	actual = "${$live.window.len().to_str()} from ${Str.inspect($live.window.first().map_ok(|p| p.seq))}"
	actual == "120 from Ok(81)"
}

## A stretch over the objective is a band from its first reading over to
## the first back under; a gap ends one; one still open ends at the newest.
expect {
	var $live = Latency.initial
	for message in [reading(1, 120), reading(2, 400), reading(3, 500), reading(4, 200), reading(6, 450), reading(8, 600), reading(9, 700)] {
		$live = Latency.receive($live, Ok(message))
	}
	actual = Latency.breaches($live.window).map(|band| "${band.start.to_str()}..${band.end.to_str()}")
	actual
		== [
			"2025-11-11 09:20:00.500..2025-11-11 09:20:01",
			"2025-11-11 09:20:01.500..2025-11-11 09:20:01.500",
			"2025-11-11 09:20:02..2025-11-11 09:20:02.250",
		]
}

## The feed ending shows on the status line, and the page offers to
## reconnect.
expect {
	ended = Latency.receive(Latency.initial, Err(Threw("socket reset")))
	actual =
		\\status: ${Latency.status_text(ended)}
		\\offers reconnect: ${Str.inspect(Latency.has_ended(ended))}
		\\after reconnect: ${Latency.status_text(Latency.reconnect(ended))}
	expected =
		\\status: The feed failed: socket reset
		\\offers reconnect: True
		\\after reconnect: Connecting to the latency feed
	actual == expected
}
