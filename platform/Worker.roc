import Engine exposing [Elem, In, Val]
import Wire

## Typed worker programs: pure Roc functions an app runs off the page's
## thread.
##
## A [Program] is a name and a pure function from an input to an output. The
## app lists each program's `registration` in `Program.with_workers`, and an
## effect site asks for a run with `request`; the answer comes back as an
## ordinary result, read with `result`. `derive` wraps both in a layer that
## follows the answers for an input, for the common case of showing a value
## computed from other values.
##
## The page and each worker run the same compiled module, so both know the
## types of every program: inputs and outputs cross as `Wire` payloads the
## compiler derives, and an app writes no codec. A type crosses if it is
## `Wire.Sendable`: numbers, `Bool`, `Str`, lists, sets, dictionaries,
## records, tuples, tag unions, and nominal types that declare
## `parser_for : _` and `encoder_for : _`. Functions, state handles, reactive
## values and `Try` do not, and using one is a compile error at the program's
## declaration; a calculation that returns a `Try` is declared with
## `fallible`. Send bulk bytes as `Wire.Bytes`, which crosses as one block.
##
## A program is a plain function, so it is pure. It runs in an instance that
## shares nothing with the page but the input it is sent, possibly one that
## ran other jobs before. A run is stopped when its site is disposed, when a
## `latest` or `derive` site moves on to a newer input, or when its deadline
## expires: a run still waiting for a worker is dropped, and a running one is
## stopped by ending its instance, so the next run starts a new one. There is
## no way to stop a run and keep its instance, and a run reports nothing
## until it answers.
Worker := [].{

	## Why a run produced no output: its deadline expired and it was stopped
	## (`Timeout`), the in-flight bound turned the request away (`Refused`), or
	## the worker could not run it or failed running it (`Lost`, with the fault
	## class; the diagnostic goes to the page's console).
	Error : [Timeout, Refused, Lost(Engine.WorkFault)]

	## A worker program from `input` to `output`. Make one with `pure` or
	## `fallible`, register it once with `registration`, and use the same value
	## wherever the app asks for a run, so a request can only name a program
	## with the right types.
	Program(input, output) :: {
		name : Str,
		deadline_ms : U32,
		send : (input -> List(U8)),
		receive : (List(U8) -> output),
		run : (List(U8) -> List(U8)),
	}.{

		## Stop a run that has not answered `ms` milliseconds after it was
		## requested, and answer `Timeout` instead. The time a request waits for
		## a free worker counts. `0`, the default, means no deadline; the
		## platform caps it at ten minutes.
		with_deadline_ms : Program(input, output), U32 -> Program(input, output)
		with_deadline_ms = |p, ms| { ..p, deadline_ms: ms }

		## The program's entry for `Program.with_workers`. Register each program
		## once, in the `Program` the app binds as `main`: a name registered twice
		## is a contract error when the app mounts, and a request for a program
		## that is not registered is a contract error naming it and the site.
		registration : Program(input, output) -> Engine.Registration
		registration = |p| Engine.registration(p.name, p.run)

		## A request to run the program on `input`, for an effect site's plan.
		## The input is a snapshot: it is encoded when the request is issued, and
		## later changes to the state it came from do not reach the run.
		request : Program(input, output), input -> Engine.Req
		request = |p, input| Work({ program: p.name, input: (p.send)(input), deadline_ms: p.deadline_ms })

		## The answer to a `request`, for an effect site's reaction: the
		## program's output, or why there is none. A result that is not from a
		## worker request is a contract error.
		result : Program(input, output), Engine.Res -> Try(output, Error)
		result = |p, res| match res {
			Work(bytes) => Ok((p.receive)(bytes))
			WorkLost(fault) => Err(Lost(fault))
			Timeout => Err(Timeout)
			Refused => Err(Refused)
			_ => crash "contract: Worker.result was given a result that is not from a worker request"
		}
	}

	## `pure(name, calculate)`: the program `name` that runs `calculate` on the
	## input it is sent and answers with its result. Both types must be
	## `Wire.Sendable`. Names are namespaced and unversioned
	## (`"example.org/search/filter"`); every instance runs the same module, so
	## a name means one function, and two programs with one name are a
	## contract error.
	pure : Str, (input -> output) -> Program(input, output)
		where [input.Wire.Sendable, output.Wire.Sendable]
	pure = |name, calculate| {
		name,
		deadline_ms: 0,
		send: |input| Wire.encode(input),
		receive: |bytes| match Wire.decode(bytes) {
			Ok(output) => output
			Err(_) => crash "contract: worker program \"${name}\" answered with bytes that are not its output type"
		},
		run: |bytes| match Wire.decode(bytes) {
			Ok(input) => Wire.encode(calculate(input))
			Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its input type"
		},
	}

	## Like `pure`, for a calculation that can fail. `Try` is not
	## `Wire.Sendable`, so this sends the calculation's `Try` itself: the
	## program's output is that `Try`, `result` gives `Ok(Ok(value))` or
	## `Ok(Err(error))` for an answer and `Err(...)` for a run that produced
	## none, and a `derive` layer holds `Done(Ok(value))` or `Done(Err(error))`.
	## Use it for failures the app expects (input that does not parse, say); a
	## crash in a program is `Lost`, not an `Err` the app chose.
	fallible : Str, (input -> Try(ok, err)) -> Program(input, Try(ok, err))
		where [input.Wire.Sendable, ok.Wire.Sendable, err.Wire.Sendable]
	fallible = |name, calculate| {
		name,
		deadline_ms: 0,
		send: |input| Wire.encode(input),
		receive: |bytes| {
			body = bytes.drop_last(1)
			match bytes.last() {
				Ok(0) => match Wire.decode(body) {
					Ok(value) => Ok(value)
					Err(_) => crash "contract: worker program \"${name}\" answered with bytes that are not its output type"
				}
				Ok(1) => match Wire.decode(body) {
					Ok(error) => Err(error)
					Err(_) => crash "contract: worker program \"${name}\" answered with bytes that are not its error type"
				}
				_ => crash "contract: worker program \"${name}\" answered without saying whether it succeeded"
			}
		},
		run: |bytes| match Wire.decode(bytes) {
			Ok(input) => match calculate(input) {
				Ok(value) => Wire.encode(value).append(0)
				Err(error) => Wire.encode(error).append(1)
			}
			Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its input type"
		},
	}

	## What a `derive` layer holds: whether a run for the current input is
	## still wanted (`running`), and the latest answer: `Nothing` before the
	## first, `Done(output)`, or `Failed(error)` for a run that produced none.
	## A new input sets `running` and keeps the previous answer, so a view can
	## go on showing it while the next one is computed; `derive_when`'s `Skip`
	## clears it.
	Remote(output) : { running : Bool, answer : [Nothing, Done(output), Failed(Error)] }

	## `derive(program, input, body)` is `Engine.derive` computed in a worker:
	## it gives `body` a layer holding the program's answer for `input`.
	##
	## The run for the first input starts at mount. When `input` changes to an
	## unequal value, the run for the old one is stopped and one for the new
	## value starts, in the same turn, so no answer for an old input is ever
	## shown and the app keeps no request serial. An equal input asks nothing,
	## so a run that failed (`Refused`, say) is asked for again only when the
	## input changes. Disposing the site stops its run. Readers of the layer do
	## no work while it is unchanged.
	derive : Program(input, output), Val(ctx, input), (Val(In(ctx, Remote(output)), Remote(output)) -> Elem(In(ctx, Remote(output)))) -> Elem(ctx)
		where [input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	derive = |program, input, body| Engine.resource(
		input,
		{
			init: { running: Bool.False, answer: Nothing },
			begin: |remote, _| { ..remote, running: Bool.True },
			plan: |value| [program.request(value)],
			fold: |_, _, res| answered(program.result(res)),
		},
		body,
	)

	## Like `derive`, for an input that is sometimes not a question: `Run(i)`
	## asks for a run on `i`, and `Skip` stops any run and clears the answer
	## (an empty search box, a form that is not valid yet).
	derive_when : Program(input, output), Val(ctx, [Run(input), Skip]), (Val(In(ctx, Remote(output)), Remote(output)) -> Elem(In(ctx, Remote(output)))) -> Elem(ctx)
		where [input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	derive_when = |program, input, body| Engine.resource(
		input,
		{
			init: { running: Bool.False, answer: Nothing },
			begin: |remote, want| match want {
				Run(_) => { ..remote, running: Bool.True }
				Skip => { running: Bool.False, answer: Nothing }
			},
			plan: |want| match want {
				Run(value) => [program.request(value)]
				Skip => []
			},
			fold: |_, _, res| answered(program.result(res)),
		},
		body,
	)
}

## A settled layer for one answer.
answered : Try(output, Worker.Error) -> Worker.Remote(output)
answered = |outcome| match outcome {
	Ok(output) => { running: Bool.False, answer: Done(output) }
	Err(error) => { running: Bool.False, answer: Failed(error) }
}

## A program's entry runs the calculation on what `send` encoded, and
## `receive` reads what it returned.
expect {
	double = Worker.pure("test/double", |n| n * 2.U64)
	(double.receive)((double.run)((double.send)(21))) == 42
}

## A record in and a list out need no codec, and a deadline is carried on the
## request.
expect {
	names = Worker.pure("test/names", |{ prefix, suffixes }| suffixes.map(|suffix| "${prefix}${suffix}")).with_deadline_ms(250)
	request = names.request({ prefix: "n", suffixes: ["0", "1", "2"] })
	answer = match request {
		Work({ program, input, deadline_ms }) => (program, (names.receive)((names.run)(input)), deadline_ms)
		_ => ("", [], 0)
	}
	answer == ("test/names", ["n0", "n1", "n2"], 250)
}

## A fallible program's own error is an answer; a deadline, a refusal and a
## lost worker are not.
expect {
	parse = Worker.fallible("test/parse", |text| U64.from_str(text).map_err(|_| NotANumber(text)))
	run : Str -> Engine.Res
	run = |text| Work((parse.run)((parse.send)(text)))
	good = parse.result(run("7"))
	bad = parse.result(run("seven"))
	late = parse.result(Timeout)
	lost = parse.result(WorkLost(AppCrash))
	good == Ok(Ok(7)) and bad == Ok(Err(NotANumber("seven"))) and late == Err(Timeout) and lost == Err(Lost(AppCrash))
}
