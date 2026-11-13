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
	retry : Retry,
	stopped : [Exhausted, Refused],
	rng : U64,
	visible : Bool,
	after : U32,
	mode : Mode,
	generation : U64,
	outage : Engine.Outbox({}),
}.{

	## A connection waits on one scoped timer between attempts. Opened
	## alone leaves it Connecting; the first accepted reading makes it Live.
	Retry : [Live, Connecting(U32), Waiting({ attempt : U32, delay_ms : U32 }), GaveUp]

	## What the reader chose: follow the feed, or stop it to read the chart.
	Mode : [Following, Paused]

	## Boot seeds the jitter; visibility is shared with the page's checks.
	Props(st) : { visible : Cell(st, Bool), seed : U128, initially_visible : Bool }

	## The panel before the feed has said anything.
	init : Live
	init = { window: [], drawn: [], received: 0, dropped: 0, rejected: 0, retry: Connecting(0), stopped: Exhausted, rng: 0, visible: True, after: 0, mode: Following, generation: 0, outage: Engine.outbox({}) }

	## Both halves of the document seed affect this app's random stream.
	seeded : { seed : U128, visible : Bool } -> Live
	seeded = |{ seed, visible }| { ..Live.init, rng: seed.to_u64_wrap().bitwise_xor(seed.shr_zf_wrap(64).to_u64_wrap()), visible }

	## Exponential delay for attempts one through five, with at most a
	## quarter of its base added as jitter. Attempts are checked by lost.
	backoff : { attempt : U32, random : U64 } -> U32
	backoff = |{ attempt, random }| {
		base : U32
		base = match attempt {
			1 => 1000
			2 => 2000
			3 => 4000
			4 => 8000
			5 => 16000
			_ => crash "Live.backoff: retry attempt is outside one through five"
		}
		base + (random % (base // 4 + 1).to_u64()).to_u32_wrap()
	}

	## A message is decoded once at the door. A connection ending starts
	## a bounded retry; a subscription refused at admission needs a person.
	receive : Live, Try(Latency.Message, Port.Error) -> Live
	receive = |live, message| match message {
		Ok(Opened) => live
		Ok(Event(reading)) => match Latency.taken(live.window, reading) {
			Ok(window) => { ..live, window, received: live.received + 1, dropped: reading.dropped, retry: Live }
			Err(_) => { ..live, rejected: live.rejected + 1 }
		}
		Err(Closed) | Err(Threw(_)) => lost(live)
		Err(Refused) => { ..live, retry: GaveUp, stopped: Refused }
		Err(Undecodable(_)) | Err(TooLarge) | Err(Timeout) => { ..live, rejected: live.rejected + 1 }
	}

	## A timer fires a new attempt. Refusal stops here, rather than
	## retrying into the same full in-flight table.
	retried : Live, Try(I64, [Refused]) -> Live
	retried = |live, result| match (live.retry, result) {
		(Waiting({ attempt, delay_ms: _ }), Ok(_)) => { ..live, retry: Connecting(attempt), generation: live.generation + 1, after: last_seq(live.window) }
		(Waiting(_), Err(Refused)) => { ..live, retry: GaveUp, stopped: Refused }
		_ => live
	}

	## Manual reconnect starts a fresh budget and resumes after the last
	## reading kept. Changing the generation supersedes any connection.
	reconnect : Live -> Live
	reconnect = |live| { ..live, retry: Connecting(0), generation: live.generation + 1, after: last_seq(live.window) }

	## Hiding cancels a waiting timer. Showing starts a fresh connection
	## after the last kept reading, rather than continuing an old wait.
	shown : Live, Bool -> Live
	shown = |live, visible| if (visible) { ..Live.reconnect(live), visible } else { ..live, visible }

	## Pausing draws the current window and disposes the connection or
	## waiting timer. Resuming starts a fresh retry budget.
	toggle_mode : Live -> Live
	toggle_mode = |live| match live.mode {
		Following => { ..live, mode: Paused, drawn: live.window }
		Paused => { ..Live.reconnect(live), mode: Following }
	}

	## How often the chart is redrawn from the window while following.
	redraw_ms : U32
	redraw_ms = 250

	## The chart catches up with the window.
	draw : Live -> Live
	draw = |live| { ..live, drawn: live.window }

	## Ask the feed to end the connection; reconnect policy stays here.
	drop_connection : Live -> Live
	drop_connection = |live| { ..live, outage: live.outage.post({}) }

	## The status line over the chart.
	status_text : Live -> Str
	status_text = |live|
		match live.mode {
			Paused => "Paused: the feed is unsubscribed until you resume"
			Following =>
				match live.retry {
					Connecting(_) => "Connecting to the latency feed"
					Live => "Live: a reading of every service's p95 every 250 ms"
					Waiting({ attempt, delay_ms }) => "Connection lost: reconnecting in ${seconds_text(delay_ms)} s (attempt ${attempt.to_str()})"
					GaveUp => match live.stopped {
						Exhausted => "Gave up after 5 attempts"
						Refused => "Reconnect stopped: too many requests were in flight"
					}
				}
		}

	## A stopped connection needs a manual restart. Waiting retries itself.
	has_ended : Live -> Bool
	has_ended = |live| live.retry == GaveUp and live.mode == Following

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
	view = |props| Engine.state(Live.seeded({ seed: props.seed, visible: props.initially_visible }), |live| panel(live, props.visible.signal()))
}

## The panel over its state. The subscription lives in a branch that is
## mounted only while the page is visible and the reader follows the feed,
## so hiding the page or pausing disposes it, which stops the feed's
## JavaScript; showing or resuming subscribes afresh.
panel : State(ctx, Live), Signal(ctx, Bool) -> Elem(ctx)
panel = |live, visible| {
	lv = live.signal()
	following = visible.map2(lv, |showing, l| showing and l.visible and l.mode == Following)
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
						|| Html.button("Pause the feed", [Engine.class("button-ghost")], live.update(Live.toggle_mode)),
						|| Html.button("Resume the feed", [Engine.class("button-primary")], live.update(Live.toggle_mode)),
					),
					Html.button("Drop the connection", [Engine.class("button-ghost")], live.update(Live.drop_connection)),
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
						Engine.when(
							lv.map(
								|l| match l.retry {
									Waiting(_) | GaveUp => False
									_ => True
								},
							),
							|| Engine.watch_latest(
								lv.map(|l| { generation: l.generation, after: l.after }),
								|issue| [Latency.readings.ask({ seed: Latency.seed, after: issue.after })],
								live.on_result(|l, _, res| Live.receive(l, res)),
							),
							|| Html.div("hidden", []),
						),
						Engine.when(
							lv.map(
								|l| match l.retry {
									Waiting(_) => True
									_ => False
								},
							),
							|| Engine.watch(
								lv.map(
									|l| match l.retry {
										Waiting(wait) => wait.delay_ms
										_ => 0
									},
								),
								|ms| [Engine.timer(ms)],
								live.on_result(|l, _, res| Live.retried(l, res)),
							),
							|| Html.div("hidden", []),
						),
						Engine.when(
							lv.map(
								|l| match l.retry {
									Waiting(_) | GaveUp => False
									_ => True
								},
							),
							|| Engine.watch(Engine.const(Live.redraw_ms), |ms| [Engine.interval(ms)], live.on_result(|l, _, _| Live.draw(l))),
							|| Html.div("hidden", []),
						),
					],
				),
				|| Html.div("hidden", []),
			),
			Engine.on_post(lv.map(|l| l.outage), |cut| [Engine.command(Latency.drop.send(cut))], Engine.ignore({})),
			Engine.watch_changes(visible, |_| [Engine.again({})], live.on_result(|l, showing, _| Live.shown(l, showing))),
		],
	)
}

## The last accepted sequence is the resume cursor, not a request identity.
last_seq : List(Latency.Point) -> U32
last_seq = |window| match window.last() {
	Ok(point) => point.seq
	Err(_) => 0
}

## SplitMix64 advances once for each lost connection that can retry.
lost : Live -> Live
lost = |live| {
	attempt = match live.retry {
		Connecting(previous) => previous + 1
		_ => 1
	}
	if attempt > 5 {
		{ ..live, retry: GaveUp, stopped: Exhausted }
	} else {
		advanced = live.rng.plus_wrap(0x9e3779b97f4a7c15)
		first = advanced.bitwise_xor(advanced.shr_zf_wrap(30)).times_wrap(0xbf58476d1ce4e5b9)
		second = first.bitwise_xor(first.shr_zf_wrap(27)).times_wrap(0x94d049bb133111eb)
		random = second.bitwise_xor(second.shr_zf_wrap(31))
		{ ..live, rng: advanced, retry: Waiting({ attempt, delay_ms: Live.backoff({ attempt, random }) }) }
	}
}

## Millisecond jitter is shown exactly without floating point rounding.
seconds_text : U32 -> Str
seconds_text = |ms| {
	whole = ms // 1000
	fraction = ms % 1000
	if fraction == 0 {
		whole.to_str()
	} else {
		digits = (fraction + 1000).to_str().drop_prefix("1")
		"${whole.to_str()}.${digits}"
	}
}

reading : { seq : U32, api : U32 } -> Latency.Message
reading = |{ seq, api }| Event({ seq, at_ms: 1_762_852_800_000 + seq.to_i64() * 250, p95_ms: { api, web: 140, database: 110, notifications: 180 }, dropped: 0 })

## Backoff doubles its base and never adds over one quarter in jitter.
expect {
	[1, 2, 3, 4, 5].map(|attempt| Live.backoff({ attempt, random: 0 })) == [1000, 2000, 4000, 8000, 16000]
}

## Both halves of the document seed affect jitter identically.
expect Live.seeded({ seed: 0x10000000000000007, visible: True }).rng == 6

## Opened is not data. The first accepted Event makes the feed live.
expect {
	connecting = Live.receive(Live.init, Ok(Opened))
	taken = Live.receive(connecting, Ok(reading({ seq: 1, api: 120 })))
	(connecting.retry, taken.retry, taken.received, last_seq(taken.window)) == (Connecting(0), Live, 1, 1)
}

## A refusal stops retries and tells the truth about why they stopped.
expect {
	waiting = Live.receive(Live.init, Err(Closed))
	stopped = Live.retried(waiting, Err(Refused))
	(stopped.retry, Live.status_text(stopped)) == (GaveUp, "Reconnect stopped: too many requests were in flight")
}

## Five failed attempts exhaust the budget; manual reconnect starts anew.
expect {
	var $live = Live.receive(Live.init, Err(Closed))
	for _attempt in 1..=5 {
		$live = Live.receive(Live.retried($live, Ok(0)), Err(Closed))
	}
	($live.retry, Live.status_text($live), Live.reconnect($live).retry) == (GaveUp, "Gave up after 5 attempts", Connecting(0))
}

## A reopen asks after the last kept reading, and pausing catches the chart up.
expect {
	taken = Live.receive(Live.init, Ok(reading({ seq: 9, api: 120 })))
	(Live.reconnect(taken).after, Live.toggle_mode(taken).drawn.len()) == (9, 1)
}

## Jitter ranges from zero through exactly a quarter of each base.
expect {
	[1, 2, 3, 4, 5].map(
		|attempt| {
			base = Live.backoff({ attempt, random: 0 })
			Live.backoff({ attempt, random: (base // 4).to_u64() }) == base + base // 4
		},
	) == [True, True, True, True, True]
}
