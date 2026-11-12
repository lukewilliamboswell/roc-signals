import Core
import Engine exposing [Elem, In, Val]
import Wire

## Worker tasks: registered Roc functions an app runs off the page's thread.
##
## A [Task] is a name and a function `run!` from an input to a `Try` of an
## output and the task's own error, made with `task` from a props record.
## The app lists each task's `registration` in `Program.with_workers`, and
## an effect site asks for a job with `request`; the answer comes back as an
## ordinary result, read with `result`. `derive` wraps both in a layer that
## follows the answers for an input, for the common case of showing a value
## computed from other values.
##
## `run!` may be a plain calculation (`run!: |text| Ok(count_words(text))`)
## or it may call the platform's hosted effects on the files its input
## holds: read them (`file.read!`, `file.contents!`) and write new files
## (`Files.build!`, from the platform's `Files` module), which its answer
## may hold. A job's files carry its effects, which the platform hands the
## engine when the job starts. A job's effects are synchronous and act
## only on files; a job cannot wait for a timer, an event or a network
## response, and it reports nothing until it answers.
##
## The page and each worker run the same compiled module, so both know the
## types of every task: inputs, outputs and errors cross as `Wire` payloads
## the compiler derives, and an app writes no codec. A type crosses if it is
## `Wire.Sendable`: numbers, `Bool`, `Str`, lists, sets, dictionaries,
## records, tuples, tag unions, files (as handles, never their bytes), and
## nominal types that declare `parser_for : _` and `encoder_for : _`.
## Functions, state handles and reactive values do not, and using one is a
## compile error at the task's declaration. Send bulk bytes as `Wire.Bytes`,
## which crosses as one block. A task that cannot fail names its error
## [Never].
##
## One execution of a task is a job, and a job runs in an instance that
## shares nothing with the page but the input it is sent, possibly one that
## ran other jobs before. A job is stopped when its site is disposed (unless
## the task says `on_dispose: Keep`), when a `latest` or `derive` site moves
## on to a newer input, or when its deadline expires: a job still waiting
## for a worker is dropped, and a running one is stopped by ending its
## instance, so the next job starts a new one (a task that says `on_cancel:
## Finish` instead lets a cancelled job complete and drops its answer). A
## job that is stopped, times out or fails leaves nothing the page can see:
## the files it was building go with it.
##
## A [Preparation] is an optional shared step, from an input to a state that
## several of its tasks read; a worker may keep that state between jobs,
## which changes how long an answer takes and never what it is.
Worker := [].{

	## Why a job has no output: the task answered with its own `error`
	## (`Failed`), its deadline expired and it was stopped (`Timeout`), the
	## in-flight bound turned the request away (`Refused`), or the worker
	## could not run it or failed running it (`Lost`, with the fault class;
	## the diagnostic goes to the page's console). A crash in a job is
	## `Lost`, never `Failed`: `Failed` is only what `run!` chose to answer.
	Error(error) : [Failed(error), Timeout, Refused, Lost(Engine.WorkFault)]

	## The error of a task that cannot fail: a type with no values.
	## `Worker.Task(Str, U64, Worker.Never)` declares a task that always
	## answers `Ok`, and a `match` on its `result` needs no `Failed` arm.
	## (The empty union `[]` says the same, but `Wire` derives no codec for
	## it, so a task's error is never `[]`.)
	Never := [].{

		## Equal, vacuously: there are no values to compare.
		is_eq : _

		## Never called: there is no value to encode.
		encoder_for : Wire.Format -> (Never, Wire.Enc -> Try(Wire.Enc, []))
		encoder_for = |_| |_, _| crash "internal: a Never value was encoded, and Never has no values"

		## Any bytes are not a `Never`: there is no value to decode.
		parser_for : Wire.Format -> (Wire.State -> Try({ value : Never, rest : Wire.State }, Wire.Error))
		parser_for = |_| |_| Err(UnknownTag)
	}

	## What `task` is told about a task.
	##
	## - `name`: namespaced and unversioned (`"example.org/search/filter"`).
	##   Every instance runs the same module, so a name means one function,
	##   and two tasks with one name are a contract error.
	## - `run!`: what a job does with its input. It answers `Ok(output)`, or
	##   `Err(error)` for a failure the app expects (input that does not
	##   parse, a file the browser can no longer read, a builder over its
	##   bound). A pure calculation is written as a lambda,
	##   `run!: |text| Ok(count_words(text))`.
	## - `deadline`: `Ms(ms)` stops a job that has not answered `ms`
	##   milliseconds after it was requested and answers `Timeout`; the time a
	##   request waits for a free worker counts, and the platform caps it at
	##   ten minutes. `Unlimited`, the default, lets a job run until it
	##   answers or its site stops it.
	## - `on_dispose`: what disposing the site that asked for a job does to
	##   it: `Stop` it (the default), or `Keep` it running and deliver its
	##   answer to the nearest surviving ancestor, for a job whose work must
	##   not be lost when a panel closes.
	## - `on_cancel`: what a running job whose request is cancelled (its site
	##   disposed, or a `latest` or `derive` site moving on) does: `Stop`, the
	##   default, ends the worker running it; `Finish` lets the job complete
	##   and drops its answer, so the worker, and any prepared state it
	##   holds, is kept for the next job. A deadline always stops the job, a
	##   finishing one included, and a finishing job of a task with no
	##   deadline is stopped ten minutes after it was asked for.
	TaskProps(input, output, error) := {
		name : Str,
		run! : input => Try(output, error),
		deadline : [Unlimited, Ms(U32)] ?? Unlimited,
		on_dispose : [Stop, Keep] ?? Stop,
		on_cancel : [Stop, Finish] ?? Stop,
	}

	## A worker task from `input` to `output` that may fail with `error`.
	## Make one with `task`, register it once with `registration`, and use
	## the same value wherever the app asks for a job, so a request can only
	## name a task with the right types.
	Task(input, output, error) :: {
		name : Str,
		deadline_ms : U32,
		on_dispose : [Stop, Keep],
		on_cancel : [Stop, Finish],
		send : (input -> { bytes : List(U8), files : List(Engine.File) }),
		receive : (List(U8), List(Engine.File) -> Try(output, error)),
		entry! : (List(U8), List(Core.File) => List(U8)),
	}.{

		## The task's entry for `Program.with_workers`. Register each task
		## once, in the `Program` the app binds as `main`: a name registered
		## twice is a contract error when the app mounts, and a request for a
		## task that is not registered is a contract error naming it and the
		## site.
		registration : Task(input, output, error) -> Engine.Registration
		registration = |t| Core.registration(t.name, t.entry!)

		## The task's name, as the props record gave it: what a request
		## carries, what the monitor and a spec's `expect-pending-work` name
		## the task's jobs by, and what a stand-in dispatches on.
		name : Task(input, output, error) -> Str
		name = |t| t.name

		## A request for a job of the task on `input`, for an effect site's
		## plan. The input is a snapshot: it is encoded when the request is
		## issued, and later changes to the state it came from do not reach
		## the job. The files it holds travel as handles.
		request : Task(input, output, error), input -> Engine.Req
		request = |t, input| {
			{ bytes, files } = (t.send)(input)
			Work({ task: t.name, input: bytes, files, deadline_ms: t.deadline_ms, on_dispose: t.on_dispose, on_cancel: t.on_cancel, prepared: Unprepared })
		}

		## The answer to a `request`, for an effect site's reaction: the
		## task's output, whose files are now handles the page holds, or why
		## there is none (see [Error]). A result that is not from a worker
		## request is a contract error.
		result : Task(input, output, error), Engine.Res -> Try(output, Error(error))
		result = |t, res| answered(res, t.receive)
	}

	## The task a props record describes:
	## `Worker.task({ name: "example.org/words/count", run!: |text| Ok(count_words(text)) })`.
	## A job runs `run!` on the input it is sent and answers with what it
	## returns. The input, the output and the error must be `Wire.Sendable`;
	## a file in any of them crosses as a handle. Names share the
	## catalogue's namespace with preparations and their tasks.
	task : TaskProps(input, output, error) -> Task(input, output, error)
		where [input.Wire.Sendable, output.Wire.Sendable, error.Wire.Sendable]
	task = |props| {
		{ name, run!, deadline, on_dispose, on_cancel } = props
		{
			name,
			deadline_ms: deadline_ms_of(deadline),
			on_dispose,
			on_cancel,
			send: |input| sent(input),
			receive: |bytes, files| received(name, bytes, files),
			entry!: |bytes, files| answer_of(name, run!(held_input(name, bytes, files))),
		}
	}

	## `derive(task, input, body)` is `Engine.derive` computed in a worker:
	## it gives `body` a layer holding the task's answer for `input`, an
	## `Engine.Remote(output, Worker.Error(error))`.
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
	## `task` is a [Task] or a preparation's [PreparedTask]: anything with
	## `request` and `result`.
	derive : work, Val(ctx, input), (Val(In(ctx, Engine.Remote(output, Error(error))), Engine.Remote(output, Error(error))) -> Elem(In(ctx, Engine.Remote(output, Error(error))))) -> Elem(ctx)
		where [work.request : work, input -> Engine.Req, work.result : work, Engine.Res -> Try(output, Error(error)), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool, error.is_eq : error, error -> Bool]
	derive = |work, input, body| Engine.resource(input, Core.follow(work), body)

	## Like `derive`, for an input that is sometimes not a question: `Run(i)`
	## asks for a job on `i`, and `Skip` stops any job and clears the answer
	## (an empty search box, a form that is not valid yet).
	derive_when : work, Val(ctx, [Run(input), Skip]), (Val(In(ctx, Engine.Remote(output, Error(error))), Engine.Remote(output, Error(error))) -> Elem(In(ctx, Engine.Remote(output, Error(error))))) -> Elem(ctx)
		where [work.request : work, input -> Engine.Req, work.result : work, Engine.Res -> Try(output, Error(error)), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool, error.is_eq : error, error -> Bool]
	derive_when = |work, input, body| Engine.resource(input, Core.follow_when(work), body)

	## `gather(task, inputs, body)` asks the task one job per input (the
	## shards, ranges or batches of one question, which the pool spreads
	## over its workers) and gives `body` an `Engine.Gathered` layer: each
	## job's state as it settles, and the whole list in input order once
	## every job has answered. A new list of inputs stops the old
	## question's jobs, as `derive` does; with `on_cancel: Finish` a worker
	## keeps its prepared state. Each job takes a slot of the in-flight
	## bound, so split a question into no more parts than it allows; the
	## pool queues the jobs beyond `maxWorkers` by itself.
	gather : work, Val(ctx, List(input)), (Val(In(ctx, Engine.Gathered(output, Error(error))), Engine.Gathered(output, Error(error))) -> Elem(In(ctx, Engine.Gathered(output, Error(error))))) -> Elem(ctx)
		where [work.request : work, input -> Engine.Req, work.result : work, Engine.Res -> Try(output, Error(error)), input.is_eq : input, input -> Bool, output.is_eq : output, output -> Bool, error.is_eq : error, error -> Bool]
	gather = |work, inputs, body| Engine.gather(work, inputs, body)

	## How a layer that follows a task stands, in one match: no job asked
	## for yet (`Unasked`), a job `Working`, its answer, or why there is
	## none: the task's own error (`Failed`) beside the platform's.
	Status(output, error) : [Unasked, Working, Answered(output), Failed(error), Timeout, Refused, Lost(Engine.WorkFault)]

	## A worker layer as a [Status], so a view matches one flat union
	## instead of `Failed(Failed(problem))`. While a newer job is `Working`,
	## `remote.answered()` still gives the previous answer.
	status : Engine.Remote(output, Error(error)) -> Status(output, error)
	status = |remote| match (remote.request, remote.answer) {
		(Pending, _) => Working
		(Idle, Answered(output)) => Answered(output)
		(Idle, Failed(Failed(error))) => Failed(error)
		(Idle, Failed(Timeout)) => Timeout
		(Idle, Failed(Refused)) => Refused
		(Idle, Failed(Lost(fault))) => Lost(fault)
		(Idle, Unanswered) => Unasked
	}

	# -- Preparations ---------------------------------------------------------

	## What `prepared` is told about a preparation: its `name`, namespaced
	## like a task's, and `prepare!`, which turns its input into the state its
	## tasks read, or fails with `error`, the error its tasks share. It may
	## read the files its input holds, and its answer must be a function of
	## its input alone, as every job's is. The input must be
	## `Wire.Sendable`; the state need not be.
	PreparationProps(init, state, error) := {
		name : Str,
		prepare! : init => Try(state, error),
	}

	## A preparation: a possibly expensive step from an input of type `init`
	## (a parsed document, an index) to a `state` that several of its tasks
	## read. Make one with `prepared`, make its tasks with `task`, and
	## register it once with `registration`, listing its tasks' entries.
	##
	## Keeping the state is an optimisation the runtime may or may not
	## achieve: a worker that prepared an input may keep the state and run
	## later jobs over the same input from it, so they cost the task, not the
	## preparation. It shows in time and in the monitor, never in an answer:
	## a job's answer is exactly what preparing afresh and running the task
	## would give, and a task never changes the state. A preparation that
	## fails (`prepare!` answers `Err(error)`) answers each of its tasks'
	## jobs `Failed(error)`. The state never crosses to the page.
	Preparation(init, state, error) :: {
		name : Str,
		build! : (List(U8), List(Core.File) => Try(state, error)),
		send : (init -> { bytes : List(U8), files : List(Engine.File) }),
		fail : (error -> List(U8)),
	}.{

		## The task a props record describes, over this preparation's state:
		## `document.task({ name, run!: |lines, query| Ok(search(lines, query)) })`
		## answers `run!(state, query)` from the state the preparation
		## built. The query and the output must be `Wire.Sendable`, and the
		## task shares the preparation's error type. Names share the
		## catalogue's namespace with every other task.
		task : Preparation(init, state, error), PreparedTaskProps(state, query, output, error) -> PreparedTask(init, state, query, output, error)
			where [query.Wire.Sendable, output.Wire.Sendable, error.Wire.Sendable]
		task = |p, props| {
			{ name, run!, deadline, on_dispose, on_cancel } = props
			{
				name,
				prep: p.name,
				deadline_ms: deadline_ms_of(deadline),
				on_dispose,
				on_cancel,
				send_init: p.send,
				send_query: |query| sent(query),
				receive: |bytes, files| received(name, bytes, files),
				entry: {
					name,
					run!: |state, bytes, files| answer_of(name, run!(state, held_input(name, bytes, files))),
				},
			}
		}

		## The preparation's entry for `Program.with_workers`, with the
		## entries of the tasks that read its state
		## (`document.registration([summary.registration(), search.registration()])`).
		## It registers the preparation's name and each task's name; a name
		## registered twice is a contract error when the app mounts, and a job
		## of a task the preparation does not list is a contract error in the
		## worker.
		registration : Preparation(init, state, error), List(PreparedTaskEntry(state)) -> Engine.Registration
		registration = |p, entries| {
			name = p.name
			build! = p.build!
			fail = p.fail
			Core.registration_prepared(
				name,
				entries.map(|e| e.name),
				|bytes, handles| {
					built = build!(bytes, handles)
					Core.kept(
						name,
						|asked, tbytes, thandles| match entries.find_first(|e| e.name == asked) {
							Ok(e) =>
								match built {
									Ok(state) => {
										run! = e.run!
										run!(state, tbytes, thandles)
									}
									Err(error) => fail(error)
								}
							Err(_) => crash "contract: worker task \"${asked}\" is not a task of the preparation \"${name}\""
						},
					)
				},
			)
		}
	}

	## The preparation a props record describes:
	## `Worker.prepared({ name: "example.org/notes/document", prepare!: |text| Ok(lines_of(text)) })`.
	##
	## Whether a worker holds the state for an input is decided by the
	## input's exact bytes and the handles and ranges of its files: a job
	## over an equal input in a worker that kept the state reuses it.
	## Comparing those bytes costs the page time proportional to the input
	## on each job, so a large input should be a `File` (or a slice of one),
	## whose identity is its handle and range, not its bytes, and which
	## `prepare!` reads with `contents!`.
	prepared : PreparationProps(init, state, error) -> Preparation(init, state, error)
		where [init.Wire.Sendable, error.Wire.Sendable]
	prepared = |props| {
		{ name, prepare! } = props
		{
			name,
			build!: |bytes, files| prepare!(held_input(name, bytes, files)),
			send: |init| sent(init),
			fail: |error| encoded_answer(name, error, 1),
		}
	}

	## What a preparation's `task` is told about a task: as [TaskProps],
	## with `run!` taking the preparation's state beside the job's own
	## input. A deadline includes the time a worker spends preparing.
	PreparedTaskProps(state, query, output, error) := {
		name : Str,
		run! : (state, query => Try(output, error)),
		deadline : [Unlimited, Ms(U32)] ?? Unlimited,
		on_dispose : [Stop, Keep] ?? Stop,
		on_cancel : [Stop, Finish] ?? Stop,
	}

	## What a preparation's task is asked: the preparation's `input` and the
	## task's own `query`, for `request`, `derive` and `derive_when`.
	Question(init, query) : { input : init, query : query }

	## A preparation's task's entry for its preparation's `registration`,
	## from the task's `registration()`: the task's name and how it runs on
	## the typed state.
	PreparedTaskEntry(state) :: { name : Str, run! : (state, List(U8), List(Core.File) => List(U8)) }

	## A task of a preparation, from a `Question(init, query)` to `output`,
	## failing with the preparation's `error`. Use it as a [Task] is used:
	## `request` and `result` in an effect site, or `Worker.derive` and
	## `Worker.derive_when`.
	PreparedTask(init, state, query, output, error) :: {
		name : Str,
		prep : Str,
		deadline_ms : U32,
		on_dispose : [Stop, Keep],
		on_cancel : [Stop, Finish],
		send_init : (init -> { bytes : List(U8), files : List(Engine.File) }),
		send_query : (query -> { bytes : List(U8), files : List(Engine.File) }),
		receive : (List(U8), List(Engine.File) -> Try(output, error)),
		entry : PreparedTaskEntry(state),
	}.{

		## The task's entry for its preparation's `registration`.
		registration : PreparedTask(init, state, query, output, error) -> PreparedTaskEntry(state)
		registration = |t| t.entry

		## The task's name, as `Task.name` gives a task's.
		name : PreparedTask(init, state, query, output, error) -> Str
		name = |t| t.name

		## A request to run the task on `query` over the preparation's
		## `input`, for an effect site's plan. Both are snapshots, encoded
		## when the request is issued.
		request : PreparedTask(init, state, query, output, error), Question(init, query) -> Engine.Req
		request = |t, { input, query }| {
			init = (t.send_init)(input)
			asked = (t.send_query)(query)
			of = Prepared({ name: t.prep, input_len: init.bytes.len(), input_files: init.files.len() })
			Work({ task: t.name, input: init.bytes.concat(asked.bytes), files: init.files.concat(asked.files), deadline_ms: t.deadline_ms, on_dispose: t.on_dispose, on_cancel: t.on_cancel, prepared: of })
		}

		## The answer to a `request`, as `Task.result`.
		result : PreparedTask(init, state, query, output, error), Engine.Res -> Try(output, Error(error))
		result = |t, res| answered(res, t.receive)
	}
}

## A job's input, decoded with the files its worker's host minted handles
## for, in the request's order, which carry the job's effects.
held_input : Str, List(U8), List(Core.File) -> input where [input.Wire.Sendable]
held_input = |name, bytes, files| match Wire.decode_with_held(bytes, files) {
	Ok(input) => input
	Err(_) => crash "contract: worker task \"${name}\" was sent bytes that are not its input type"
}

## A job's answer as its entry returns it: the tokens of the files it
## holds, then its bytes and a byte that says whether it is `Ok` (0) or
## `Err` (1). An answer nesting containers deeper than the page decodes, or
## holding more files than an answer may, is a contract error here, in the
## worker, where it is contained.
answer_of : Str, Try(output, error) -> List(U8) where [output.Wire.Sendable, error.Wire.Sendable]
answer_of = |name, answer| match answer {
	Ok(value) => encoded_answer(name, value, 0)
	Err(error) => encoded_answer(name, error, 1)
}

## One side of an answer, with its flag byte.
encoded_answer : Str, value, U8 -> List(U8) where [value.Wire.Sendable]
encoded_answer = |name, value, flag| {
	encoded = Wire.encode_with_files(value)
	if encoded.deep {
		crash "contract: worker task \"${name}\" returned a value nested deeper than 512 containers, which the page cannot decode"
	}
	Core.task_answer(name, encoded.bytes.append(flag), encoded.files)
}

## A job's answer as the page reads it: the output or the task's error,
## with the files the page now holds for it.
received : Str, List(U8), List(Engine.File) -> Try(output, error) where [output.Wire.Sendable, error.Wire.Sendable]
received = |name, bytes, files| {
	body = bytes.drop_last(1)
	match bytes.last() {
		Ok(0) => match Wire.decode_with_held(body, files) {
			Ok(value) => Ok(value)
			Err(_) => crash "contract: worker task \"${name}\" answered with bytes that are not its output type"
		}
		Ok(1) => match Wire.decode_with_held(body, files) {
			Ok(error) => Err(error)
			Err(_) => crash "contract: worker task \"${name}\" answered with bytes that are not its error type"
		}
		_ => crash "contract: worker task \"${name}\" answered without saying whether it succeeded"
	}
}

## A worker request's result as a task's: its answer, or why there is none.
answered : Engine.Res, (List(U8), List(Engine.File) -> Try(output, error)) -> Try(output, [Failed(error), Timeout, Refused, Lost(Engine.WorkFault)])
answered = |res, receive| match res {
	Work({ output, files }) =>
		match receive(output, files) {
			Ok(value) => Ok(value)
			Err(error) => Err(Failed(error))
		}
	WorkLost(fault) => Err(Lost(fault))
	Timeout => Err(Timeout)
	Refused => Err(Refused)
	_ => crash "contract: Worker.result was given a result that is not from a worker request"
}

## A request's payload and the files it refers to. A page input nested too
## deep is sent anyway and refused in the worker, where that is contained.
sent : input -> { bytes : List(U8), files : List(Engine.File) } where [input.Wire.Sendable]
sent = |input| {
	{ bytes, files, deep: _ } = Wire.encode_with_files(input)
	{ bytes, files }
}

## A deadline as the request carries it: `0` is none.
deadline_ms_of : [Unlimited, Ms(U32)] -> U32
deadline_ms_of = |deadline| match deadline {
	Unlimited => 0
	Ms(ms) => ms
}

## A task's request carries its name, its deadline and its policies, and
## its answer is read back as an output or the task's own error; a
## deadline, a refusal and a lost worker are not answers.
expect {
	parse : Worker.Task(Str, U64, [NotANumber(Str)])
	parse = Worker.task({ name: "test/parse", run!: |text| U64.from_str(text).map_err(|_| NotANumber(text)), deadline: Ms(250), on_cancel: Finish })
	shape = match parse.request("7") {
		Work({ task, deadline_ms, on_dispose, on_cancel, prepared, .. }) => Str.inspect((task, deadline_ms, on_dispose, on_cancel, prepared))
		_ => "not a work request"
	}
	answer = |bytes| Work({ output: bytes, files: [] })
	actual =
		\\name: ${parse.name()}
		\\request: ${shape}
		\\good: ${Str.inspect(parse.result(answer(Wire.encode(7.U64).append(0))))}
		\\bad: ${Str.inspect(parse.result(answer(Wire.encode(NotANumber("seven")).append(1))))}
		\\late: ${Str.inspect(parse.result(Timeout))}
		\\lost: ${Str.inspect(parse.result(WorkLost(AppCrash)))}
	expected =
		\\name: test/parse
		\\request: ("test/parse", 250, Stop, Finish, Unprepared)
		\\good: Ok(7)
		\\bad: Err(Failed(NotANumber("seven")))
		\\late: Err(Timeout)
		\\lost: Err(Lost(AppCrash))
	actual == expected
}

## A task that cannot fail matches its result with no `Failed` arm.
expect {
	double : Worker.Task(U64, U64, Worker.Never)
	double = Worker.task({ name: "test/double", run!: |n| Ok(n * 2) })
	shown = match double.result(Work({ output: Wire.encode(42.U64).append(0), files: [] })) {
		Ok(n) => n.to_str()
		Err(Timeout) => "late"
		Err(Refused) => "refused"
		Err(Lost(_)) => "lost"
	}
	shown == "42"
}

## A layer that follows a task keeps its previous answer while the next is
## pending, settles on an answer or a failure, and `Skip` clears it.
expect {
	double : Worker.Task(U64, U64, Worker.Never)
	double = Worker.task({ name: "test/double", run!: |n| Ok(n * 2) })
	follow = Core.follow_when(double)
	first = (follow.pending)(follow.init, Run(1))
	answered_now = (follow.resolve)(first, Run(1), Work({ output: Wire.encode(2.U64).append(0), files: [] }))
	again = (follow.pending)(answered_now, Run(2))
	failed = (follow.resolve)(again, Run(2), Refused)
	skipped = (follow.pending)(failed, Skip)
	actual =
		\\first: ${Str.inspect(first)}
		\\answered: ${Str.inspect(answered_now)}
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

## A layer's status is one flat match over every arm, and `answered` keeps
## the latest answer while a newer job works but none after a failure.
expect {
	done : Engine.Remote(U64, Worker.Error([Unlucky]))
	done = { request: Idle, answer: Answered(2) }
	failed : Engine.Remote(U64, Worker.Error([Unlucky]))
	failed = { request: Idle, answer: Failed(Failed(Unlucky)) }
	working = { ..done, request: Pending }
	status = |answer| Str.inspect(Worker.status({ request: Idle, answer }))
	actual =
		\\unasked: ${status(Unanswered)}
		\\working: ${Str.inspect(Worker.status(working))} ${Str.inspect(working.answered())}
		\\answered: ${Str.inspect(Worker.status(done))} ${Str.inspect(done.answered())}
		\\failed: ${Str.inspect(Worker.status(failed))} ${Str.inspect(failed.answered())}
		\\timeout: ${status(Failed(Timeout))}
		\\refused: ${status(Failed(Refused))}
		\\lost: ${status(Failed(Lost(AppCrash)))}
		\\inspect: ${Str.inspect(working)}
	expected =
		\\unasked: Unasked
		\\working: Working Ok(2)
		\\answered: Answered(2) Ok(2)
		\\failed: Failed(Unlucky) Err(NoAnswer)
		\\timeout: Timeout
		\\refused: Refused
		\\lost: Lost(AppCrash)
		\\inspect: { answer: Answered(2), request: Pending }
	actual == expected
}

## A gathered layer settles each job at its position, in any order, keeps
## the previous whole answer while a question works, answers every output
## in input order once none works, fails with the first failure in input
## order, and answers an empty question at once.
expect {
	double : Worker.Task(U64, U64, [Odd])
	double = Worker.task({ name: "test/double-even", run!: |n| if (n % 2 == 0) Ok(n * 2) else Err(Odd) })
	gather = Core.gather(double)
	answer : U64 -> Engine.Res
	answer = |n| Work({ output: Wire.encode(n).append(0), files: [] })
	odd = Work({ output: Wire.encode(Odd).append(1), files: [] })
	asked = (gather.pending)(gather.init, [2, 4, 6])
	last = (gather.resolve)(asked, [2, 4, 6], 2, answer(12))
	first = (gather.resolve)(last, [2, 4, 6], 0, answer(4))
	all = (gather.resolve)(first, [2, 4, 6], 1, answer(8))
	again = (gather.pending)(all, [1, 2])
	one = (gather.resolve)(again, [1, 2], 1, answer(4))
	failed = (gather.resolve)(one, [1, 2], 0, odd)
	refused = (gather.resolve)((gather.pending)(failed, [2, 4]), [2, 4], 1, Refused)
	show : Engine.Gathered(U64, Worker.Error([Odd])) -> Str
	show = |g| "${Str.inspect(g.jobs)} ${Str.inspect(g.all)}"
	actual =
		\\asked: ${show(asked)} ${(gather.plan)([2, 4, 6]).len().to_str()} requests
		\\last: ${show(last)}
		\\first: ${show(first)}
		\\all: ${show(all)}
		\\again: ${show(again)}
		\\failed: ${show(failed)}
		\\refused: ${show(refused)}
		\\empty: ${show((gather.pending)(all, []))} ${(gather.plan)([]).len().to_str()} requests
	expected =
		\\asked: [Working, Working, Working] { answer: Unanswered, request: Pending } 3 requests
		\\last: [Working, Working, Answered(12)] { answer: Unanswered, request: Pending }
		\\first: [Answered(4), Working, Answered(12)] { answer: Unanswered, request: Pending }
		\\all: [Answered(4), Answered(8), Answered(12)] { answer: Answered([4, 8, 12]), request: Idle }
		\\again: [Working, Working] { answer: Answered([4, 8, 12]), request: Pending }
		\\failed: [Failed(Failed(Odd)), Answered(4)] { answer: Failed(Failed(Odd)), request: Idle }
		\\refused: [Working, Failed(Refused)] { answer: Failed(Failed(Odd)), request: Pending }
		\\empty: [] { answer: Answered([]), request: Idle } 0 requests
	actual == expected
}

## A preparation's task carries its preparation and where the
## preparation's input lies on the request, and its deadline and policies
## as any task does.
expect {
	lines : Worker.Preparation(Str, List(Str), Worker.Never)
	lines = Worker.prepared({ name: "test/lines", prepare!: |text| Ok(Str.split_on(text, "\n")) })
	nth = lines.task({ name: "test/lines/nth", run!: |all, n| Ok(all.get(n) ?? ""), deadline: Ms(40), on_cancel: Finish })
	shape = match nth.request({ input: "a\nb", query: 1.U64 }) {
		Work({ task, input, deadline_ms, on_cancel, prepared, .. }) => Str.inspect((task, input.len(), deadline_ms, on_cancel, prepared))
		_ => "not a work request"
	}
	actual =
		\\name: ${nth.name()}
		\\request: ${shape}
		\\answer: ${Str.inspect(nth.result(Work({ output: Wire.encode("b").append(0), files: [] })))}
	expected =
		\\name: test/lines/nth
		\\request: ("test/lines/nth", 12, 40, Finish, Prepared({ input_files: 0, input_len: 4, name: "test/lines" }))
		\\answer: Ok("b")
	actual == expected
}
