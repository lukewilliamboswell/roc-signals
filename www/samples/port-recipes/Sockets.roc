import pf.Engine
import pf.Html
import pf.Port
import Backoff

Sockets := [].{
	# region declaration
	Message : [Opened, Event({ seq : U64, data : Str, dropped : U64 })]
	Input : { url : Str, after : U64 }

	## One scope is one connection. Every(16) preserves accepted messages;
	## the handler's own bounded buffer reports any older readings it drops.
	sse : Port.Subscription(Input, Message)
	sse = Port.subscription({ name: "example.org/recipes/sse", delivery: Every(16) })

	websocket : Port.Subscription(Input, Message)
	websocket = Port.subscription({ name: "example.org/recipes/websocket", delivery: Every(16) })

	## A closed connection drops this command. Use a call for acknowledged sends.
	send : Port.Command({ connection : Str, data : Str })
	send = Port.command({ name: "example.org/recipes/socket-send" })
	# endregion declaration

	Transport : [Sse, WebSocket]
	Retry : [Live, Connecting, Waiting(U32), GaveUp]
	Model : { following : Bool, transport : Transport, retry : Retry, attempt : U32, generation : U64, random : U64, after : U64, resume : U64, message : Str, sent : Engine.Outbox({}) }

	initial : U128 -> Model
	initial = |seed| { following: False, transport: Sse, retry: Connecting, attempt: 0, generation: 0, random: Backoff.seed(seed), after: 0, resume: 0, message: "Connection stopped", sent: Engine.outbox({}) }

	## Start again only by a user decision or a completed backoff timer.
	started : Model, Transport -> Model
	started = |model, transport| { ..model, following: True, transport, retry: Connecting, attempt: 0, generation: model.generation + 1, resume: model.after, message: "Connecting" }

	# region reconnect
	## Failure chooses one bounded wait in Roc. A refusal never loops into
	## a full in-flight table, and a fifth failed retry offers a manual start.
	lost : Model -> Model
	lost = |model| {
		if model.attempt >= 5 {
			return { ..model, retry: GaveUp, message: "Gave up after five retries" }
		}
		attempt = model.attempt + 1
		random = Backoff.next(model.random)
		delay = Backoff.delay({ attempt, random: random.value })
		{ ..model, attempt, random: random.state, retry: Waiting(delay), message: "Reconnecting in ${delay.to_str()} ms (attempt ${attempt.to_str()})" }
	}

	waited : Model, Try(I64, [Refused]) -> Model
	waited = |model, result| match result {
		Ok(_) => { ..model, retry: Connecting, generation: model.generation + 1, resume: model.after, message: "Connecting" }
		Err(Refused) => { ..model, retry: GaveUp, message: "Retry refused; reconnect manually" }
	}
	# endregion reconnect

	## The last kept sequence is the next connection's resume argument. Zero is
	## the sample protocol's before-first-event value; events start at one.
	received : Model, Try(Message, Port.Error) -> Model
	received = |model, result| match result {
		Ok(Opened) => { ..model, message: "Connection opened; waiting for data" }
		Ok(Event(event)) => if event.seq > model.after {
			{
				gap = event.seq - model.after - 1
				message = if (gap == 0) "${event.data} (dropped ${event.dropped.to_str()})" else "${event.data} (gap ${gap.to_str()}, dropped ${event.dropped.to_str()})"
				{ ..model, after: event.seq, retry: Live, attempt: 0, message }
			}
		} else { ..model, message: "Ignored an out-of-order reading" }
		Err(Closed) | Err(Threw(_)) => Sockets.lost(model)
		Err(Refused) => { ..model, retry: GaveUp, message: "Connection refused; reconnect manually" }
		Err(error) => { ..model, message: "Unreadable feed: ${Str.inspect(error)}" }
	}

	view : { seed : U128 } -> Engine.Elem(ctx)
	view = |props| Engine.state(
		Sockets.initial(props.seed),
		|state| {
			v = state.signal()
			Html.div(
				"recipe",
				[
					Html.button("Connect event stream", [], state.update(|s| Sockets.started(s, Sse))),
					Html.button("Connect WebSocket", [], state.update(|s| Sockets.started(s, WebSocket))),
					Html.button("Pause connection", [], state.update(|s| { ..s, following: False, message: "Connection paused" })),
					Html.button("Send greeting", [], state.update(|s| { ..s, sent: s.sent.post({}) })),
					Engine.on_post(v.map(|s| s.sent), |_| [Engine.command(Sockets.send.send({ connection: "primary", data: "hello" }))], Engine.ignore({})),
					Engine.when(
						v.map(|s| s.following),
						|| Html.div(
							"connection",
							[
								Engine.when(
									v.map(
										|s| match s.retry {
											Waiting(_) | GaveUp => False
											_ => True
										},
									),
									|| Engine.watch_latest(
										v.map(|s| { generation: s.generation, transport: s.transport, resume: s.resume }),
										|wanted| [if (wanted.transport == Sse) Sockets.sse.ask({ url: "/events", after: wanted.resume }) else Sockets.websocket.ask({ url: "/socket", after: wanted.resume })],
										state.on_result(|s, _, result| Sockets.received(s, result)),
									),
									|| Engine.text(""),
								),
								Engine.when(
									v.map(
										|s| match s.retry {
											Waiting(_) => True
											_ => False
										},
									),
									|| Engine.watch(
										v.map(
											|s| match s.retry {
												Waiting(delay) => delay
												_ => crash "Sockets: wait scope without a delay"
											},
										),
										|delay| [Engine.timer(delay)],
										state.on_result(|s, _, result| Sockets.waited(s, result)),
									),
									|| Engine.text(""),
								),
							],
						),
						|| Engine.text(""),
					),
					Html.p_s(v.map(|s| s.message), [Engine.test_id("socket-result")]),
				],
			)
		},
	)
}

## A refused timer stops automatic retry, while a received event resumes live data.
expect {
	initial = Sockets.started(Sockets.initial(7), Sse)
	lost = Sockets.lost(initial)
	refused = Sockets.waited(lost, Err(Refused))
	received = Sockets.received(initial, Ok(Event({ seq: 5, data: "ready", dropped: 0 })))
	(refused.retry, received.after, received.retry) == (GaveUp, 5, Live)
}
