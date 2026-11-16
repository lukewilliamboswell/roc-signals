import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Contract fixture: debug observations never alter the rendered count or jobs.
DbgApp := [].{
	Ctx : In(Root, I64)

	## A preparation refuses a genuinely empty prefix rather than inventing one.
	## The original infallible dbg graph crashes monotype checking on the pinned
	## compiler. https://github.com/roc-lang/roc/issues/13056 tracks a related
	## empty-catalogue failure; a nonempty published-0.5 dbg reduction passes,
	## so a shared cause has not been established.
	Problem : [EmptyPrefix]

	## A kept preparation prints only when a worker actually prepares it.
	preparation : Worker.Preparation(Str, Str, Problem)
	preparation = Worker.preparation({
		name: "dbg/prepare",
		prepare!: |input| {
			dbg { at: "prepare", input }
			if input.is_empty() {
				return Err(EmptyPrefix)
			}
			Ok(input)
		},
	})

	## Successive jobs share preparation input but have distinct answers.
	echo : Worker.PreparedTask(Str, Str, I64, Str, Problem)
	echo = DbgApp.preparation.task({
		name: "dbg/echo",
		on_cancel: Finish,
		run!: |prepared, input| {
			dbg { at: "task", input }
			if input == -2 {
				crash "task boom after dbg"
			}
			if input == -1 {
				observed = DbgApp.delay(input)
				Ok("${prepared}:${input.to_str()}:${observed.to_str()}")
			} else Ok("${prepared}:${input.to_str()}")
		},
	})

	## A separate Stop task proves cancellation ends its instance, unlike Finish.
	stop : Worker.Task(I64, Str, Worker.Never)
	stop = Worker.task({
		name: "dbg/stop",
		run!: |input| {
			dbg { at: "stopped-task", input }
			observed = DbgApp.delay(input)
			Ok(observed.to_str())
		},
	})

	## Bounded work keeps cancellation observable; its answer forces the loop.
	delay : I64 -> U64
	delay = |input| {
		var $result = input.to_u64_wrap() % 65521
		for index in 0.U64..<1000000 {
			$result = ($result * 31 + index) % 65521
		}
		$result
	}

	## Declarations are ordinary Roc evaluation too, before the first frame.
	keys : {} -> List(Str)
	keys = |_unit| {
		dbg { at: "declarations" }
		[]
	}

	## The same app entry serves native specs and actual page/worker contracts.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: DbgApp.keys({}) }, |_boot| Engine.state(0.I64, DbgApp.view)).with_workers([
		DbgApp.preparation.registration([DbgApp.echo.registration()]),
		DbgApp.stop.registration(),
	])

	## Two entries belong to one real handler evaluation, in authored order.
	bump : I64 -> I64
	bump = |count| {
		dbg { at: "handler-first", count }
		dbg { at: "handler-second", count }
		count + 1
	}

	## The reader prints only for a real evaluation, not a native settle probe.
	shown : I64 -> Str
	shown = |count| {
		dbg { at: "reader", count }
		count.to_str()
	}

	## This call exceeds the entry buffer without affecting application output.
	many : I64 -> I64
	many = |count| {
		for index in 0.U64..<2000 {
			dbg { at: "many", index }
		}
		count + 1
	}

	## A multibyte value crosses the per-entry byte bound.
	long : I64 -> I64
	long = |count| {
		dbg Str.join_with(List.repeat("😀", 400), "")
		count + 1
	}

	## The host must retain this entry independently of its crash diagnostic.
	boom : I64 -> I64
	boom = |count| {
		dbg { at: "before-crash", count }
		if count >= 0 {
			crash "boom after dbg"
		}
		count
	}

	## The runtime's in-progress note retains output from an unclassified trap.
	recurse : I64 -> I64
	recurse = |count| {
		dbg { at: "before-recursion", count }
		recurse_forever(count)
	}

	## Answers, including failures, stay ordinary app-visible values.
	answer : Engine.Remote(Str, Worker.Error(Problem)) -> Str
	answer = |remote| match remote.answer {
		Answered(text) => text
		Failed(Failed(EmptyPrefix)) => "empty prefix"
		Failed(_) => "lost"
		_ => "waiting"
	}

	## The plain Stop task remains infallible; stopping it still sends no answer.
	stop_answer : Engine.Remote(Str, Worker.Error(Worker.Never)) -> Str
	stop_answer = |remote| match remote.answer {
		Answered(text) => text
		_ => "waiting"
	}

	## Contract-only fault buttons do not participate in seeded native walks.
	view : State(Ctx, I64) -> Elem(Ctx)
	view = |count| Html.div(
		"dbg",
		[
			Html.button("Increment", [], count.update(DbgApp.bump)),
			Html.button("Reset", [], count.update(|_previous| 0)),
			Html.button("Many", [], count.update(DbgApp.many)),
			Html.button("Long", [], count.update(DbgApp.long)),
			Html.button("Finish", [], count.update(|_previous| -1)),
			Html.button("Task crash", [], count.update(|_previous| -2)),
			Html.button("Empty prefix", [], count.update(|_previous| -4)),
			Html.button("Stop", [], count.update(|_previous| -3)),
			Html.button("Crash", [], count.update(DbgApp.boom)),
			Html.button("Recurse", [], count.update(DbgApp.recurse)),
			Html.p_s(count.signal().map(DbgApp.shown), [Engine.test_id("count")]),
			Engine.when(
				count.signal().map(|value| value == -3),
				|| Worker.resource(DbgApp.stop, count.signal(), |remote| Html.p_s(remote.map(DbgApp.stop_answer), [Engine.test_id("answer")])),
				|| Worker.resource(DbgApp.echo, count.signal().map(|value| { init: if (value == -4) "" else "kept", input: value }), |remote| Html.p_s(remote.map(DbgApp.answer), [Engine.test_id("answer")])),
			),
		],
	)
}

## A deliberately non-tail recursive executor-fault witness. Keep this helper
## private and outside the worker fixture namespace; the equivalent member
## currently crashes monotype checking. The original failure is retained in
## the compiler proof; the related issue linked above does not establish its cause.
recurse_forever : I64 -> I64
recurse_forever = |count| 1 + recurse_forever(count + 1)
