import Core
import Engine exposing [Elem, In, Val]
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
## Make each port once, list its `declaration` in `Program.with_ports`, and
## use the same value wherever the app sends on it, so a request can only
## carry the port's own types. The page passes one handler per declared port
## in the `ports` option of `mountRocEngineApp`, and the runtime refuses to
## mount a page whose handlers do not match the declarations.
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
## Under `Engine.latest` or `Engine.resource` a newer value stops the older
## value's calls, and the JavaScript sees its `AbortSignal` abort.
Port := [].{

	## Why a port request has no value for the app.
	##
	## - `Refused`: the in-flight bound turned the request away.
	## - `Timeout`: the call's timeout expired (see `with_timeout_ms`).
	## - `Threw(message)`: the JavaScript threw or rejected, or answered with
	##   something that is not JSON data (a `Map`, a function, a cycle).
	## - `TooLarge`: the answer was larger than the page's `maxPayloadBytes`,
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

	## A port that sends an `out` to JavaScript and expects nothing back.
	## Make one with `command`.
	Command(output) :: { name : Str, encode : (output -> Engine.PortMessage) }.{

		## A request that sends `value`, for an effect site's plan (or an
		## `on_cleanup`, which allows commands). The JavaScript's `command`
		## handler receives it after the turn's DOM changes are applied. A
		## failure there is reported to the console and the page's
		## `onPortFault`; the app learns nothing of it.
		send : Command(output), output -> Engine.Req
		send = |p, value| PortCommand({ port: p.name, message: (p.encode)(value) })

		## The port's entry for `Program.with_ports`.
		declaration : Command(output) -> Engine.PortDecl
		declaration = |p| Core.port_declaration(p.name, Command)
	}

	## A port that sends an `in` to JavaScript and awaits one `out`. Make one
	## with `call`.
	Call(input, output) :: { name : Str, timeout_ms : U32, encode : (input -> Engine.PortMessage), decode : (Engine.PortMessage -> Try(output, Str)) }.{

		## Answer `Timeout` when the JavaScript has not answered `ms`
		## milliseconds after the request was performed, and abort its
		## `AbortSignal`. `0`, the default, means no timeout; the platform
		## caps it at ten minutes.
		with_timeout_ms : Call(input, output), U32 -> Call(input, output)
		with_timeout_ms = |p, ms| { ..p, timeout_ms: ms }

		## A request that calls the JavaScript with `value`, for an effect
		## site's plan. The value is a snapshot, encoded when the request is
		## issued.
		request : Call(input, output), input -> Engine.Req
		request = |p, value| PortCall({ port: p.name, message: (p.encode)(value), timeout_ms: p.timeout_ms })

		## The answer to a `request`, for an effect site's reaction: the
		## JavaScript's answer as an `out`, or why there is none. A result
		## that is not from a port request is a contract error.
		result : Call(input, output), Engine.Res -> Try(output, Error)
		result = |p, res| answer_of(p.name, p.decode, res)

		## The port's entry for `Program.with_ports`.
		declaration : Call(input, output) -> Engine.PortDecl
		declaration = |p| Core.port_declaration(p.name, Call)
	}

	## A port that sends an `arg` to JavaScript once and receives any number
	## of `msg`s. Make one with `subscription`.
	Subscription(arg, msg) :: { name : Str, delivery : Delivery, encode : (arg -> Engine.PortMessage), decode : (Engine.PortMessage -> Try(msg, Str)) }.{

		## A request that subscribes with `arg`, for an effect site's plan.
		## The JavaScript's `subscribe` handler receives `arg` and an `emit`
		## function; each message it emits is a result turn for the site.
		## Disposing the site, or a `latest` site moving to a new value,
		## calls the unsubscribe function the handler returned.
		subscribe : Subscription(arg, msg), arg -> Engine.Req
		subscribe = |p, arg| PortSubscribe({ port: p.name, message: (p.encode)(arg) })

		## One message of the subscription, for an effect site's reaction, or
		## why there is none. After `Closed` or `Threw` no more messages come.
		## A result that is not from a port request is a contract error.
		message : Subscription(arg, msg), Engine.Res -> Try(msg, Error)
		message = |p, res| answer_of(p.name, p.decode, res)

		## The port's entry for `Program.with_ports`.
		declaration : Subscription(arg, msg) -> Engine.PortDecl
		declaration = |p| Core.port_declaration(p.name, Subscription(p.delivery))
	}

	## `command(name)`: the command port `name`. Its value type must be
	## `PortJson.Sendable`, which records, tag unions, lists, numbers,
	## strings, `Bool`, `Wire.Bytes` and `Engine.File` are.
	command : Str -> Command(output) where [output.PortJson.Sendable]
	command = |name| { name, encode: |value| PortJson.encode(value) }

	## `call(name)`: the call port `name`, which sends an `in` and answers an
	## `out`. A call whose JavaScript answers nothing useful (it stores a
	## value, say) declares `{}` as its answer, which `undefined` and `null`
	## both decode to.
	call : Str -> Call(input, output) where [input.PortJson.Sendable, output.PortJson.Sendable]
	call = |name| { name, timeout_ms: 0, encode: |value| PortJson.encode(value), decode: |message| PortJson.decode(message).map_err(PortJson.describe) }

	## `subscription(name, delivery)`: the subscription port `name`, which
	## sends an `arg` when it subscribes and receives `msg`s, kept while the
	## app is busy as `delivery` says.
	subscription : Str, Delivery -> Subscription(arg, msg) where [arg.PortJson.Sendable, msg.PortJson.Sendable]
	subscription = |name, delivery| { name, delivery, encode: |value| PortJson.encode(value), decode: |message| PortJson.decode(message).map_err(PortJson.describe) }

	## What a `fetch` layer holds: whether a call for the current input is
	## still wanted (`running`), and the latest answer: `Nothing` before the
	## first, `Done(output)`, or `Failed(error)`. A new input sets `running`
	## and keeps the previous answer, so a view can go on showing it.
	Remote(output) : { running : Bool, answer : [Nothing, Done(output), Failed(Error)] }

	## `fetch(call, input, body)` gives `body` a layer holding the call's
	## answer for `input`, as `Worker.derive` does for a worker program: the
	## call for the first input is made at mount, and when `input` changes to
	## an unequal value the older call is stopped (its `AbortSignal` aborts)
	## and one for the new value is made in the same turn, so an answer for
	## an old input is never shown and the app keeps no request serial.
	fetch : Call(input, output), Val(ctx, input), (Val(In(ctx, Remote(output)), Remote(output)) -> Elem(In(ctx, Remote(output)))) -> Elem(ctx)
		where [input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	fetch = |port, input, body| Engine.resource(
		input,
		{
			init: { running: Bool.False, answer: Nothing },
			begin: |remote, _| { ..remote, running: Bool.True },
			plan: |value| [port.request(value)],
			fold: |_, _, res| match port.result(res) {
				Ok(output) => { running: Bool.False, answer: Done(output) }
				Err(error) => { running: Bool.False, answer: Failed(error) }
			},
		},
		body,
	)
}

## A port result as the app's type, or why there is none.
answer_of : Str, (Engine.PortMessage -> Try(a, Str)), Engine.Res -> Try(a, Port.Error)
answer_of = |name, decode, res| match res {
	PortReply(message) => decode(message).map_err(|why| Undecodable("port \"${name}\": ${why}"))
	PortFailed(Threw(text)) => Err(Threw(text))
	PortFailed(TooLarge) => Err(TooLarge)
	PortFailed(Closed) => Err(Closed)
	Timeout => Err(Timeout)
	Refused => Err(Refused)
	_ => crash "contract: port \"${name}\" was given a result that is not from a port request"
}

## A call sends its value's JSON and reads its answer's, and a malformed
## answer is a typed error naming the port.
expect {
	get = Port.call("test/get")
	sent = match get.request({ id: "n1" }) {
		PortCall({ port, message, timeout_ms }) => (port, message.json, timeout_ms)
		_ => ("", "", 1)
	}
	good : Try({ title : Str }, Port.Error)
	good = get.result(PortReply({ json: "{\"title\":\"a\",\"extra\":1}", blobs: [], files: [] }))
	bad : Try({ title : Str }, Port.Error)
	bad = get.result(PortReply({ json: "{\"title\":5}", blobs: [], files: [] }))
	threw : Try({ title : Str }, Port.Error)
	threw = get.result(PortFailed(Threw("no store")))
	sent == ("test/get", "{\"id\":\"n1\"}", 0) and good == Ok({ title: "a" }) and bad == Err(Undecodable("port \"test/get\": expected a string at byte 9")) and threw == Err(Threw("no store"))
}

## A subscription carries its argument and its delivery policy into its
## declaration, and `Closed` and `Refused` are errors of a message.
expect {
	ticks : Port.Subscription({ every_ms : U32 }, U64)
	ticks = Port.subscription("test/ticks", Every(8))
	sent = match ticks.subscribe({ every_ms: 50 }) {
		PortSubscribe({ port, message }) => (port, message.json)
		_ => ("", "")
	}
	one = ticks.message(PortReply({ json: "\"18446744073709551615\"", blobs: [], files: [] }))
	sent == ("test/ticks", "{\"every_ms\":50}") and one == Ok(18446744073709551615) and ticks.message(PortFailed(Closed)) == Err(Closed) and ticks.message(Refused) == Err(Refused)
}
