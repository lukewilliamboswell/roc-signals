import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Port
import pf.Worker

## Effect-channel test app: three sites, each shown or hidden by a `when`
## (hiding disposes the branch). Each branch holds:
## - G: watches the site's root counter, issues GET /s<k>/<count> for every
##   nonzero count (plus a `Self` follow-up on multiples of 3, two on
##   multiples of 6, the first of which hides the site mid-drain); its
##   reaction appends to the root log (a surviving state).
## - H: inside a branch-local `state` (hits), issues GET /h<k>/<count>; its
##   reaction increments hits (a state retired when the branch is disposed).
## - an Interval subscription whose ticks append to the root log.
## Disposal stops the interval and reparents G and H requests to the `when`:
## G results still reach the log, H results are skipped writes.
## A popstate subscription at the root appends to the log too.
##
## Two superseding sites follow root counters:
## - L, a `latest` site over the query counter `q`: an HTTP request (with
##   a timeout), an interval, an HTTP request with two `Self` follow-ups
##   (the first bumps `q`, superseding the second), or nothing, by `q % 4`.
##   Its reaction appends to the root log.
## - R, a `resource` over the counter `r`, shown or hidden by a `when`: an
##   HTTP request, a request and a timer, or an interval and a worker job
##   (the echo task, with a deadline), by `r % 3`. Its layer folds
##   answers and is shown as `input|answer|faults`.
## - F, an `on_change` site over the flood counter `f`: 70 timers at once,
##   far past the bound, so one turn refuses dozens of them. Its reaction
##   appends to the root log.
## - A follow-up loop that only the browser contract test arms ("loop"): a
##   refused request whose reaction issues it again.
## - P, a `latest` site over the counter `p`, shown or hidden by a `when`:
##   for a nonzero `p` a port call (kept when P is disposed) and a port
##   subscription (scoped, ended by its JavaScript with `Closed` or
##   `Threw`). Its reaction appends to the root log.
## - X, a `gather` over the counter `g`, shown or hidden by a `when`: one
##   HTTP request per input (one to three, by `g % 3`), each answer settling
##   the job at its position. Its layer is shown as its jobs and its whole
##   answer. Hiding X keeps its requests (they reparent) and their answers
##   are skipped writes to the retired layer.
## - O, an `on_post` site over the outbox `out`: each "post" posts
##   `posts / 2` (so items repeat) and sends one HTTP request for it. Its
##   reaction appends to the root log with the item it was posted with.
FxApp := [].{
	S : { counts : List(U64), shown : List(Bool), log : List(Str), q : U64, r : U64, rshown : Bool, f : U64, n : U64, looping : Bool, p : U64, pshown : Bool, g : U64, gshown : Bool, out : Engine.Outbox(U64), posts : U64 }

	## The resource's layer: the input it was begun for, the last answer, and
	## the timeouts seen.
	Load : { input : U64, answer : Str, faults : U64 }

	Ctx : In(Root, S)

	nsites : U64
	nsites = 3

	url_of : U64, U64 -> Str
	url_of = |k, c| "/s${k.to_str()}/${c.to_str()}"

	plan : U64 -> (U64 -> List(Engine.Req))
	plan = |k| |c| {
		if c == 0 {
			[]
		} else {
			get = Http({ method: "GET", url: FxApp.url_of(k, c), headers: [("accept", "text/plain")], body: "", timeout_ms: FxApp.timeout_of(c) })
			if (c % 6 == 0) [get, Self, Self] else if (c % 3 == 0) [get, Self] else [get]
		}
	}

	## G's per-request timeout: 300 ms for odd counts, else c * 250 s (above
	## the host cap from 4).
	timeout_of : U64 -> U32
	timeout_of = |c| if (c % 2 == 1) 300 else c.to_u32_wrap() * 250000

	describe : U64, U64, Engine.Res -> Str
	describe = |k, c, r| {
		head = "${k.to_str()}:${c.to_str()}"
		match r {
			Http({ status, headers, body }) => "${head}:${status.to_str()}:${body}:${Str.join_with(headers.map(|(n, v)| "${n}=${v}"), ",")}"
			Work({ output, .. }) => "${head}:work:${Str.inspect(output)}"
			WorkLost(fault) => "${head}:lost:${Str.inspect(fault)}"
			Timeout => "${head}:timeout"
			Network(m) => "${head}:net:${m}"
			Refused => "${head}:refused"
			Now => "${head}:self"
			Location(u) => "pop:${u}"
			PortReply(m) => "${head}:port:${m.json}"
			PortFailed(failure) => "${head}:portfail:${Str.inspect(failure)}"
			_ => "${head}:other"
		}
	}

	log_line : S, Str -> S
	log_line = |{ counts, shown, log, q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }, line| { counts, shown, log: log.append(line), q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }

	bump : S, U64 -> S
	bump = |{ counts, shown, log, q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }, k| { counts: counts.update(k, |c| c + 1) ?? counts, shown, log, q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }

	toggle : S, U64 -> S
	toggle = |{ counts, shown, log, q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }, k| { counts, shown: shown.update(k, |b| !b) ?? shown, log, q, r, rshown, f, n, looping, p, pshown, g, gshown, out, posts }

	## X's inputs for `g`: none for 0, else one to three numbers.
	inputs_x : U64 -> List(U64)
	inputs_x = |g| {
		var $inputs = []
		if g != 0 {
			for i in 0..<(g % 3 + 1) {
				$inputs = $inputs.append(g * 10 + i)
			}
		}
		$inputs
	}

	## How X asks for an input and reads an answer: any result is an
	## answer or a failure, so an arbitrary result for one of its ids
	## settles a job.
	Asker := [Asker].{
		request : Asker, U64 -> Engine.Req
		request = |_, x| Http({ method: "GET", url: "/x/${x.to_str()}", headers: [], body: "", timeout_ms: 0 })

		result : Asker, Engine.Res -> Try(Str, Str)
		result = |_, res| match res {
			Http({ status: 200, body, .. }) => Ok(body)
			Http({ status, .. }) => Err("s${status.to_str()}")
			Timeout => Err("timeout")
			Refused => Err("refused")
			_ => Err("other")
		}
	}

	asker : Asker
	asker = Asker

	## X's layer as text: each job (`w`, `a:answer`, `f:error`), then the
	## whole answer, `P` or `I` for pending or idle.
	show_x : Engine.Gathered(Str, Str) -> Str
	show_x = |{ jobs, all }| {
		job_text = |job| match job {
			Working => "w"
			Answered(a) => "a:${a}"
			Failed(e) => "f:${e}"
		}
		request = if (all.request == Pending) "P" else "I"
		answer = match all.answer {
			Unanswered => "un"
			Answered(answers) => "ok:${Str.join_with(answers, "+")}"
			Failed(e) => "fail:${e}"
		}
		"${Str.join_with(jobs.map(job_text), ",")}|${request}:${answer}"
	}

	## O's request for the item posted.
	plan_o : U64 -> List(Engine.Req)
	plan_o = |item| [Http({ method: "GET", url: "/o/${item.to_str()}", headers: [], body: "", timeout_ms: 0 })]

	## P's ports: a call and a subscription, each sent `p`.
	port_call : Port.Call(U64, Str)
	port_call = Port.call({ name: "test.roc-signals/fx-call" })

	port_feed : Port.Subscription(U64, Str)
	port_feed = Port.subscription({ name: "test.roc-signals/fx-feed", delivery: Every(8) })

	## P's requests for `p`.
	plan_p : U64 -> List(Engine.Req)
	plan_p = |p| if (p == 0) [] else [FxApp.port_call.request(p), FxApp.port_feed.subscribe(p)]

	## L's requests for query `q`.
	plan_l : U64 -> List(Engine.Req)
	plan_l = |q| {
		if q == 0 {
			[]
		} else if q % 4 == 1 {
			[Http({ method: "GET", url: "/l/${q.to_str()}", headers: [], body: "", timeout_ms: 5000 })]
		} else if q % 4 == 2 {
			[Interval(500)]
		} else if q % 4 == 3 {
			[Http({ method: "GET", url: "/l/${q.to_str()}", headers: [], body: "", timeout_ms: 0 }), Self, Self]
		} else {
			[]
		}
	}

	## L logs every result; a follow-up also bumps `q`, which supersedes
	## whatever L still owns (the second follow-up among it).
	react_l : S, U64, Engine.Res -> S
	react_l = |s, q, r| {
		s1 = FxApp.log_line(s, FxApp.describe(7, q, r))
		match r {
			Now => { ..s1, q: s1.q + 1 }
			_ => s1
		}
	}

	## R's requests for input `r`.
	plan_r : U64 -> List(Engine.Req)
	plan_r = |r| {
		if r == 0 {
			[]
		} else if r % 3 == 1 {
			[Http({ method: "GET", url: "/r/${r.to_str()}", headers: [], body: "", timeout_ms: 0 })]
		} else if r % 3 == 2 {
			[Http({ method: "GET", url: "/r/${r.to_str()}", headers: [], body: "", timeout_ms: 0 }), Timer(100)]
		} else {
			[Interval(700), FxApp.echo.request(r.to_u8_wrap())]
		}
	}

	## R's worker task: its input back, with a 100 ms deadline.
	echo : Worker.Task(U8, U8, Worker.Never)
	echo = Worker.task({ name: "test.roc-signals/fx/echo", run!: |b| Ok(b), deadline: Ms(100) })

	## The worker catalogue: R's echo task.
	workers : List(Engine.Registration)
	workers = [FxApp.echo.registration()]

	## How many timers one flood asks for.
	flood_size : U64
	flood_size = 70

	load0 : Load
	load0 = { input: 0, answer: "", faults: 0 }

	pending_r : Load, U64 -> Load
	pending_r = |l, r| { ..l, input: r }

	## An HTTP answer or a job's output replaces the answer, a timeout or a
	## lost job counts as a fault, a refusal is shown; anything else (a tick)
	## is an equal fold.
	resolve_r : Load, U64, Engine.Res -> Load
	resolve_r = |l, r, res| match res {
		Http({ status, body, .. }) => { ..l, answer: "${r.to_str()}:${status.to_str()}:${body}" }
		Work(_) =>
			match FxApp.echo.result(res) {
				Ok(b) => { ..l, answer: "${r.to_str()}:work:${Str.inspect([b])}" }
				Err(_) => { ..l, faults: l.faults + 1 }
			}
		Timeout | WorkLost(_) => { ..l, faults: l.faults + 1 }
		Refused => { ..l, answer: "${r.to_str()}:refused" }
		_ => l
	}

	show_r : Load -> Str
	show_r = |l| "${l.input.to_str()}|${l.answer}|${l.faults.to_str()}"

	react : S, U64, U64, Engine.Res -> S
	react = |s, k, c, r| {
		s1 = FxApp.log_line(s, FxApp.describe(k, c, r))
		match r {
			Now => if (c % 6 == 0) FxApp.toggle(s1, k) else s1
			_ => s1
		}
	}

	site : State(Ctx, S), U64 -> Elem(Ctx)
	site = |st, k| {
		label = "site ${k.to_str()}"
		Engine.element(
			"div",
			[],
			[
				Html.button("issue ${k.to_str()}", [], st.update(|s| FxApp.bump(s, k))),
				Html.button("toggle ${k.to_str()}", [], st.update(|s| FxApp.toggle(s, k))),
				Engine.when(
					st.val().map(|s| s.shown.get(k) ?? False),
					|| Engine.element(
						"p",
						[],
						[
							Engine.text(label),
							Engine.watch(
								st.val().map(|s| s.counts.get(k) ?? 0),
								FxApp.plan(k),
								st.on_result(|s, c, r| FxApp.react(s, k, c, r)),
							),
							Engine.state(
								0.U64,
								|hits| Engine.element(
									"span",
									[Engine.test_id("hits ${k.to_str()}")],
									[
										Engine.watch(
											st.val().map(|s| s.counts.get(k) ?? 0).lift(),
											|c| if (c == 0) [] else [Http({ method: "GET", url: "/h${k.to_str()}/${c.to_str()}", headers: [], body: "", timeout_ms: 0 })],
											hits.on_result(|h, _, _| h + 1),
										),
										Engine.text_v(hits.val().map(|h| h.to_str())),
									],
								),
							),
							Engine.watch(Engine.const(0.U64), |_| [Interval(1000)], st.on_result(|s, _, r| FxApp.log_line(s, FxApp.describe(k, 0, r)))),
						],
					),
					|| Engine.text(""),
				),
			],
		)
	}

	main_with : List(Bool) -> Elem(Root)
	main_with = |shown| Engine.state(
		{ counts: List.repeat(0, FxApp.nsites), shown, log: [], q: 0, r: 0, rshown: True, f: 0, n: 0, looping: False, p: 0, pshown: True, g: 0, gshown: True, out: Engine.outbox({}), posts: 0 },
		|st| Engine.element(
			"div",
			[],
			[
				Engine.watch(Engine.const(0.U64), |_| [Popstate], st.on_result(|s, _, r| FxApp.log_line(s, FxApp.describe(9, 0, r)))),
				FxApp.site(st, 0),
				FxApp.site(st, 1),
				FxApp.site(st, 2),
				Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
				# An SVG badge (namespace check in the browser): its class follows the log length.
				Engine.element(
					"svg",
					[Engine.attr("aria-label", "badge"), Engine.attr("width", "10"), Engine.attr("height", "10")],
					[
						Engine.element("circle", [Engine.attr("r", "4"), Engine.attr("cx", "5"), Engine.attr("cy", "5"), Engine.class_v(st.val().map(|s| if (s.log.is_empty()) "idle" else "busy"))], []),
					],
				),
				# F: each flood asks for 70 timers at once, far past the bound, so one
				# turn queues dozens of refusals (one follow-up chain deep each).
				Html.button("flood", [], st.update(|s| { ..s, f: s.f + 1 })),
				Engine.on_change(st.val().map(|s| s.f), |_| List.repeat(Timer(10), FxApp.flood_size), st.on_result(|s, f, r| FxApp.log_line(s, FxApp.describe(6, f, r)))),
				# A genuine follow-up loop, never armed by the fuzz model: once
				# "loop" is pressed, a refusal bumps `n`, which issues again, which
				# is refused again while the table is full.
				Html.button("loop", [], st.update(|s| { ..s, looping: True })),
				Engine.watch(
					st.val().map(|s| if (s.looping) s.n + 1 else 0),
					|n| if (n == 0) [] else [Http({ method: "GET", url: "/loop/${n.to_str()}", headers: [], body: "", timeout_ms: 0 })],
					st.on_result(
						|s, _, r| match r {
							Refused => { ..s, n: s.n + 1 }
							_ => s
						},
					),
				),
				Html.button("query", [], st.update(|s| { ..s, q: s.q + 1 })),
				Engine.latest(st.val().map(|s| s.q), FxApp.plan_l, st.on_result(|s, q, r| FxApp.react_l(s, q, r))),
				Html.button("rquery", [], st.update(|s| { ..s, r: s.r + 1 })),
				Html.button("toggle r", [], st.update(|s| { ..s, rshown: !s.rshown })),
				Engine.when(
					st.val().map(|s| s.rshown),
					|| Engine.resource(
						st.val().map(|s| s.r),
						{ init: FxApp.load0, pending: FxApp.pending_r, plan: FxApp.plan_r, resolve: FxApp.resolve_r },
						|l| Html.p_v(l.map(FxApp.show_r), [Engine.test_id("res")]),
					),
					|| Engine.text(""),
				),
				Html.button("pquery", [], st.update(|s| { ..s, p: s.p + 1 })),
				Html.button("toggle p", [], st.update(|s| { ..s, pshown: !s.pshown })),
				Engine.when(
					st.val().map(|s| s.pshown),
					|| Engine.latest(st.val().map(|s| s.p), FxApp.plan_p, st.on_result(|s, p, r| FxApp.log_line(s, FxApp.describe(10, p, r)))),
					|| Engine.text(""),
				),
				Html.button("gquery", [], st.update(|s| { ..s, g: s.g + 1 })),
				Html.button("toggle g", [], st.update(|s| { ..s, gshown: !s.gshown })),
				Engine.when(
					st.val().map(|s| s.gshown),
					|| Engine.gather(FxApp.asker, st.val().map(|s| FxApp.inputs_x(s.g)), |x| Html.p_v(x.map(FxApp.show_x), [Engine.test_id("gather")])),
					|| Engine.text(""),
				),
				Html.button("post", [], st.update(|s| { ..s, posts: s.posts + 1, out: s.out.post((s.posts + 1) // 2) })),
				Engine.on_post(st.val().map(|s| s.out), FxApp.plan_o, st.on_result(|s, item, r| FxApp.log_line(s, FxApp.describe(12, item, r)))),
			],
		),
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [], max_inflight: 8 }, |_| FxApp.main({})).with_workers(FxApp.workers).with_ports(FxApp.ports)

	## The ports P uses.
	ports : List(Engine.PortRegistration)
	ports = [FxApp.port_call.registration(), FxApp.port_feed.registration()]

	main : {} -> Elem(Root)
	main = |_| FxApp.main_with([True, True, True])
}
