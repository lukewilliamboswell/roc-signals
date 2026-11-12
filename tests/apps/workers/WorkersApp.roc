import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Wire
import pf.Worker

## Worker test app: effect sites that issue `Work` requests for the tasks
## below, each answered as an ordinary effect-result turn. Every result is
## appended to the log (`test-id "log"`). Every task but "Deep" maps bytes
## to bytes (`Wire.Bytes`, one block each way) and cannot fail.
## - "Upper" issues one job, "Batch" four at once (several in flight, and
##   more than a small pool holds).
## - "Panel" mounts a `when` branch whose site issues a long job at mount;
##   closing it disposes the site, which cancels the job.
## - "Spin" runs `spin` for the number of rounds in "Rounds"; "Slow" runs
##   the same calculation as a task with a 50 ms deadline.
## - "Crash" runs a task that crashes, "Tail" one that returns a slice of
##   its input, and "Missing" issues work for a task nobody registered (a
##   contract error at issue time).
## - "Grow" runs a task that allocates 16 MiB, growing its instance's
##   memory (the monitor's per-instance memory figures).
## - "Deep" runs a task whose answer nests deeper than the page could
##   decode: the worker refuses to send it, and only that job is lost.
WorkersApp := [].{
	S : {
		upper : U64,
		batch : U64,
		panel : Bool,
		rounds : Str,
		spin : Engine.Outbox(Str),
		slow : Engine.Outbox(Str),
		crashes : U64,
		tails : U64,
		missing : U64,
		grows : U64,
		deeps : U64,
		log : List(Str),
	}

	Ctx : In(Root, S)

	initial : S
	initial = { upper: 0, batch: 0, panel: False, rounds: "1000", spin: Engine.outbox({}), slow: Engine.outbox({}), crashes: 0, tails: 0, missing: 0, grows: 0, deeps: 0, log: [] }

	## A task from bytes to bytes that cannot fail: every task here but
	## `deep`.
	Bytes : Worker.Task(Wire.Bytes, Wire.Bytes, Worker.Never)

	## The task `name`, whose jobs run `f` on the bytes they are sent.
	bytes_task : Str, (List(U8) -> List(U8)) -> Bytes
	bytes_task = |name, f| Worker.task({ name, run!: |input| Ok(Wire.Bytes.from_list(f(input.to_list()))) })

	upper : Bytes
	upper = WorkersApp.bytes_task("test.roc-signals/upper", WorkersApp.upper_bytes)

	spin : Bytes
	spin = WorkersApp.bytes_task("test.roc-signals/spin", WorkersApp.spin_bytes)

	## The spin calculation with a 50 ms deadline.
	slow : Bytes
	slow = Worker.task({ name: "test.roc-signals/slow", run!: |input| Ok(Wire.Bytes.from_list(WorkersApp.spin_bytes(input.to_list()))), deadline: Ms(50) })

	## A task that always crashes: its worker instance is poisoned.
	crasher : Bytes
	crasher = WorkersApp.bytes_task("test.roc-signals/crash", |_| crash "the crash task crashed, as it always does")

	## The input without its first byte: a slice of the input.
	tail : Bytes
	tail = WorkersApp.bytes_task("test.roc-signals/tail", |input| input.drop_first(1))

	grow : Bytes
	grow = WorkersApp.bytes_task("test.roc-signals/grow", WorkersApp.grow_bytes)

	## A task nobody registers: a request for it is a contract error when it
	## is issued.
	missing : Bytes
	missing = WorkersApp.bytes_task("test.roc-signals/missing", |input| input)

	## A chain of containers, as deep as the task is asked to build.
	Chain := [End, Link(Chain)].{
		parser_for : _
		encoder_for : _
	}

	## A chain `depth` links long: more than 512 is deeper than a payload may
	## nest.
	deep : Worker.Task(U64, Chain, Worker.Never)
	deep = Worker.task({
		name: "test.roc-signals/deep",
		run!: |depth| {
			var $chain = Chain.End
			var $i = 0.U64
			while $i < depth {
				$chain = Chain.Link($chain)
				$i = $i + 1
			}
			Ok($chain)
		},
	})

	## ASCII letters to upper case; every other byte unchanged.
	upper_bytes : List(U8) -> List(U8)
	upper_bytes = |input| input.map(|b| if (b >= 97 and b <= 122) b - 32 else b)

	## Busy work: the decimal number of rounds in, a summary out.
	spin_bytes : List(U8) -> List(U8)
	spin_bytes = |input| {
		rounds = U64.from_str(Str.from_utf8(input) ?? "0") ?? 0
		var $x = 88172645463325252.U64
		var $i = 0.U64
		while $i < rounds {
			$x = $x.bitwise_xor($x.shl_wrap(13))
			$x = $x.bitwise_xor($x.shr_zf_wrap(7))
			$x = $x.bitwise_xor($x.shl_wrap(17))
			$i = $i + 1
		}
		"spun ${rounds.to_str()} ${($x % 1000).to_str()}".to_utf8()
	}

	## Memory: the decimal number of bytes in; a list that long is allocated
	## and its length comes out.
	grow_bytes : List(U8) -> List(U8)
	grow_bytes = |input| {
		n = U64.from_str(Str.from_utf8(input) ?? "0") ?? 0
		List.repeat(1.U8, n).len().to_str().to_utf8()
	}

	## A request for a job of a bytes task on `input`.
	job : Bytes, List(U8) -> Engine.Req
	job = |task, input| task.request(Wire.Bytes.from_list(input))

	## A job's result as the log shows it; a task that cannot fail has no
	## `Failed` arm.
	described : Try(a, Worker.Error(Worker.Never)), (a -> Str) -> Str
	described = |r, shown| match r {
		Ok(a) => shown(a)
		Err(Lost(fault)) => "lost ${Str.inspect(fault)}"
		Err(Timeout) => "timeout"
		Err(Refused) => "refused"
	}

	## A bytes task's result, its output as text.
	describe : Bytes, Engine.Res -> Str
	describe = |task, r| WorkersApp.described(task.result(r), |out| Str.from_utf8(out.to_list()) ?? "bytes")

	log_line : S, Str -> S
	log_line = |s, line| { ..s, log: s.log.append(line) }

	logs : State(Ctx, S), Str, (Engine.Res -> Str) -> Engine.Reaction(Ctx, a)
	logs = |st, label, shown| st.on_result(|s, _, r| WorkersApp.log_line(s, "${label}:${shown(r)}"))

	## The reaction of a bytes task's site, logging under `label`.
	logs_of : State(Ctx, S), Str, Bytes -> Engine.Reaction(Ctx, a)
	logs_of = |st, label, task| WorkersApp.logs(st, label, |r| WorkersApp.describe(task, r))

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"workers",
			[
				Html.button("Upper", [], st.update(|s| { ..s, upper: s.upper + 1 })),
				Engine.on_change(v.map(|s| s.upper), |n| [WorkersApp.job(WorkersApp.upper, "job ${n.to_str()}".to_utf8())], WorkersApp.logs_of(st, "upper", WorkersApp.upper)),
				Html.button("Batch", [], st.update(|s| { ..s, batch: s.batch + 1 })),
				Engine.on_change(
					v.map(|s| s.batch),
					|n| [1.U64, 2, 3, 4].map(|i| WorkersApp.job(WorkersApp.upper, "b${n.to_str()}-${i.to_str()}".to_utf8())),
					WorkersApp.logs_of(st, "batch", WorkersApp.upper),
				),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[
							Engine.watch(Engine.const({}), |_| [WorkersApp.job(WorkersApp.spin, "400000000".to_utf8())], WorkersApp.logs_of(st, "panel", WorkersApp.spin)),
							Engine.text("panel open"),
						],
					),
					|| Engine.text(""),
				),
				Html.text_input(Engine.const("Rounds"), "text", v.map(|s| s.rounds), [], st.set_value(|s, t| { ..s, rounds: t })),
				# Each press posts the rounds it was made with, so editing
				# "Rounds" alone issues nothing and pressing twice runs twice.
				Html.button("Spin", [], st.update(|s| { ..s, spin: s.spin.post(s.rounds) })),
				Engine.on_post(v.map(|s| s.spin), |rounds| [WorkersApp.job(WorkersApp.spin, rounds.to_utf8())], WorkersApp.logs_of(st, "spin", WorkersApp.spin)),
				Html.button("Slow", [], st.update(|s| { ..s, slow: s.slow.post(s.rounds) })),
				Engine.on_post(v.map(|s| s.slow), |rounds| [WorkersApp.job(WorkersApp.slow, rounds.to_utf8())], WorkersApp.logs_of(st, "slow", WorkersApp.slow)),
				Html.button("Crash", [], st.update(|s| { ..s, crashes: s.crashes + 1 })),
				Engine.on_change(v.map(|s| s.crashes), |_| [WorkersApp.job(WorkersApp.crasher, [])], WorkersApp.logs_of(st, "crash", WorkersApp.crasher)),
				Html.button("Tail", [], st.update(|s| { ..s, tails: s.tails + 1 })),
				Engine.on_change(v.map(|s| s.tails), |n| [WorkersApp.job(WorkersApp.tail, "xtail ${n.to_str()}".to_utf8())], WorkersApp.logs_of(st, "tail", WorkersApp.tail)),
				Html.button("Missing", [], st.update(|s| { ..s, missing: s.missing + 1 })),
				Engine.on_change(v.map(|s| s.missing), |_| [WorkersApp.job(WorkersApp.missing, [])], WorkersApp.logs_of(st, "missing", WorkersApp.missing)),
				Html.button("Grow", [], st.update(|s| { ..s, grows: s.grows + 1 })),
				Engine.on_change(v.map(|s| s.grows), |_| [WorkersApp.job(WorkersApp.grow, "16777216".to_utf8())], WorkersApp.logs_of(st, "grow", WorkersApp.grow)),
				Html.button("Deep", [], st.update(|s| { ..s, deeps: s.deeps + 1 })),
				Engine.on_change(v.map(|s| s.deeps), |_| [WorkersApp.deep.request(600)], WorkersApp.logs(st, "deep", |r| WorkersApp.described(WorkersApp.deep.result(r), |_| "chain"))),
				Html.p_s(v.map(|s| Str.join_with(s.log, "|")), [Engine.test_id("log")]),
			],
		)
	}

	## The program both the page's instance and every worker instance run.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(WorkersApp.initial, |st| WorkersApp.view(st)))
			.with_workers([
				WorkersApp.upper.registration(),
				WorkersApp.spin.registration(),
				WorkersApp.slow.registration(),
				WorkersApp.crasher.registration(),
				WorkersApp.tail.registration(),
				WorkersApp.grow.registration(),
				WorkersApp.deep.registration(),
			])
}
