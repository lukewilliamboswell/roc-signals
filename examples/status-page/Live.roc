import pf.Engine exposing [Cell, Elem, Signal, State]
import pf.Html
import pf.Port
import Charts
import Latency
import Parts

## The live latency panel: the readings the page has kept of the feed
## (`Latency`), where the subscription stands, and what the reader chose.
## The type, its pure operations and its view are this one module.
##
## `window` holds the readings kept, and `drawn` the copy the chart shows,
## which `draw` brings up to date on the page's redraw tick: a backlog of
## readings drains as back-to-back turns with no paint between them, and
## redrawing the chart for each would cost a frame per reading. `received`
## counts the readings kept; `dropped` is what the feed last said it
## dropped; `rejected` counts messages the page refused at the door
## (unreadable, too large, or out of order). `generation` changes to
## subscribe afresh after the feed ended, and `outage` holds what the
## reader asked the feed to do.
##
## Only this panel reads any of it, so the view keeps it in a state of its
## own rather than in the app's store: a message of the feed is a turn that
## writes that state alone, and the checks, the cards and the uptime
## history do no work for it. What the panel needs of the rest of the page
## (whether it is showing) it is handed as a cell.
Live :: {
	window : List(Latency.Point),
	drawn : List(Latency.Point),
	received : U64,
	dropped : U32,
	rejected : U64,
	feed : Feed,
	mode : Mode,
	generation : U64,
	outage : Engine.Outbox({ seconds : U32 }),
}.{

	## Where the subscription stands: asked for and not yet heard from
	## (`Connecting`), delivering (`Streaming`), or ended by the feed or
	## refused by the page's in-flight bound (`Ended`).
	Feed : [Connecting, Streaming, Ended(Port.Error)]

	## What the reader chose: follow the feed, or stop it to read the chart.
	Mode : [Following, Paused]

	## What the view is handed, in a store whose type is `st`: whether
	## the page is showing.
	Props(st) : { visible : Cell(st, Bool) }

	## The panel before the feed has said anything.
	init : Live
	init = { window: [], drawn: [], received: 0, dropped: 0, rejected: 0, feed: Connecting, mode: Following, generation: 0, outage: Engine.outbox({}) }

	## One message of the subscription, checked at the door. A reading is
	## kept only if its sequence number comes after the last one kept and its
	## time is one the chart can place; anything else is counted as
	## rejected, and so is a message the port could not read. `Closed` and
	## `Threw` end the feed; a subscription the in-flight bound refused never
	## began.
	receive : Live, Try(Latency.Reading, Port.Error) -> Live
	receive = |live, message|
		match message {
			Ok(reading) =>
				match Latency.taken(live.window, reading) {
					Ok(window) => { ..live, window, received: live.received + 1, dropped: reading.dropped, feed: Streaming }
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

	## Ask the feed to drop its connection for `Latency.outage_seconds`.
	drop_connection : Live -> Live
	drop_connection = |live| { ..live, outage: live.outage.post({ seconds: Latency.outage_seconds }) }

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

	## The panel, with a state of its own for the feed.
	view : Props(st) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props| Engine.state(Live.init, |live| panel(live, props.visible.signal()))
}

## The panel over its state. The subscription lives in a branch that is
## mounted only while the page is visible and the reader follows the feed,
## so hiding the page or pausing disposes it, which stops the feed's
## JavaScript; showing or resuming subscribes afresh.
panel : State(ctx, Live), Signal(ctx, Bool) -> Elem(ctx)
panel = |live, visible| {
	lv = live.signal()
	following = visible.map2(lv, |showing, l| showing and l.mode == Following)
	Html.section(
		"Live latency",
		Parts.panel_class,
		[
			Html.div(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.h2("Live p95 latency", "panel-title"),
					Html.p_s(lv.map(Live.status_text), [Engine.class("hint"), Engine.test_id("live-status")]),
				],
			),
			Html.div(
				"stat-grid",
				[
					Parts.metric("live-api-p95", "API p95 now", lv.map(Live.latest_api_text)),
					Parts.metric("live-received", "Readings received", lv.map(|l| l.received.to_str())),
					Parts.metric("live-dropped", "Dropped by the feed", lv.map(|l| l.dropped.to_str())),
					Parts.metric("live-rejected", "Rejected at the door", lv.map(|l| l.rejected.to_str())),
				],
			),
			# The chart reads the drawn copy through a `derive`, so a
			# reading builds no figure: the redraw tick below does, at
			# most four times a second however fast readings arrive.
			Engine.derive(
				lv.map(|l| l.drawn),
				|drawn| Engine.element("plume-chart", [Engine.class("block"), Engine.attr("role", "img"), Html.aria_label("Live p95 latency by service"), Engine.test_id("latency-chart"), Engine.attr_s("data-figure", drawn.map(Charts.latency))], []),
			),
			Html.div(
				"toolbar",
				[
					Engine.when(
						lv.map(|l| l.mode == Following),
						|| Html.button("Pause the feed", [Engine.class("button-secondary")], live.update(Live.toggle_mode)),
						|| Html.button("Resume the feed", [Engine.class("button-primary")], live.update(Live.toggle_mode)),
					),
					Html.button("Drop the connection for ${Latency.outage_seconds.to_str()} s", [Engine.class("button-secondary")], live.update(Live.drop_connection)),
					Engine.when(
						lv.map(Live.has_ended),
						|| Html.button("Reconnect", [Engine.class("button-primary")], live.update(Live.reconnect)),
						|| Html.div("hidden", []),
					),
				],
			),
			# The runtime's own account of the port, drawn by the
			# example's `feed-monitor.mjs` from `runtime.monitor`.
			Engine.element("latency-feed-monitor", [Engine.attr("data-port", Latency.readings_name)], []),
			Engine.when(
				following,
				|| Html.div(
					"hidden",
					[
						Engine.watch_latest(
							lv.map(|l| l.generation),
							|_| [Latency.readings.subscribe({ seed: Latency.seed })],
							live.on_result(|l, _, res| Live.receive(l, Latency.readings.message(res))),
						),
						Engine.watch(Engine.const(Live.redraw_ms), |ms| [Interval(ms)], live.on_result(|l, _, _| Live.draw(l))),
					],
				),
				|| Html.div("hidden", []),
			),
			Engine.on_post(lv.map(|l| l.outage), |cut| [Latency.disconnect.send(cut)], Engine.ignore({})),
		],
	)
}

reading : U32, U32 -> Latency.Reading
reading = |seq, api| { seq, at_ms: 1_762_852_800_000 + seq.to_i64() * 250, p95_ms: { api, web: 140, database: 110, notifications: 180 }, dropped: 0 }

## Readings the door takes are counted as received; one out of order and a
## message the port could not read are counted as rejected.
expect {
	var $live = Live.init
	for message in [Ok(reading(1, 120)), Ok(reading(2, 130)), Ok(reading(5, 140)), Ok(reading(4, 150)), Err(Undecodable("x"))] {
		$live = Live.receive($live, message)
	}
	actual =
		\\kept: ${Str.inspect($live.window.map(|p| p.seq))}
		\\received: ${$live.received.to_str()}
		\\rejected: ${$live.rejected.to_str()}
		\\api: ${Live.latest_api_text($live)}
	expected =
		\\kept: [1, 2, 5]
		\\received: 3
		\\rejected: 2
		\\api: 140 ms
	actual == expected
}

## The chart shows the window only once it is drawn; pausing draws it.
expect {
	taken = Live.receive(Live.init, Ok(reading(1, 120)))
	actual =
		\\before: ${taken.drawn.len().to_str()}
		\\drawn: ${Live.draw(taken).drawn.len().to_str()}
		\\paused: ${Live.toggle_mode(taken).drawn.len().to_str()} ${Live.status_text(Live.toggle_mode(taken))}
	expected =
		\\before: 0
		\\drawn: 1
		\\paused: 1 Paused: the feed is unsubscribed until you resume
	actual == expected
}

## The feed ending shows on the status line, and the page offers to
## reconnect.
expect {
	ended = Live.receive(Live.init, Err(Threw("socket reset")))
	actual =
		\\status: ${Live.status_text(ended)}
		\\offers reconnect: ${Str.inspect(Live.has_ended(ended))}
		\\after reconnect: ${Live.status_text(Live.reconnect(ended))}
	expected =
		\\status: The feed failed: socket reset
		\\offers reconnect: True
		\\after reconnect: Connecting to the latency feed
	actual == expected
}
