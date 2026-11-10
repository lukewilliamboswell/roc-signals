import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

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
##   (the echo program, with a deadline), by `r % 3`. Its layer folds
##   answers and is shown as `input|answer|faults`.
FxApp := [].{
	S : { counts : List(U64), shown : List(Bool), log : List(Str), q : U64, r : U64, rshown : Bool }

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
			Work(out) => "${head}:work:${Str.inspect(out)}"
			WorkLost(fault) => "${head}:lost:${Str.inspect(fault)}"
			Timeout => "${head}:timeout"
			Network(m) => "${head}:net:${m}"
			Refused => "${head}:refused"
			Now => "${head}:self"
			Location(u) => "pop:${u}"
			_ => "${head}:other"
		}
	}

	log_line : S, Str -> S
	log_line = |{ counts, shown, log, q, r, rshown }, line| { counts, shown, log: log.append(line), q, r, rshown }

	bump : S, U64 -> S
	bump = |{ counts, shown, log, q, r, rshown }, k| { counts: counts.update(k, |c| c + 1) ?? counts, shown, log, q, r, rshown }

	toggle : S, U64 -> S
	toggle = |{ counts, shown, log, q, r, rshown }, k| { counts, shown: shown.update(k, |b| !b) ?? shown, log, q, r, rshown }

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
			[Interval(700), Work({ program: FxApp.echo_name, input: [r.to_u8_wrap()], deadline_ms: 100 })]
		}
	}

	## R's worker program: its input back.
	echo_name = "test.roc-signals/fx/echo"

	## The worker catalogue: R's echo program.
	workers : List(Engine.Registration)
	workers = [Engine.registration(FxApp.echo_name, |b| b)]

	load0 : Load
	load0 = { input: 0, answer: "", faults: 0 }

	begin_r : Load, U64 -> Load
	begin_r = |l, r| { ..l, input: r }

	## An HTTP answer or a job's output replaces the answer, a timeout or a
	## lost job counts as a fault, a refusal is shown; anything else (a tick)
	## is an equal fold.
	fold_r : Load, U64, Engine.Res -> Load
	fold_r = |l, r, res| match res {
		Http({ status, body, .. }) => { ..l, answer: "${r.to_str()}:${status.to_str()}:${body}" }
		Work(out) => { ..l, answer: "${r.to_str()}:work:${Str.inspect(out)}" }
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
		{ counts: List.repeat(0, FxApp.nsites), shown, log: [], q: 0, r: 0, rshown: True },
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
				Html.button("query", [], st.update(|s| { ..s, q: s.q + 1 })),
				Engine.latest(st.val().map(|s| s.q), FxApp.plan_l, st.on_result(|s, q, r| FxApp.react_l(s, q, r))),
				Html.button("rquery", [], st.update(|s| { ..s, r: s.r + 1 })),
				Html.button("toggle r", [], st.update(|s| { ..s, rshown: !s.rshown })),
				Engine.when(
					st.val().map(|s| s.rshown),
					|| Engine.resource(
						st.val().map(|s| s.r),
						{ init: FxApp.load0, begin: FxApp.begin_r, plan: FxApp.plan_r, fold: FxApp.fold_r },
						|l| Html.p_v(l.map(FxApp.show_r), [Engine.test_id("res")]),
					),
					|| Engine.text(""),
				),
			],
		),
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives on the fuzz platform.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [], max_inflight: 8 }, |_| FxApp.main({})).with_workers(FxApp.workers)

	main : {} -> Elem(Root)
	main = |_| FxApp.main_with([True, True, True])
}
