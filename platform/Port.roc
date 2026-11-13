import Core
import Engine exposing [Elem, In, Signal]
import PortJson

## Typed ports: services the page's JavaScript supplies, for what the
## platform does not model itself (IndexedDB, a save-file picker, a socket).
##
## A port has a namespaced name (`"example.org/notes/list"`) and one of three
## shapes:
##
## - a [Command] sends a value to JavaScript and forgets it;
## - a [Call] sends a value and awaits one answer, like an HTTP request;
## - a [Subscription] sends an argument and receives any number of messages
##   until its site is disposed or the JavaScript ends it.
##
## Make each port once from a props record (`Port.call({ name })`), list its
## `registration` in `Program.with_ports`, and use the same value wherever
## the app sends on it, so a request can only carry the port's own types.
## The page passes one handler per registered port in the `ports` option of
## `mountRocEngineApp`, and the runtime refuses to mount a page whose
## handlers do not match the registrations.
##
## Values cross as JSON in the `PortJson` format, derived from their types:
## the JavaScript receives and answers plain data (objects, arrays, strings,
## numbers, booleans and `null`), with `Wire.Bytes` as a `Uint8Array` and an
## `Engine.File` as the browser's own `File`, carried beside the text rather
## than encoded in it. Anything a port's JavaScript answers is checked
## against the type the app expects; an answer that does not fit is the
## typed `Undecodable` error, never a crash.
##
## Everything goes through the effect channel. A call or a subscription is
## an awaited request: it counts against the in-flight bound, is answered
## `Refused` beyond it, and its answers are ordinary result turns. A call
## survives its site's disposal and is answered to the nearest surviving
## ancestor, as an HTTP request is; a subscription is stopped by disposal.
## Under `Engine.watch_latest` or `Engine.resource` a newer value stops the older
## value's calls, and the JavaScript sees its `AbortSignal` abort.
Port := [].{

	## Why a port request has no value for the app.
	##
	## - `Refused`: the in-flight bound turned the request away.
	## - `Timeout`: the call's `timeout` expired.
	## - `Threw(message)`: the JavaScript threw or rejected, or answered with
	##   something that is not JSON data (a `Map`, a function, a cycle).
	## - `TooLarge`: the answer was larger than the page's `maxPortBytes`,
	##   or carried more files than the instance can hold.
	## - `Closed`: the JavaScript ended the subscription.
	## - `Undecodable(why)`: the answer is JSON data, but not of the type the
	##   app declared; `why` names the port and the place.
	##
	## `Threw` and `Closed` end a subscription; every other error reports one
	## message and the subscription goes on.
	Error : [Refused, Timeout, Threw(Str), TooLarge, Closed, Undecodable(Str)]

	## How a subscription's messages wait while the app is busy: `Latest`
	## keeps only the newest undelivered one, for a value whose newest state
	## is all that matters (a revision number, a status); `Every(n)` keeps up
	## to `n` (1 to 1024) in order, and the JavaScript's `emit` returns
	## `false` and takes nothing beyond them.
	Delivery : Engine.PortDelivery

	## A port that sends an `output` to JavaScript and expects nothing back.
	## Make one with `command`.
	Command(output) :: { name : Str, encode : (output -> Engine.PortMessage) }.{

		## A command that sends `value`, for an effect site's plan or the
		## plan of an `on_cleanup`: its type is the one tag it returns, so
		## it fits a list of `Engine.Request`s and a list of
		## `Engine.Command`s alike. The JavaScript's `command` handler
		## receives it after the turn's DOM changes are applied. A failure
		## there is reported to the console and the page's `onPortFault`;
		## the app learns nothing of it.
		send : Command(output), output -> [PortCommand({ port : Str, message : Engine.PortMessage })]
		send = |p, value| PortCommand({ port: p.name, message: (p.encode)(value) })

		## The port's entry for `Program.with_ports`.
		registration : Command(output) -> Engine.PortRegistration
		registration = |p| Core.port_declaration(p.name, Command)
	}

	## A port that sends an `input` to JavaScript and awaits one `output`.
	## Make one with `call`.
	Call(input, output) :: { name : Str, timeout_ms : U32, encode : (input -> Engine.PortMessage), decode : (Engine.PortMessage -> Try(output, Str)) }.{

		## Ask the call and retain its declared result reader with this input.
		ask : Call(input, output), input -> Engine.Ask(output, Error)
		ask = |port, input| Engine.ask_of(port, input)

		## A request that calls the JavaScript with `value`, for an effect
		## site's plan. The value is a snapshot, encoded when the request is
		## issued.
		request : Call(input, output), input -> Engine.Request
		request = |p, value| PortCall({ port: p.name, message: (p.encode)(value), timeout_ms: p.timeout_ms })

		## The answer to a `request`, for an effect site's reaction: the
		## JavaScript's answer as an `output`, or why there is none. A result
		## that is not from a port request is a contract error.
		result : Call(input, output), Engine.Result -> Try(output, Error)
		result = |p, res| answer_of(p.name, p.decode, res)

		## The port's entry for `Program.with_ports`.
		registration : Call(input, output) -> Engine.PortRegistration
		registration = |p| Core.port_declaration(p.name, Call)
	}

	## A port that sends an `arg` to JavaScript once and receives any number
	## of `msg`s. Make one with `subscription`.
	Subscription(arg, msg) :: { name : Str, delivery : Delivery, encode : (arg -> Engine.PortMessage), decode : (Engine.PortMessage -> Try(msg, Str)) }.{

		## Subscribe with the reader of each message. A subscription deliberately
		## has no request/result protocol for single-answer resource layers.
		ask : Subscription(arg, msg), arg -> Engine.Ask(msg, Error)
		ask = |port, arg| Core.make_ask(port.subscribe(arg), |result| port.message(result))

		## A request that subscribes with `arg`, for an effect site's plan.
		## The JavaScript's `subscribe` handler receives `arg` and an `emit`
		## function; each message it emits is a result turn for the site.
		## Disposing the site, or a `watch_latest` site moving to a new value,
		## calls the unsubscribe function the handler returned.
		subscribe : Subscription(arg, msg), arg -> Engine.Request
		subscribe = |p, arg| PortSubscribe({ port: p.name, message: (p.encode)(arg) })

		## One message of the subscription, for an effect site's reaction, or
		## why there is none. After `Closed` or `Threw` no more messages come.
		## A result that is not from a port request is a contract error.
		message : Subscription(arg, msg), Engine.Result -> Try(msg, Error)
		message = |p, res| answer_of(p.name, p.decode, res)

		## The port's entry for `Program.with_ports`.
		registration : Subscription(arg, msg) -> Engine.PortRegistration
		registration = |p| Core.port_declaration(p.name, Subscription(p.delivery))
	}

	## What `command` is told about a command port: its `name`, namespaced
	## (`"example.org/notes/log"`) and unique among the program's ports.
	CommandProps := { name : Str }

	## The command port a props record describes:
	## `Port.command({ name: "example.org/notes/log" })`. Its value type must
	## be `PortJson.Sendable`, which records, tag unions, lists, numbers,
	## strings, `Bool`, `Wire.Bytes` and `Engine.File` are.
	command : CommandProps -> Command(output) where [output.PortJson.Sendable]
	command = |CommandProps.({ name })| { name, encode: |value| PortJson.encode(value) }

	## What `call` is told about a call port.
	##
	## - `name`: namespaced and unique among the program's ports.
	## - `timeout`: `Ms(ms)` answers `Timeout` when the JavaScript has not
	##   answered `ms` milliseconds after the request was performed, and
	##   aborts its `AbortSignal`; the platform caps it at ten minutes.
	##   `Unlimited`, the default, waits for the JavaScript. `Ms(0)` is a
	##   contract error; a finite timeout is at least one millisecond.
	CallProps := {
		name : Str,
		timeout : [Unlimited, Ms(U32)] ?? Unlimited,
	}

	## The call port a props record describes:
	## `Port.call({ name: "example.org/notes/list", timeout: Ms(5000) })`,
	## which sends an `input` and answers an `output`. A call whose
	## JavaScript answers nothing useful (it stores a value, say) declares
	## `{}` as its answer, which `undefined` and `null` both decode to.
	call : CallProps -> Call(input, output) where [input.PortJson.Sendable, output.PortJson.Sendable]
	call = |CallProps.({ name, timeout })| {
		name,
		timeout_ms: Core.timeout_wire(timeout),
		encode: |value| PortJson.encode(value),
		decode: |message| PortJson.decode(message).map_err(PortJson.describe),
	}

	## What `subscription` is told about a subscription port: its `name`,
	## and how its messages wait while the app is busy (`delivery`, see
	## [Delivery]). Both are required: a subscription always says how much
	## it lets wait.
	SubscriptionProps := {
		name : Str,
		delivery : Delivery,
	}

	## The subscription port a props record describes:
	## `Port.subscription({ name: "example.org/notes/changed", delivery: Latest })`,
	## which sends an `arg` when it subscribes and receives `msg`s.
	subscription : SubscriptionProps -> Subscription(arg, msg) where [arg.PortJson.Sendable, msg.PortJson.Sendable]
	subscription = |SubscriptionProps.({ name, delivery })| { name, delivery, encode: |value| PortJson.encode(value), decode: |message| PortJson.decode(message).map_err(PortJson.describe) }

	## `resource(call, input, body)` gives `body` a signal holding the call's
	## answer for `input`, an `Engine.Remote(output, Port.Error)`, as
	## `Worker.resource` does for a worker task: the call for the first input
	## is made at mount, and when `input` changes to an unequal value the
	## older call is stopped (its `AbortSignal` aborts) and one for the new
	## value is made in the same turn, so an answer for an old input is never
	## shown and the app keeps no request serial.
	resource : Call(input, output), Signal(ctx, input), (Signal(In(ctx, Engine.Remote(output, Error)), Engine.Remote(output, Error)) -> Elem(In(ctx, Engine.Remote(output, Error)))) -> Elem(ctx)
		where [input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	resource = |port, input, body| Engine.resource(input, Core.follow(port), body)

	## Like `resource`, for an input that is sometimes not a question: `Run(i)`
	## makes the call with `i`, and `Skip` stops any call and clears the
	## answer.
	resource_when : Call(input, output), Signal(ctx, [Run(input), Skip]), (Signal(In(ctx, Engine.Remote(output, Error)), Engine.Remote(output, Error)) -> Elem(In(ctx, Engine.Remote(output, Error)))) -> Elem(ctx)
		where [input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	resource_when = |port, input, body| Engine.resource(input, Core.follow_when(port), body)
}

## A port result as the app's type, or why there is none.
answer_of : Str, (Engine.PortMessage -> Try(a, Str)), Engine.Result -> Try(a, Port.Error)
answer_of = |name, decode, res| match res {
	PortAnswer(message) => decode(message).map_err(|why| Undecodable("port \"${name}\": ${why}"))
	PortFailed(Threw(text)) => Err(Threw(text))
	PortFailed(TooLarge) => Err(TooLarge)
	PortFailed(Closed) => Err(Closed)
	Timeout => Err(Timeout)
	Refused => Err(Refused)
	_ => crash "contract: port \"${name}\" was given a result that is not from a port request"
}

## A call sends its value's JSON and its timeout, reads its answer's, and a
## malformed answer is a typed error naming the port.
expect {
	get = Port.call({ name: "test/get", timeout: Ms(1000) })
	sent = match get.request({ id: "n1" }) {
		PortCall({ port, message, timeout_ms }) => "${port} ${message.json} ${timeout_ms.to_str()}"
		_ => "not a call"
	}
	good : Try({ title : Str }, Port.Error)
	good = get.result(PortAnswer({ json: "{\"title\":\"a\",\"extra\":1}", blobs: [], files: [] }))
	bad : Try({ title : Str }, Port.Error)
	bad = get.result(PortAnswer({ json: "{\"title\":5}", blobs: [], files: [] }))
	threw : Try({ title : Str }, Port.Error)
	threw = get.result(PortFailed(Threw("no store")))
	actual =
		\\sent: ${sent}
		\\good: ${Str.inspect(good)}
		\\bad names the port: ${Str.inspect(bad == Err(Undecodable("port \"test/get\": expected a string at byte 9")))}
		\\threw: ${Str.inspect(threw)}
	expected =
		\\sent: test/get {"id":"n1"} 1000
		\\good: Ok({ title: "a" })
		\\bad names the port: True
		\\threw: Err(Threw("no store"))
	actual == expected
}

## A command's `send` carries its value's JSON, and is typed by the one tag
## it returns: its value is a request in an effect site's plan and a command
## in a cleanup's.
expect {
	note : Port.Command({ text : Str })
	note = Port.command({ name: "test/note" })
	requests : List(Engine.Request)
	requests = [note.send({ text: "a" }), Timer(1)]
	commands : List(Engine.Command)
	commands = [note.send({ text: "b" }), Title("t")]
	as_request = match requests {
		[PortCommand({ port, message }), ..] => "${port} ${message.json}"
		_ => "not a command"
	}
	as_command = match commands {
		[PortCommand({ port, message }), ..] => "${port} ${message.json}"
		_ => "not a command"
	}
	actual =
		\\request: ${as_request}
		\\command: ${as_command}
	expected =
		\\request: test/note {"text":"a"}
		\\command: test/note {"text":"b"}
	actual == expected
}

## A call without a timeout asks for none.
expect {
	put : Port.Call({ id : Str }, {})
	put = Port.call({ name: "test/put" })
	timeout = match put.request({ id: "n1" }) {
		PortCall({ timeout_ms, .. }) => timeout_ms
		_ => 1
	}
	timeout == 0
}

## A subscription carries its argument, and `Closed` and `Refused` are
## errors of a message.
expect {
	ticks : Port.Subscription({ every_ms : U32 }, U64)
	ticks = Port.subscription({ name: "test/ticks", delivery: Every(8) })
	sent = match ticks.subscribe({ every_ms: 50 }) {
		PortSubscribe({ port, message }) => "${port} ${message.json}"
		_ => "not a subscription"
	}
	actual =
		\\sent: ${sent}
		\\one: ${Str.inspect(ticks.message(PortAnswer({ json: "\"18446744073709551615\"", blobs: [], files: [] })))}
		\\closed: ${Str.inspect(ticks.message(PortFailed(Closed)))}
		\\refused: ${Str.inspect(ticks.message(Refused))}
	expected =
		\\sent: test/ticks {"every_ms":50}
		\\one: Ok(18446744073709551615)
		\\closed: Err(Closed)
		\\refused: Err(Refused)
	actual == expected
}
