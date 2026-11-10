import Core
import Engine exposing [Elem, In, Val]
import Wire

## Typed worker programs: pure Roc functions an app runs off the page's
## thread.
##
## A [Program] is a name and a pure function from an input to an output,
## made with `program` (or `fallible`) from a props record. The app lists
## each program's `registration` in `Program.with_workers`, and an effect
## site asks for a job with `request`; the answer comes back as an ordinary
## result, read with `result`. `derive` wraps both in a layer that follows
## the answers for an input, for the common case of showing a value computed
## from other values.
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
## A program is a plain function, so it is pure. One execution of it is a
## job, and a job runs in an instance that shares nothing with the page but
## the input it is sent, possibly one that ran other jobs before. A job is
## stopped when its site is disposed, when a `latest` or `derive` site moves
## on to a newer input, or when its deadline expires: a job still waiting for
## a worker is dropped, and a running one is stopped by ending its instance,
## so the next job starts a new one; only a prepared program's query may
## instead finish a stopped job so that its instance keeps its state
## (`on_cancel: Finish`). A job reports nothing until it answers.
##
## A [Prepared] program is a preparation and several typed queries over its
## state; a worker may keep that state between jobs, which changes how long
## an answer takes and never what it is.
Worker := [].{

	## Why a job produced no output: its deadline expired and it was stopped
	## (`Timeout`), the in-flight bound turned the request away (`Refused`), or
	## the worker could not run it or failed running it (`Lost`, with the fault
	## class; the diagnostic goes to the page's console), or the files its
	## input holds could not be read into the worker (`FileFailed`: a file
	## changed or went away since the user gave it, `Unreadable`, or they are
	## more than one job reads, `TooLarge`). A job whose files fail is not
	## started, and its worker is not lost.
	Error : [Timeout, Refused, Lost(Engine.WorkFault), FileFailed(Engine.FileError)]

	## A worker program from `input` to `output`. Make one with `program` or
	## `fallible`, register it once with `registration`, and use the same value
	## wherever the app asks for a job, so a request can only name a program
	## with the right types.
	Program(input, output) :: {
		name : Str,
		deadline_ms : U32,
		send : (input -> { bytes : List(U8), files : List(Engine.File) }),
		receive : (List(U8) -> output),
		run : (List(U8), List(List(U8)) -> List(U8)),
	}.{

		## The program's entry for `Program.with_workers`. Register each program
		## once, in the `Program` the app binds as `main`: a name registered twice
		## is a contract error when the app mounts, and a request for a program
		## that is not registered is a contract error naming it and the site.
		registration : Program(input, output) -> Engine.Registration
		registration = |p| Core.registration_with_files(p.name, p.run)

		## A request for a job of the program on `input`, for an effect site's
		## plan. The input is a snapshot: it is encoded when the request is
		## issued, and later changes to the state it came from do not reach the
		## job.
		request : Program(input, output), input -> Engine.Req
		request = |p, input| {
			{ bytes, files } = (p.send)(input)
			Work({ program: p.name, input: bytes, files, deadline_ms: p.deadline_ms })
		}

		## The answer to a `request`, for an effect site's reaction: the
		## program's output, or why there is none. A result that is not from a
		## worker request is a contract error.
		result : Program(input, output), Engine.Res -> Try(output, Error)
		result = |p, res| match res {
			Work(bytes) => Ok((p.receive)(bytes))
			FileFailed(reason) => Err(FileFailed(reason))
			WorkLost(fault) => Err(Lost(fault))
			Timeout => Err(Timeout)
			Refused => Err(Refused)
			_ => crash "contract: Worker.result was given a result that is not from a worker request"
		}
	}

	## What `program` and `fallible` are told about a program.
	##
	## - `name`: namespaced and unversioned (`"example.org/search/filter"`).
	##   Every instance runs the same module, so a name means one function,
	##   and two programs with one name are a contract error.
	## - `run`: the pure calculation. Its input and output must be
	##   `Wire.Sendable`.
	## - `deadline`: `Ms(ms)` stops a job that has not answered `ms`
	##   milliseconds after it was requested and answers `Timeout`; the time a
	##   request waits for a free worker counts, and the platform caps it at
	##   ten minutes. `Unlimited`, the default, lets a job run until it
	##   answers or its site stops it.
	ProgramProps(input, output) := {
		name : Str,
		run : input -> output,
		deadline : [Unlimited, Ms(U32)] ?? Unlimited,
	}

	## The program a props record describes:
	## `Worker.program({ name: "example.org/words/count", run: count_words })`.
	## A job runs `run` on the input it is sent and answers with its result.
	program : ProgramProps(input, output) -> Program(input, output)
		where [input.Wire.Sendable, output.Wire.Sendable]
	program = |ProgramProps.({ name, run: calculate, deadline })| {
		name,
		deadline_ms: deadline_ms_of(deadline),
		send: |input| sent(input),
		receive: |bytes| match Wire.decode(bytes) {
			Ok(output) => output
			Err(_) => crash "contract: worker program \"${name}\" answered with bytes that are not its output type"
		},
		run: |bytes, files| match Wire.decode_with_files(bytes, files) {
			Ok(input) => payload_of(name, calculate(input))
			Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its input type"
		},
	}

	## Like `program`, for a calculation that can fail. `Try` is not
	## `Wire.Sendable`, so this sends the calculation's `Try` itself: the
	## program's output is that `Try`, `result` gives `Ok(Ok(value))` or
	## `Ok(Err(error))` for an answer and `Err(...)` for a job that produced
	## none, and a `derive` layer holds `Answered(Ok(value))` or
	## `Answered(Err(error))`. Use it for failures the app expects (input that
	## does not parse, say); a crash in a program is `Lost`, not an `Err` the
	## app chose.
	fallible : ProgramProps(input, Try(ok, err)) -> Program(input, Try(ok, err))
		where [input.Wire.Sendable, ok.Wire.Sendable, err.Wire.Sendable]
	fallible = |ProgramProps.({ name, run: calculate, deadline })| {
		name,
		deadline_ms: deadline_ms_of(deadline),
		send: |input| sent(input),
		receive: |bytes| received_try(name, bytes),
		run: |bytes, files| match Wire.decode_with_files(bytes, files) {
			Ok(input) => match calculate(input) {
				Ok(value) => payload_of(name, value).append(0)
				Err(error) => payload_of(name, error).append(1)
			}
			Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its input type"
		},
	}

	## `derive(program, input, body)` is `Engine.derive` computed in a worker:
	## it gives `body` a layer holding the program's answer for `input`, an
	## `Engine.Remote(output, Worker.Error)`.
	##
	## The job for the first input starts at mount. When `input` changes to an
	## unequal value, the job for the old one is stopped and one for the new
	## value starts, in the same turn, so no answer for an old input is ever
	## shown and the app keeps no request serial. Meanwhile the layer is
	## `Pending` and keeps the previous answer. An equal input asks nothing,
	## so a job that failed (`Refused`, say) is asked for again only when the
	## input changes. Disposing the site stops its job. Readers of the layer do
	## no work while it is unchanged.
	##
	## `program` is a [Program] or a prepared [Query]: anything with
	## `request` and `result`.
	derive : work, Val(ctx, input), (Val(In(ctx, Engine.Remote(output, Error)), Engine.Remote(output, Error)) -> Elem(In(ctx, Engine.Remote(output, Error)))) -> Elem(ctx)
		where [work.request : work, input -> Engine.Req, work.result : work, Engine.Res -> Try(output, Error), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	derive = |work, input, body| Engine.resource(input, Core.follow(work), body)

	## Like `derive`, for an input that is sometimes not a question: `Run(i)`
	## asks for a job on `i`, and `Skip` stops any job and clears the answer
	## (an empty search box, a form that is not valid yet).
	derive_when : work, Val(ctx, [Run(input), Skip]), (Val(In(ctx, Engine.Remote(output, Error)), Engine.Remote(output, Error)) -> Elem(In(ctx, Engine.Remote(output, Error)))) -> Elem(ctx)
		where [work.request : work, input -> Engine.Req, work.result : work, Engine.Res -> Try(output, Error), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool]
	derive_when = |work, input, body| Engine.resource(input, Core.follow_when(work), body)

	# -- Prepared programs ----------------------------------------------------

	## A preparation: a pure, possibly expensive step from an input of type
	## `init` (a parsed document, an index) to a `state` that several typed
	## queries read. Make one with `prepared`, build its queries with
	## `query` or `fallible_query`, and register it once with
	## `registration`, listing the queries it answers.
	##
	## A query is still a pure function of the preparation's input and its
	## own: its answer is exactly what preparing afresh and asking would
	## give. Keeping the state is an optimisation the runtime may or may not
	## achieve: a worker that prepared an input may keep the state and
	## answer later queries over the same input from it, so they cost a
	## query, not the preparation. It shows in time and in the monitor,
	## never in an answer. The state never crosses to the page and need not
	## be `Wire.Sendable`.
	Prepared(init, state) :: {
		name : Str,
		build : (List(U8), List(List(U8)) -> state),
		send : (init -> { bytes : List(U8), files : List(Engine.File) }),
	}.{

		## `document.query(name, ask)`: the query `name`, which answers
		## `ask(state, q)` from the state the preparation built. Both `q` and
		## the answer must be `Wire.Sendable`. Names share the catalogue's
		## namespace with programs and preparations.
		query : Prepared(init, state), Str, (state, q -> out) -> Query(init, state, q, out)
			where [q.Wire.Sendable, out.Wire.Sendable]
		query = |p, name, ask| {
			name,
			prep: p.name,
			deadline_ms: 0,
			policy: Stop,
			send_init: p.send,
			send_query: |q| sent(q),
			receive: |bytes| match Wire.decode(bytes) {
				Ok(output) => output
				Err(_) => crash "contract: worker program \"${name}\" answered with bytes that are not its output type"
			},
			answer: {
				name,
				run: |state, bytes, files| match Wire.decode_with_files(bytes, files) {
					Ok(q) => payload_of(name, ask(state, q))
					Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its query type"
				},
			},
		}

		## Like `query`, for a query that can fail, as `fallible` is to
		## `pure`: the query's output is its `Try`.
		fallible_query : Prepared(init, state), Str, (state, q -> Try(ok, err)) -> Query(init, state, q, Try(ok, err))
			where [q.Wire.Sendable, ok.Wire.Sendable, err.Wire.Sendable]
		fallible_query = |p, name, ask| {
			name,
			prep: p.name,
			deadline_ms: 0,
			policy: Stop,
			send_init: p.send,
			send_query: |q| sent(q),
			receive: |bytes| received_try(name, bytes),
			answer: {
				name,
				run: |state, bytes, files| match Wire.decode_with_files(bytes, files) {
					Ok(q) => match ask(state, q) {
						Ok(value) => payload_of(name, value).append(0)
						Err(error) => payload_of(name, error).append(1)
					}
					Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its query type"
				},
			},
		}

		## The preparation's entry for `Program.with_workers`, with the
		## queries it answers (each query's `answers()`). It registers the
		## preparation's name and each query's name; a name registered twice
		## is a contract error when the app mounts, and asking a preparation
		## a query it does not list is a contract error in the worker.
		registration : Prepared(init, state), List(Answer(state)) -> Engine.Registration
		registration = |p, answers| {
			name = p.name
			build = p.build
			Core.registration_prepared(
				name,
				answers.map(|a| a.name),
				|bytes, files| {
					state = build(bytes, files)
					Core.kept(
						name,
						|q, qbytes, qfiles| match answers.find_first(|a| a.name == q) {
							Ok(a) => (a.run)(state, qbytes, qfiles)
							Err(_) => crash "contract: worker program \"${q}\" is not a query of the preparation \"${name}\""
						},
					)
				},
			)
		}
	}

	## `prepared(name, prepare)`: the preparation `name`, which turns its
	## input into the state its queries read with `prepare`. The input must
	## be `Wire.Sendable`; the state need not be.
	##
	## Whether a worker holds the state for an input is decided by the
	## input's exact bytes: a query over an equal input in a worker that
	## kept the state reuses it. Comparing those bytes costs the page time
	## proportional to the input on each query, so a large input should be
	## a `File` (or a slice of one), whose identity is its handle and range,
	## not its bytes; a worker reads a file's bytes once, when it prepares.
	prepared : Str, (init -> state) -> Prepared(init, state)
		where [init.Wire.Sendable]
	prepared = |name, prepare| {
		name,
		build: |bytes, files| match Wire.decode_with_files(bytes, files) {
			Ok(init) => prepare(init)
			Err(_) => crash "contract: worker program \"${name}\" was sent bytes that are not its preparation's input type"
		},
		send: |init| sent(init),
	}

	## What a query is asked about: the preparation's `input` and the
	## query's own `query`.
	Asked(init, q) : { input : init, query : q }

	## What happens to a run of a query when its request is cancelled (its
	## site disposed, or a `latest` or `derive` site moving on) while it
	## runs. `Stop`, the default, ends the worker running it, as for any
	## program, and the state that worker held goes with it. `Finish` lets
	## the run complete and drops its answer, so the worker keeps the state
	## for the next query. Either way the app never sees the cancelled
	## run's answer. A deadline always stops the run.
	Cancel : [Stop, Finish]

	## A query's entry for its preparation's `registration`: the query's
	## name and how it answers from the typed state.
	Answer(state) :: { name : Str, run : (state, List(U8), List(List(U8)) -> List(U8)) }

	## A typed query of a preparation, from an `Asked(init, q)` to `out`.
	## Use it as a [Program] is used: `request` and `result` in an effect
	## site, or `Worker.derive` and `Worker.derive_when`.
	Query(init, state, q, out) :: {
		name : Str,
		prep : Str,
		deadline_ms : U32,
		policy : Cancel,
		send_init : (init -> { bytes : List(U8), files : List(Engine.File) }),
		send_query : (q -> { bytes : List(U8), files : List(Engine.File) }),
		receive : (List(U8) -> out),
		answer : Answer(state),
	}.{

		## Stop a job that has not answered `ms` milliseconds after it was
		## requested, and answer `Timeout`. The deadline includes the time a
		## worker spends preparing.
		with_deadline_ms : Query(init, state, q, out), U32 -> Query(init, state, q, out)
		with_deadline_ms = |p, ms| { ..p, deadline_ms: ms }

		## What a cancelled run does (see [Cancel]); `Stop` by default.
		with_cancel : Query(init, state, q, out), Cancel -> Query(init, state, q, out)
		with_cancel = |p, policy| { ..p, policy }

		## The query's entry for its preparation's `registration`.
		answers : Query(init, state, q, out) -> Answer(state)
		answers = |p| p.answer

		## A request to answer `query` over the preparation's `input`, for an
		## effect site's plan. Both are snapshots, encoded when the request
		## is issued.
		request : Query(init, state, q, out), Asked(init, q) -> Engine.Req
		request = |p, { input, query }| {
			init = (p.send_init)(input)
			asked = (p.send_query)(query)
			policy = match p.policy {
				Stop => 1
				Finish => 2
			}
			prep = p.prep.to_utf8()
			header = le32(le32(le32([], prep.len().to_u32_wrap()).concat(prep), init.bytes.len().to_u32_wrap()), init.files.len().to_u32_wrap()).append(policy)
			Ask({ program: p.name, input: header.concat(init.bytes).concat(asked.bytes), files: init.files.concat(asked.files), deadline_ms: p.deadline_ms })
		}

		## The answer to a `request`, as `Program.result`.
		result : Query(init, state, q, out), Engine.Res -> Try(out, Error)
		result = |p, res| match res {
			Work(bytes) => Ok((p.receive)(bytes))
			FileFailed(reason) => Err(FileFailed(reason))
			WorkLost(fault) => Err(Lost(fault))
			Timeout => Err(Timeout)
			Refused => Err(Refused)
			_ => crash "contract: Worker.result was given a result that is not from a worker request"
		}
	}
}

## A request's payload and the files it refers to. A page input nested too
## deep is sent anyway and refused in the worker, where that is contained.
sent : input -> { bytes : List(U8), files : List(Engine.File) } where [input.Wire.Sendable]
sent = |input| {
	{ bytes, files, deep: _ } = Wire.encode_with_files(input)
	{ bytes, files }
}

## A program's answer as its payload. An answer nesting containers deeper
## than `Wire.decode` accepts would be refused by the page, so it is a
## contract error here, in the worker instance, where it is contained.
payload_of : Str, output -> List(U8) where [output.Wire.Sendable]
payload_of = |name, output| match Wire.try_encode(output) {
	Ok(bytes) => bytes
	Err(TooDeep) => crash "contract: worker program \"${name}\" returned a value nested deeper than 512 containers, which the page cannot decode"
}

## A fallible answer: the value or the error, then `0` or `1`.
received_try : Str, List(U8) -> Try(ok, err) where [ok.Wire.Sendable, err.Wire.Sendable]
received_try = |name, bytes| {
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
}

## A deadline as the request carries it: `0` is none.
deadline_ms_of : [Unlimited, Ms(U32)] -> U32
deadline_ms_of = |deadline| match deadline {
	Unlimited => 0
	Ms(ms) => ms
}

## `v` appended to `buf` as four little-endian bytes.
le32 : List(U8), U32 -> List(U8)
le32 = |buf, v| buf.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

## A program's entry runs the calculation on what `send` encoded, and
## `receive` reads what it returned.
expect {
	double = Worker.program({ name: "test/double", run: |n| n * 2.U64 })
	(double.receive)((double.run)((double.send)(21).bytes, [])) == 42
}

## A record in and a list out need no codec, and a deadline is carried on the
## request; a program without one asks for none.
expect {
	names = Worker.program({ name: "test/names", run: |{ prefix, suffixes }| suffixes.map(|suffix| "${prefix}${suffix}"), deadline: Ms(250) })
	plain = Worker.program({ name: "test/plain", run: |n| n + 1.U64 })
	answer = match names.request({ prefix: "n", suffixes: ["0", "1", "2"] }) {
		Work({ program, input, files: _, deadline_ms }) => (program, (names.receive)((names.run)(input, [])), deadline_ms)
		_ => ("", [], 0)
	}
	unlimited = match plain.request(1) {
		Work({ deadline_ms, .. }) => deadline_ms
		_ => 1
	}
	(answer, unlimited) == (("test/names", ["n0", "n1", "n2"], 250), 0)
}

## A fallible program's own error is an answer; a deadline, a refusal, a
## lost worker and an unread file are not.
expect {
	parse = Worker.fallible({ name: "test/parse", run: |text| U64.from_str(text).map_err(|_| NotANumber(text)) })
	job : Str -> Engine.Res
	job = |text| Work((parse.run)((parse.send)(text).bytes, []))
	actual =
		\\good: ${Str.inspect(parse.result(job("7")))}
		\\bad: ${Str.inspect(parse.result(job("seven")))}
		\\late: ${Str.inspect(parse.result(Timeout))}
		\\lost: ${Str.inspect(parse.result(WorkLost(AppCrash)))}
		\\unread: ${Str.inspect(parse.result(FileFailed(Unreadable)))}
	expected =
		\\good: Ok(Ok(7))
		\\bad: Ok(Err(NotANumber("seven")))
		\\late: Err(Timeout)
		\\lost: Err(Lost(AppCrash))
		\\unread: Err(FileFailed(Unreadable))
	actual == expected
}

## A layer that follows a program keeps its previous answer while the next
## is pending, settles on an answer or a failure, and `Skip` clears it.
expect {
	double = Worker.program({ name: "test/double", run: |n| n * 2.U64 })
	follow = Core.follow_when(double)
	first = (follow.pending)(follow.init, Run(1))
	answered = (follow.resolve)(first, Run(1), Work((double.run)((double.send)(1).bytes, [])))
	again = (follow.pending)(answered, Run(2))
	failed = (follow.resolve)(again, Run(2), Refused)
	skipped = (follow.pending)(failed, Skip)
	actual =
		\\first: ${Str.inspect(first)}
		\\answered: ${Str.inspect(answered)}
		\\again: ${Str.inspect(again)}
		\\failed: ${Str.inspect(failed)}
		\\skipped: ${Str.inspect(skipped)}
		\\plans: ${Str.inspect([(follow.plan)(Skip).len(), (follow.plan)(Run(3)).len()])}
	expected =
		\\first: { answer: Unanswered, request: Pending }
		\\answered: { answer: Answered(2), request: Idle }
		\\again: { answer: Answered(2), request: Pending }
		\\failed: { answer: Failed(Refused), request: Idle }
		\\skipped: { answer: Unanswered, request: Idle }
		\\plans: [0, 1]
	actual == expected
}
