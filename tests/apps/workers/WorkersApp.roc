import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Worker test app: effect sites that issue `Work` requests for the pure
## programs below, each answered as an ordinary effect-result turn. Every
## result is appended to the log (`test-id "log"`).
## - "Upper" issues one job, "Batch" four at once (several in flight, and
##   more than a small pool holds).
## - "Panel" mounts a `when` branch whose site issues a long job at mount;
##   closing it disposes the site, which cancels the job.
## - "Spin" runs `spin` for the number of rounds in "Rounds"; "Slow" does the
##   same with a 50 ms deadline.
## - "Crash" runs a program that crashes, "Tail" one that returns a slice of
##   its input, and "Missing" issues work for a program nobody registered (a
##   contract error at issue time).
## - "Grow" runs a program that allocates 16 MiB, growing its instance's
##   memory (the monitor's per-instance memory figures).
WorkersApp := [].{
	S : {
		upper : U64,
		batch : U64,
		panel : Bool,
		rounds : Str,
		spin : Press,
		slow : Press,
		crashes : U64,
		tails : U64,
		missing : U64,
		grows : U64,
		log : List(Str),
	}

	## How many times a button was pressed and the rounds at the last press, so
	## editing "Rounds" alone issues nothing.
	Press : { n : U64, rounds : Str }

	Ctx : In(Root, S)

	initial : S
	initial = { upper: 0, batch: 0, panel: False, rounds: "1000", spin: { n: 0, rounds: "" }, slow: { n: 0, rounds: "" }, crashes: 0, tails: 0, missing: 0, grows: 0, log: [] }

	pressed : Press, Str -> Press
	pressed = |{ n, rounds: _ }, rounds| { n: n + 1, rounds }

	upper_name = "test.roc-signals/upper"

	spin_name = "test.roc-signals/spin"

	crash_name = "test.roc-signals/crash"

	tail_name = "test.roc-signals/tail"

	grow_name = "test.roc-signals/grow"

	## ASCII letters to upper case; every other byte unchanged.
	upper : List(U8) -> List(U8)
	upper = |input| input.map(|b| if (b >= 97 and b <= 122) b - 32 else b)

	## Busy work: the decimal number of rounds in, a summary out.
	spin : List(U8) -> List(U8)
	spin = |input| {
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

	## A program that always crashes: its worker instance is poisoned.
	crasher : List(U8) -> List(U8)
	crasher = |_| crash "the crash program crashed, as it always does"

	## The input without its first byte: a slice of the input.
	tail : List(U8) -> List(U8)
	tail = |input| input.drop_first(1)

	## Memory: the decimal number of bytes in; a list that long is allocated
	## and its length comes out.
	grow : List(U8) -> List(U8)
	grow = |input| {
		n = U64.from_str(Str.from_utf8(input) ?? "0") ?? 0
		List.repeat(1.U8, n).len().to_str().to_utf8()
	}

	job : Str, List(U8), U32 -> Engine.Req
	job = |program, input, deadline_ms| Work({ program, input, deadline_ms })

	describe : Engine.Res -> Str
	describe = |r| match r {
		Work(out) => Str.from_utf8(out) ?? "bytes"
		WorkLost(fault) => "lost ${Str.inspect(fault)}"
		Timeout => "timeout"
		Refused => "refused"
		_ => "other"
	}

	log_line : S, Str -> S
	log_line = |s, line| { ..s, log: s.log.append(line) }

	logs : State(Ctx, S), Str -> Engine.Reaction(Ctx, a)
	logs = |st, label| st.on_result(|s, _, r| WorkersApp.log_line(s, "${label}:${WorkersApp.describe(r)}"))

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"workers",
			[
				Html.button("Upper", [], st.update(|s| { ..s, upper: s.upper + 1 })),
				Engine.on_change(v.map(|s| s.upper), |n| [WorkersApp.job(WorkersApp.upper_name, "job ${n.to_str()}".to_utf8(), 0)], WorkersApp.logs(st, "upper")),
				Html.button("Batch", [], st.update(|s| { ..s, batch: s.batch + 1 })),
				Engine.on_change(
					v.map(|s| s.batch),
					|n| [1.U64, 2, 3, 4].map(|i| WorkersApp.job(WorkersApp.upper_name, "b${n.to_str()}-${i.to_str()}".to_utf8(), 0)),
					WorkersApp.logs(st, "batch"),
				),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[
							Engine.watch(Engine.const({}), |_| [WorkersApp.job(WorkersApp.spin_name, "400000000".to_utf8(), 0)], WorkersApp.logs(st, "panel")),
							Engine.text("panel open"),
						],
					),
					|| Engine.text(""),
				),
				Html.text_input(Engine.const("Rounds"), "text", v.map(|s| s.rounds), [], st.set_value(|s, t| { ..s, rounds: t })),
				Html.button("Spin", [], st.update(|s| { ..s, spin: WorkersApp.pressed(s.spin, s.rounds) })),
				Engine.on_change(v.map(|s| s.spin), |p| [WorkersApp.job(WorkersApp.spin_name, p.rounds.to_utf8(), 0)], WorkersApp.logs(st, "spin")),
				Html.button("Slow", [], st.update(|s| { ..s, slow: WorkersApp.pressed(s.slow, s.rounds) })),
				Engine.on_change(v.map(|s| s.slow), |p| [WorkersApp.job(WorkersApp.spin_name, p.rounds.to_utf8(), 50)], WorkersApp.logs(st, "slow")),
				Html.button("Crash", [], st.update(|s| { ..s, crashes: s.crashes + 1 })),
				Engine.on_change(v.map(|s| s.crashes), |_| [WorkersApp.job(WorkersApp.crash_name, [], 0)], WorkersApp.logs(st, "crash")),
				Html.button("Tail", [], st.update(|s| { ..s, tails: s.tails + 1 })),
				Engine.on_change(v.map(|s| s.tails), |n| [WorkersApp.job(WorkersApp.tail_name, "xtail ${n.to_str()}".to_utf8(), 0)], WorkersApp.logs(st, "tail")),
				Html.button("Missing", [], st.update(|s| { ..s, missing: s.missing + 1 })),
				Engine.on_change(v.map(|s| s.missing), |_| [WorkersApp.job("test.roc-signals/missing", [], 0)], WorkersApp.logs(st, "missing")),
				Html.button("Grow", [], st.update(|s| { ..s, grows: s.grows + 1 })),
				Engine.on_change(v.map(|s| s.grows), |_| [WorkersApp.job(WorkersApp.grow_name, "16777216".to_utf8(), 0)], WorkersApp.logs(st, "grow")),
				Html.p_v(v.map(|s| Str.join_with(s.log, "|")), [Engine.test_id("log")]),
			],
		)
	}

	## The program both the page's instance and every worker instance run.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(WorkersApp.initial, |st| WorkersApp.view(st)))
			.with_workers([
				Engine.registration(WorkersApp.upper_name, WorkersApp.upper),
				Engine.registration(WorkersApp.spin_name, WorkersApp.spin),
				Engine.registration(WorkersApp.crash_name, WorkersApp.crasher),
				Engine.registration(WorkersApp.tail_name, WorkersApp.tail),
				Engine.registration(WorkersApp.grow_name, WorkersApp.grow),
			])
}
