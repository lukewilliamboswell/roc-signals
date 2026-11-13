app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Engine
import pf.Dom
import pf.Scm
import pf.SpecRunner
import FxApp
import CurrentModel

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Core.App({}), dom : Dom.Model, steps : U64 }

start : Engine.Elem(Engine.Root) -> S
start = |view| {
	(a, c) = Core.take_cmds(Core.mount(view), [])
	{ eng: a, dom: Dom.apply(Dom.new({}), c), steps: 0 }
}

## Effect channel against a reference model (design.md disposal law).
## - generated: a byte program of issue / toggle (mount or dispose a site's
##   branch) / deliver a result for an arbitrary id (live, orphaned,
##   delivered, cancelled, refused or never issued) / popstate. After every
##   step the effect commands the engine emitted (decoded by Dom, in stream
##   order), the rendered log and per-site hits, the engine's effect counters
##   and its live ids must equal the model's. In-flight bound 5 (the
##   popstate subscription holds one; each shown site an interval).
## - Disposal stops a branch's interval (CANCEL) and reparents its G and H
##   requests: G results still append to the root log, H results are
##   skipped writes (their hits state is retired). Multiples of 6 make a
##   follow-up hide its own site mid-drain; its remaining follow-ups are
##   dropped (stale).
## - Supersession: L (a `latest` site, `k` 7) and R (a `resource`, `k` 8)
##   own only their current value's requests. A new value cancels every
##   request still in flight (CANCEL, `cancelled`), HTTP included, and drops
##   queued follow-ups and refusals (`stale`), before issuing again. L's first
##   follow-up bumps the query, superseding its second mid-drain. R's layer
##   is the model's fold of the answers it owns; hiding R disposes it: its
##   timer and interval stop, its HTTP request reparents to the `when` and
##   its answer is then a skipped write.
## - Work is scoped: R's worker job (with its interval, `r % 3 == 0`) is
##   cancelled by supersession and by disposal alike, never reparented, and
##   its output, a lost job or its timeout fold into R's layer.
## - Breadth is not depth: F (`k` 6) asks for 70 timers in one turn, so at
##   the bound of 5 one click queues 65 or more refusals. Each is an
##   independent follow-up one chain deep, so the call completes and every
##   refusal reaches the log; a budget that counted every follow-up turn of
##   the call would poison the instance here.
## - Every batch must leave the engine settled: a pass over every layer emits
##   nothing (`Core.settled`).
## - Ports: P (`k` 10, a `latest` site over `p` inside a `when`) issues a
##   port call and a port subscription for each nonzero `p`. A new `p`
##   supersedes both (CANCEL); hiding P keeps the call (it reparents and its
##   answer still reaches the log) and cancels the subscription. A message
##   leaves a subscription live; `Closed` or `Threw` retires it, and a
##   later message for it is stale.
## - Gathering: X (`k` 11, a `gather` over `g` inside a `when`) asks one
##   HTTP request per input. Each result, refusal included, settles the job
##   at the position its request had in the plan, whatever order the
##   results come in; the whole answer settles once no job is working, and
##   a new `g` supersedes every job. Hiding X reparents its requests, whose
##   answers are then skipped writes.
## - Posting: O (`k` 12, an `on_post` site) sends one request per post, an
##   equal item included, and never cancels; each result reaches the log
##   with the item it was posted with.

Kind : [G, H, Tick, Pop, Lh, Li, Rh, Rt, Ri, Rw, Ft, Pc, Ps, Xh, Oh]

## A live request: `at` is its position in the plan it was issued in
## (X's job).
Live : { id : U32, k : U64, c : U64, at : U64, kind : Kind, orphan : Bool }

## A queued follow-up: a refusal for G, H, an interval, L, R, F, P, X
## (at its job's position `at`) or O, or a Self (G's first or second, or
## L's).
Follow : { k : U64, c : U64, at : U64, what : [RefG, RefH, RefT, Self1, Self2, RefL, SelfL, RefR, RefF, RefP, RefX, RefO] }

## F's `k`.
k_f : U64
k_f = 6

## P's `k`.
k_p : U64
k_p = 10

## L's and R's `k`.
k_l : U64
k_l = 7

k_r : U64
k_r = 8

## X's and O's `k`.
k_x : U64
k_x = 11

k_o : U64
k_o = 12

## X's layer: each job, and the whole answer.
XJob : [W, A(Str), F(Str)]

XAll : { pending : Bool, answer : [Unanswered, Answers(List(Str)), Failure(Str)] }

M : {
	counts : List(U64),
	shown : List(Bool),
	hits : List(U64),
	log : List(Str),
	next : U32,
	live : List(Live),
	queue : List(Follow),
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	cancelled : U64,
	reparented : U64,
	skipped : U64,
	max : U64,
	fx : List(Dom.FxCmd),
	q : U64,
	r : U64,
	rshown : Bool,
	rl : FxApp.Load,
	f : U64,
	p : U64,
	pshown : Bool,
	g : U64,
	gshown : Bool,
	xjobs : List(XJob),
	xall : XAll,
	posts : U64,
}

model_new : U64 -> M
model_new = |max| {
	m0 = {
		counts: [0, 0, 0],
		shown: [True, True, True],
		hits: [0, 0, 0],
		log: [],
		next: 2,
		live: [{ id: 1, k: 9, c: 0, at: 0, kind: Pop, orphan: False }],
		queue: [],
		issued: 1,
		delivered: 0,
		stale: 0,
		refused: 0,
		cancelled: 0,
		reparented: 0,
		skipped: 0,
		max,
		fx: [Pop(1)],
		q: 0,
		r: 0,
		rshown: True,
		rl: FxApp.pending_r(FxApp.load0, 0),
		f: 0,
		p: 0,
		pshown: True,
		g: 0,
		gshown: True,
		xjobs: [],
		xall: { pending: False, answer: Answers([]) },
		posts: 0,
	}
	# each shown branch mounts its interval (counts are 0: no G/H)
	tick(tick(tick(m0, 0), 1), 2)
}

tick : M, U64 -> M
tick = |m, k| {
	id = m.next
	if m.live.len() >= m.max {
		# a refused interval: its reaction logs the refusal in a follow-up
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c: 0, at: 0, what: RefT }) }
	} else {
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c: 0, at: 0, kind: Tick, orphan: False }), fx: m.fx.append(Interval(id, 1000)) }
	}
}

## Admit (or refuse) one GET of kind G or H.
admit : M, U64, U64, Kind -> M
admit = |m, k, c, kind| {
	id = m.next
	if m.live.len() >= m.max {
		what = if (kind == G) RefG else RefH
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c, at: 0, what }) }
	} else {
		url = if (kind == G) FxApp.url_of(k, c) else "/h${k.to_str()}/${c.to_str()}"
		headers = if (kind == G) [("accept", "text/plain")] else []
		# G asks for 300 ms (odd c) or c * 250 s, capped at 600 s; H for none
		asked = if (c % 2 == 1) 300 else c * 250000
		timeout = if (kind == G) (if (asked > 600000) 600000 else asked.to_u32_wrap()) else 0
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c, at: 0, kind, orphan: False }), fx: m.fx.append(Http(id, "GET", url, headers, "", timeout, { cache: "default", credentials: "same-origin", progress_ms: 0 })) }
	}
}

## Site k's G and H issue for count c (tree order: G with its follow-ups,
## then H).
request : M, U64, U64 -> M
request = |m, k, c| {
	if c == 0 {
		m
	} else {
		m1 = admit(m, k, c, G)
		m2 = if c % 6 == 0 {
			{ ..m1, queue: m1.queue.concat([{ k, c, at: 0, what: Self1 }, { k, c, at: 0, what: Self2 }]) }
		} else if c % 3 == 0 {
			{ ..m1, queue: m1.queue.append({ k, c, at: 0, what: Self1 }) }
		} else {
			m1
		}
		admit(m2, k, c, H)
	}
}

## Admit (or refuse, queueing `refusal`) one awaited request of L, R, F,
## P or O: `cmd` is its effect command given the id.
admit_x : M, U64, U64, Kind, (U32 -> Dom.FxCmd), [RefL, RefR, RefF, RefP, RefX, RefO] -> M
admit_x = |m, k, c, kind, cmd, refusal| admit_at(m, { k, c, at: 0 }, kind, cmd, refusal)

## `admit_x` for a request at position `at` of its plan.
admit_at : M, { k : U64, c : U64, at : U64 }, Kind, (U32 -> Dom.FxCmd), [RefL, RefR, RefF, RefP, RefX, RefO] -> M
admit_at = |m, { k, c, at }, kind, cmd, refusal| {
	id = m.next
	if m.live.len() >= m.max {
		what = match refusal {
			RefL => RefL
			RefR => RefR
			RefF => RefF
			RefP => RefP
			RefX => RefX
			RefO => RefO
		}
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c, at, what }) }
	} else {
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c, at, kind, orphan: False }), fx: m.fx.append(cmd(id)) }
	}
}

## Site `k` gives up what it owns before issuing for a new value: every
## live request it still owns is cancelled in issue order, and its queued
## follow-ups are dropped as stale.
supersede : M, U64 -> M
supersede = |m, k| {
	var $m = m
	for l in m.live {
		if l.k == k and !l.orphan {
			$m = { ..$m, fx: $m.fx.append(Cancel(l.id)), cancelled: $m.cancelled + 1 }
		}
	}
	purged = $m.queue.count_if(|f| f.k == k)
	{
		..$m,
		live: $m.live.keep_if(|l| !(l.k == k and !l.orphan)),
		queue: $m.queue.keep_if(|f| f.k != k),
		stale: $m.stale + purged,
	}
}

## L's requests for query `q` (FxApp.plan_l), in plan order.
issue_l : M, U64 -> M
issue_l = |m, q| {
	url = "/l/${q.to_str()}"
	if q == 0 {
		m
	} else if q % 4 == 1 {
		admit_x(m, k_l, q, Lh, |id| Http(id, "GET", url, [], "", 5000, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefL)
	} else if q % 4 == 2 {
		admit_x(m, k_l, q, Li, |id| Interval(id, 500), RefL)
	} else if q % 4 == 3 {
		m1 = admit_x(m, k_l, q, Lh, |id| Http(id, "GET", url, [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefL)
		{ ..m1, queue: m1.queue.concat([{ k: k_l, c: q, at: 1, what: SelfL }, { k: k_l, c: q, at: 2, what: SelfL }]) }
	} else {
		m
	}
}

## R's requests for input `r` (FxApp.plan_r), in plan order.
issue_r : M, U64 -> M
issue_r = |m, r| {
	url = "/r/${r.to_str()}"
	if r == 0 {
		m
	} else if r % 3 == 1 {
		admit_x(m, k_r, r, Rh, |id| Http(id, "GET", url, [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefR)
	} else if r % 3 == 2 {
		m1 = admit_x(m, k_r, r, Rh, |id| Http(id, "GET", url, [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefR)
		admit_x(m1, k_r, r, Rt, |id| Timer(id, 100), RefR)
	} else {
		m1 = admit_x(m, k_r, r, Ri, |id| Interval(id, 700), RefR)
		# The echo task's input, a `U8`, is one byte on the wire; its 100 ms
		# timeout and `Stop` cancel policy travel with it.
		admit_x(m1, k_r, r, Rw, |id| Work(id, { task: FxApp.echo.name(), input: [r.to_u8_wrap()], files: [], timeout_ms: 100, cancel: 1, prepared: Unprepared }), RefR)
	}
}

## P's requests for `p` (FxApp.plan_p): a call and a subscription, each
## sent `p` as PortJson writes a `U64`, a string of its digits.
issue_p : M, U64 -> M
issue_p = |m, p| {
	if p == 0 {
		m
	} else {
		msg = { json: "\"${p.to_str()}\"", blobs: [], files: [] }
		m1 = admit_x(m, k_p, p, Pc, |id| PortCall(id, "test.roc-signals/fx-call", msg, 0), RefP)
		admit_x(m1, k_p, p, Ps, |id| PortListen(id, "test.roc-signals/fx-feed", msg), RefP)
	}
}

## A click on "pquery": a shown P supersedes and issues for the next `p`.
model_pquery : M -> M
model_pquery = |m| {
	p = m.p + 1
	if (m.pshown) drain(issue_p(supersede({ ..m, p }, k_p), p)) else { ..m, p }
}

## A click on "toggle p": hiding disposes P (its call reparents, its
## subscription is cancelled, its queued refusals are dropped); showing
## mounts it afresh for the current `p`.
model_toggle_p : M -> M
model_toggle_p = |m| {
	if m.pshown {
		var $m = { ..m, pshown: False }
		for l in m.live {
			if l.k == k_p and !l.orphan {
				if l.kind == Pc {
					$m = { ..$m, reparented: $m.reparented + 1 }
				} else {
					$m = { ..$m, fx: $m.fx.append(Cancel(l.id)), cancelled: $m.cancelled + 1 }
				}
			}
		}
		purged = $m.queue.count_if(|f| f.k == k_p)
		{
			..$m,
			live: $m.live.keep_if(|l| !(l.k == k_p and !l.orphan and l.kind == Ps)).map(|l| if (l.k == k_p) { ..l, orphan: True } else l),
			queue: $m.queue.keep_if(|f| f.k != k_p),
			stale: $m.stale + purged,
		}
	} else {
		drain(issue_p({ ..m, pshown: True }, m.p))
	}
}

## X begins a question for `inputs`: an empty one is answered at once,
## otherwise every job works and the whole answer is pending, keeping the
## answer it had.
x_begin : M, List(U64) -> M
x_begin = |m, inputs|
	if inputs.is_empty() {
		{ ..m, xjobs: [], xall: { pending: False, answer: Answers([]) } }
	} else {
		{ ..m, xjobs: List.repeat(W, inputs.len()), xall: { ..m.xall, pending: True } }
	}

## X's requests for `g`, one per input in plan order.
issue_x : M, U64 -> M
issue_x = |m, g| {
	var $m = m
	var $at = 0
	for input in FxApp.inputs_x(g) {
		$m = admit_at($m, { k: k_x, c: g, at: $at }, Xh, |id| Http(id, "GET", "/x/${input.to_str()}", [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefX)
		$at = $at + 1
	}
	$m
}

## A result settles X's job at `at`; once no job works, the whole answer
## is every answer in input order, or the first failure.
x_settle : M, U64, Engine.Result -> M
x_settle = |m, at, res| {
	job = match FxApp.Asker.result(FxApp.asker, res) {
		Ok(a) => A(a)
		Err(e) => F(e)
	}
	jobs = m.xjobs.set(at, job) ?? crash "model: X has no job ${at.to_str()}"
	if jobs.contains(W) {
		{ ..m, xjobs: jobs }
	} else {
		failures = jobs.keep_oks(
			|j| match j {
				F(e) => Ok(e)
				_ => Err(NotFailed)
			},
		)
		answers = jobs.keep_oks(
			|j| match j {
				A(a) => Ok(a)
				_ => Err(NotAnswered)
			},
		)
		answer = match failures {
			[first, ..] => Failure(first)
			[] => Answers(answers)
		}
		{ ..m, xjobs: jobs, xall: { pending: False, answer } }
	}
}

## X's layer as the page shows it.
x_text : M -> Str
x_text = |m| {
	jobs = m.xjobs.map(
		|j| match j {
			W => "w"
			A(a) => "a:${a}"
			F(e) => "f:${e}"
		},
	)
	answer = match m.xall.answer {
		Unanswered => "un"
		Answers(answers) => "ok:${Str.join_with(answers, "+")}"
		Failure(e) => "fail:${e}"
	}
	"${Str.join_with(jobs, ",")}|${if (m.xall.pending) "P" else "I"}:${answer}"
}

## A click on "gquery": a shown X supersedes, begins the new question and
## issues its jobs.
model_gquery : M -> M
model_gquery = |m| {
	g = m.g + 1
	if m.gshown {
		inputs = FxApp.inputs_x(g)
		drain(issue_x(x_begin(supersede({ ..m, g }, k_x), inputs), g))
	} else {
		{ ..m, g }
	}
}

## A click on "toggle g": hiding disposes X (its requests reparent, its
## queued refusals are dropped); showing mounts it afresh.
model_toggle_g : M -> M
model_toggle_g = |m| {
	if m.gshown {
		var $m = { ..m, gshown: False }
		for l in m.live {
			if l.k == k_x and !l.orphan {
				$m = { ..$m, reparented: $m.reparented + 1 }
			}
		}
		purged = $m.queue.count_if(|f| f.k == k_x)
		{
			..$m,
			live: $m.live.map(|l| if (l.k == k_x) { ..l, orphan: True } else l),
			queue: $m.queue.keep_if(|f| f.k != k_x),
			stale: $m.stale + purged,
		}
	} else {
		fresh = { ..m, gshown: True, xjobs: [], xall: { pending: False, answer: Unanswered } }
		drain(issue_x(x_begin(fresh, FxApp.inputs_x(m.g)), m.g))
	}
}

## A click on "post": O sends one request for the item posted, never
## cancelling an earlier one.
model_post : M -> M
model_post = |m| {
	posts = m.posts + 1
	item = posts // 2
	drain(admit_x({ ..m, posts }, k_o, item, Oh, |id| Http(id, "GET", "/o/${item.to_str()}?q=${m.q.to_str()}", [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 0 }), RefO))
}

## The query changes (a click or L's own follow-up): L supersedes, then
## issues for the new value.
bump_q : M -> M
bump_q = |m| {
	q = m.q + 1
	issue_l(supersede({ ..m, q }, k_l), q)
}

## Run queued follow-ups in order (after the turn).
drain : M -> M
drain = |m0| {
	var $m = m0
	while !$m.queue.is_empty() {
		f = $m.queue.first() ?? crash "queue"
		m = { ..$m, queue: $m.queue.drop_first(1) }
		$m = match f.what {
			RefG => { ..m, log: m.log.append(FxApp.describe(f.k, f.c, Refused)), delivered: m.delivered + 1 }
			RefH => { ..m, hits: m.hits.update(f.k, |h| h + 1) ?? m.hits, delivered: m.delivered + 1 }
			RefT => { ..m, log: m.log.append(FxApp.describe(f.k, 0, Refused)), delivered: m.delivered + 1 }
			Self1 | Self2 => {
				m1 = { ..m, log: m.log.append(FxApp.describe(f.k, f.c, Now)), delivered: m.delivered + 1 }
				if (f.c % 6 == 0) hide(m1, f.k) else m1
			}
			RefL => { ..m, log: m.log.append(FxApp.describe(k_l, f.c, Refused)), delivered: m.delivered + 1 }
			SelfL => bump_q({ ..m, log: m.log.append(FxApp.describe(k_l, f.c, Now)), delivered: m.delivered + 1 })
			RefR => { ..m, rl: FxApp.resolve_r(m.rl, f.c, Refused), delivered: m.delivered + 1 }
			RefF => { ..m, log: m.log.append(FxApp.describe(k_f, f.c, Refused)), delivered: m.delivered + 1 }
			RefP => { ..m, log: m.log.append(FxApp.describe(k_p, f.c, Refused)), delivered: m.delivered + 1 }
			RefX => x_settle({ ..m, delivered: m.delivered + 1 }, f.at, Refused)
			RefO => { ..m, log: m.log.append(FxApp.describe(k_o, f.c, Refused)), delivered: m.delivered + 1 }
		}
	}
	$m
}

## Dispose site k's branch: stop its interval, reparent G/H, drop its
## queued follow-ups.
hide : M, U64 -> M
hide = |m, k| {
	var $m = { ..m, shown: m.shown.set(k, False) ?? m.shown }
	for l in m.live {
		if l.k == k and !l.orphan {
			if l.kind == Tick {
				$m = { ..$m, fx: $m.fx.append(Cancel(l.id)), cancelled: $m.cancelled + 1 }
			} else {
				$m = { ..$m, reparented: $m.reparented + 1 }
			}
		}
	}
	purged = $m.queue.count_if(|q| q.k == k)
	{
		..$m,
		live: $m.live.keep_if(|l| !(l.k == k and l.kind == Tick)).map(|l| if (l.k == k) { ..l, orphan: True } else l),
		queue: $m.queue.keep_if(|q| q.k != k),
		stale: $m.stale + purged,
	}
}

model_issue : M, U64 -> M
model_issue = |m, k| {
	c = (m.counts.get(k) ?? 0) + 1
	m1 = { ..m, counts: m.counts.set(k, c) ?? m.counts }
	if (m.shown.get(k) ?? False) drain(request(m1, k, c)) else m1
}

model_toggle : M, U64 -> M
model_toggle = |m, k| {
	if m.shown.get(k) ?? False {
		hide(m, k)
	} else {
		m1 = { ..m, shown: m.shown.set(k, True) ?? m.shown, hits: m.hits.set(k, 0) ?? m.hits }
		# mount order: G (+ follow-ups), H, then the interval
		drain(tick(request(m1, k, m.counts.get(k) ?? 0), k))
	}
}

## A click on "flood": F asks for its timers, in plan order.
model_flood : M -> M
model_flood = |m0| {
	f = m0.f + 1
	var $m = { ..m0, f }
	var $i = 0.U64
	while $i < FxApp.flood_size {
		$m = admit_x($m, k_f, f, Ft, |id| Timer(id, 10), RefF)
		$i = $i + 1
	}
	drain($m)
}

## A click on "query": L supersedes and issues for the next query.
model_query : M -> M
model_query = |m| drain(bump_q(m))

## A click on "rquery": a shown R supersedes, begins its layer for the new
## input and issues; a hidden R only sees the counter move.
model_rquery : M -> M
model_rquery = |m| {
	r = m.r + 1
	if m.rshown {
		m1 = supersede({ ..m, r }, k_r)
		drain(issue_r({ ..m1, rl: FxApp.pending_r(m1.rl, r) }, r))
	} else {
		{ ..m, r }
	}
}

## A click on "toggle r": hiding disposes R (its timer and interval stop,
## its HTTP request reparents, its queued follow-ups are dropped); showing
## mounts it afresh.
model_toggle_r : M -> M
model_toggle_r = |m| {
	if m.rshown {
		var $m = { ..m, rshown: False }
		for l in m.live {
			if l.k == k_r and !l.orphan {
				if l.kind == Rh {
					$m = { ..$m, reparented: $m.reparented + 1 }
				} else {
					$m = { ..$m, fx: $m.fx.append(Cancel(l.id)), cancelled: $m.cancelled + 1 }
				}
			}
		}
		purged = $m.queue.count_if(|f| f.k == k_r)
		{
			..$m,
			live: $m.live.keep_if(|l| !(l.k == k_r and !l.orphan and l.kind != Rh)).map(|l| if (l.k == k_r) { ..l, orphan: True } else l),
			queue: $m.queue.keep_if(|f| f.k != k_r),
			stale: $m.stale + purged,
		}
	} else {
		drain(issue_r({ ..m, rshown: True, rl: FxApp.pending_r(FxApp.load0, m.r) }, m.r))
	}
}

model_deliver : M, U32, Engine.Result -> M
model_deliver = |m, id, res| {
	match m.live.find_first(|l| l.id == id) {
		Ok(l) => {
			ended = match res {
				PortFailed(Closed) | PortFailed(Threw(_)) => Bool.True
				_ => Bool.False
			}
			# A terminal port result retires whatever subscription it reaches
			# (only a port's ever receives one from a well-behaved host).
			sub = (l.kind == Tick or l.kind == Pop or l.kind == Li or l.kind == Ri or l.kind == Ps) and !ended
			live = if (sub) m.live else m.live.keep_if(|x| x.id != id)
			m1 = { ..m, live, delivered: m.delivered + 1 }
			match l.kind {
				H => if (l.orphan) { ..m1, skipped: m1.skipped + 1 } else { ..m1, hits: m1.hits.update(l.k, |h| h + 1) ?? m1.hits }
				Rh | Rt | Ri | Rw => if (l.orphan) { ..m1, skipped: m1.skipped + 1 } else { ..m1, rl: FxApp.resolve_r(m1.rl, l.c, res) }
				Xh => if (l.orphan) { ..m1, skipped: m1.skipped + 1 } else x_settle(m1, l.at, res)
				_ => { ..m1, log: m1.log.append(FxApp.describe(l.k, l.c, res)) }
			}
		}
		Err(_) => { ..m, stale: m.stale + 1 }
	}
}

E : { s : S, fx : List(Dom.FxCmd) }

## Apply one batch to the oracle. The engine's per-opcode work counters must
## have moved by exactly the commands the oracle decoded from it.
apply! : S, Core.App({}), List(U8) => E
apply! = |s, a, c| {
	(d2, ops, fx) = Dom.apply_fx(s.dom, c)
	before = Core.work_counters(s.eng)
	after = Core.work_counters(a)
	var $op = 1.U64
	while $op <= 18 {
		moved = (after.get($op) ?? 0) - (before.get($op) ?? 0)
		seen = ops.count_if(|o| o.to_u64() == $op)
		if moved != seen {
			crash "work counter for ${Dom.op_name($op.to_u8_wrap())} moved by ${moved.to_str()}, the batch holds ${seen.to_str()}"
		}
		$op = $op + 1
	}
	settle!(a, d2)
	{ s: { eng: a, dom: d2, steps: s.steps + 1 }, fx }
}

## The settle check: a pass over every layer of the engine (on a discarded
## copy) must emit nothing, or the batch left a reader stale.
settle! : Core.App({}), Dom.Model => {}
settle! = |a, dom|
	match Core.settled(a) {
		Ok(_) => {}
		Err({ cmds, note }) => crash "a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(dom, cmds).1)} ${note}"
	}

click! : S, Str => E
click! = |s, name| {
	i = SpecRunner.find(s.dom, Role({ role: "button", name })) ?? crash "no button ${name}"
	target = Dom.target(s.dom, i, "click", Bool.True) ?? crash "no handler"
	(a, c) = Core.take_cmds(Core.event(s.eng, target.node, target.handler, ""), [])
	apply!(s, a, c)
}

## Results go through the wire: an independent encoder here, the engine's
## decoder there (the round trip is part of what the model checks).
deliver! : S, U32, Engine.Result => E
deliver! = |s, id, res| {
	(a, c) = Core.take_cmds(Core.result(s.eng, id, Core.decode_res(encode_res(res))), [])
	apply!(s, a, c)
}

le32 : List(U8), U64 -> List(U8)
le32 = |b, v| b.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

wstr : List(U8), Str -> List(U8)
wstr = |b, s| le32(b, s.count_utf8_bytes()).concat(Str.to_utf8(s))

encode_res : Engine.Result -> List(U8)
encode_res = |res| match res {
	Http({ status, headers, body }) => {
		var $b = le32([1, status.to_u8_wrap(), status.shr_zf_wrap(8).to_u8_wrap()], headers.len())
		for (n, v) in headers {
			$b = wstr(wstr($b, n), v)
		}
		$b.concat(Str.to_utf8(body))
	}
	Network(m) => [2].concat(Str.to_utf8(m))
	Timeout => [7]
	Value(v) => [3].concat(Str.to_utf8(v))
	Missing => [4]
	Fired(at_ms) => SpecRunner.put_u64([5], at_ms.to_u64_wrap())
	Location(u) => [6].concat(Str.to_utf8(u))
	Work({ output, files: [] }) => SpecRunner.encode_answer(output)
	WorkLost(AppCrash) => [11, 4]
	PortAnswer({ json, .. }) => le32(le32(wstr([14], json), 0), 0)
	PortFailed(Threw(t)) => [15, 1].concat(Str.to_utf8(t))
	PortFailed(TooLarge) => [15, 2]
	PortFailed(Closed) => [15, 3]
	_ => crash "not a host result"
}

show_fx : List(Dom.FxCmd) -> Str
show_fx = |l| Str.inspect(l)

check! : Str, E, M => {}
check! = |what, e, m| {
	if e.fx != m.fx {
		crash "${what}: effect commands ${show_fx(e.fx)}, model ${show_fx(m.fx)}"
	}
	log = Dom.text_of(e.s.dom, SpecRunner.find(e.s.dom, TestId("log")) ?? crash "no log")
	want = Str.join_with(m.log, "|")
	if log != want {
		crash "${what}: log \"${log}\", model \"${want}\""
	}
	st = Core.fx_stats(e.s.eng)
	got = [st.issued, st.delivered, st.stale, st.refused, st.cancelled, st.live, st.reparented, st.skipped]
	exp = [m.issued, m.delivered, m.stale, m.refused, m.cancelled, m.live.len(), m.reparented, m.skipped]
	if got != exp {
		crash "${what}: counters ${Str.inspect(got)} (issued delivered stale refused cancelled live reparented skipped), model ${Str.inspect(exp)}"
	}
	var $k = 0.U64
	while $k < 3 {
		shown_hits = match SpecRunner.find(e.s.dom, TestId("hits ${$k.to_str()}")) {
			Ok(i) => Ok(Dom.text_of(e.s.dom, i))
			Err(_) => Err(Hidden)
		}
		want_hits = if (m.shown.get($k) ?? False) Ok((m.hits.get($k) ?? 0).to_str()) else Err(Hidden)
		if shown_hits != want_hits {
			crash "${what}: site ${$k.to_str()} hits ${Str.inspect(shown_hits)}, model ${Str.inspect(want_hits)}"
		}
		$k = $k + 1
	}
	shown_res = match SpecRunner.find(e.s.dom, TestId("res")) {
		Ok(i) => Ok(Dom.text_of(e.s.dom, i))
		Err(_) => Err(Hidden)
	}
	want_res = if (m.rshown) Ok(FxApp.show_r(m.rl)) else Err(Hidden)
	if shown_res != want_res {
		crash "${what}: resource ${Str.inspect(shown_res)}, model ${Str.inspect(want_res)}"
	}
	shown_x = match SpecRunner.find(e.s.dom, TestId("gather")) {
		Ok(i) => Ok(Dom.text_of(e.s.dom, i))
		Err(_) => Err(Hidden)
	}
	want_x = if (m.gshown) Ok(x_text(m)) else Err(Hidden)
	if shown_x != want_x {
		crash "${what}: gather ${Str.inspect(shown_x)}, model ${Str.inspect(want_x)}"
	}
	# The FX and CANCEL work counters are the model's issued and cancelled
	# requests: every admitted request is one FX, every stop one CANCEL.
	w = Core.work_counters(e.s.eng)
	if (w.get(13) ?? 0) != m.issued or (w.get(14) ?? 0) != m.cancelled {
		crash "${what}: FX/CANCEL work counters ${(w.get(13) ?? 0).to_str()}/${(w.get(14) ?? 0).to_str()}, model issued/cancelled ${m.issued.to_str()}/${m.cancelled.to_str()}"
	}
	# The work record carries the effect counters too (design.md, Appendix B,
	# indices 32-39), so both spec runners can read them.
	recorded = [m.issued, m.delivered, m.stale, m.refused, m.cancelled, m.reparented, m.skipped, m.live.len()]
	if w.drop_first(32).take_first(8) != recorded {
		crash "${what}: work-record effect counters ${Str.inspect(w.drop_first(32).take_first(8))} (issued delivered stale refused cancelled reparented skipped live), model ${Str.inspect(recorded)}"
	}
	# The app sends no port commands (index 40).
	if w.get(40) != Ok(0) {
		crash "${what}: port commands sent ${Str.inspect(w.get(40))}, model 0"
	}
	if Core.fx_live(e.s.eng) != m.live.map(|l| l.id) {
		crash "${what}: live ids ${Str.inspect(Core.fx_live(e.s.eng))}, model ${Str.inspect(m.live.map(|l| l.id))}"
	}
}

run_program! : List(U8) => {}
run_program! = |prog| {
	max = 5
	# The app's view with its worker catalogue, mounted as a host mounts it.
	program = Engine.program_boot({ storage_keys: [], max_inflight: max }, |_| FxApp.main({})).with_workers(FxApp.workers).with_ports(FxApp.ports)
	(a0, c0, _) = (Core.driver(program).init)([])
	(d0, _, fx0) = Dom.apply_fx(Dom.new({}), c0)
	var $s = { eng: a0, dom: d0, steps: 0 }
	var $m = model_new(max)
	settle!(a0, d0)
	check!("mount", { s: $s, fx: fx0 }, $m)
	var $i = 0.U64
	while $i + 1 < prog.len() {
		op = (prog.get($i) ?? 0) % 13
		arg = prog.get($i + 1) ?? 0
		k = arg.to_u64() % 3
		m0 = { ..$m, fx: [] }
		(e, m2, what) = if op == 0 {
			(click!($s, "issue ${k.to_str()}"), model_issue(m0, k), "issue ${k.to_str()}")
		} else if op == 1 {
			(click!($s, "toggle ${k.to_str()}"), model_toggle(m0, k), "toggle ${k.to_str()}")
		} else if op == 2 {
			id = (arg.to_u32() % $m.next) + 1
			body = "b${arg.to_str()}"
			res = if arg % 3 == 0 {
				Http({ status: 200, headers: [], body })
			} else if arg % 3 == 1 {
				Http({ status: 201, headers: [("x-a", "1"), ("x-b", "v${arg.to_str()}")], body })
			} else {
				Timeout
			}
			(deliver!($s, id, res), model_deliver(m0, id, res), "deliver ${id.to_str()}")
		} else if op == 3 {
			url = "/u${arg.to_str()}"
			(deliver!($s, 1, Location(url)), model_deliver(m0, 1, Location(url)), "popstate ${url}")
		} else if op == 4 {
			(click!($s, "query"), model_query(m0), "query")
		} else if op == 5 {
			(click!($s, "rquery"), model_rquery(m0), "rquery")
		} else if op == 6 {
			(click!($s, "toggle r"), model_toggle_r(m0), "toggle r")
		} else if op == 8 {
			(click!($s, "flood"), model_flood(m0), "flood")
		} else if op == 9 {
			if (arg % 2 == 0) (click!($s, "pquery"), model_pquery(m0), "pquery") else (click!($s, "toggle p"), model_toggle_p(m0), "toggle p")
		} else if op == 11 {
			if (arg % 2 == 0) (click!($s, "gquery"), model_gquery(m0), "gquery") else (click!($s, "toggle g"), model_toggle_g(m0), "toggle g")
		} else if op == 12 {
			(click!($s, "post"), model_post(m0), "post")
		} else if op == 10 {
			# A port's message, its close or its failure, for an arbitrary id.
			id = (arg.to_u32() % $m.next) + 1
			res = if (arg % 3 == 0) PortAnswer({ json: "\"m${arg.to_str()}\"", blobs: [], files: [] }) else if (arg % 3 == 1) PortFailed(Closed) else PortFailed(Threw("t${arg.to_str()}"))
			(deliver!($s, id, res), model_deliver(m0, id, res), "port result ${id.to_str()}")
		} else {
			# A tick, a job's answer (the echo task's answer `arg`: the byte
			# and its `Ok` flag) or a lost job for an arbitrary id: a tick is an
			# equal fold for R and "other" for logs.
			id = (arg.to_u32() % $m.next) + 1
			res = if (arg % 4 == 1) Work({ output: [arg, 0], files: [] }) else if (arg % 4 == 3) WorkLost(AppCrash) else Fired(arg.to_i64())
			(deliver!($s, id, res), model_deliver(m0, id, res), "result ${id.to_str()}")
		}
		check!("step ${($i // 2).to_str()} ${what}", e, m2)
		$s = e.s
		$m = m2
		$i = $i + 2
	}
}

## Media subscriptions share cancellation, supersession, refusal and stale
## result rules with every other subscription. This independent model runs
## a generated history with a cap of one and a two-request plan, so each
## subscription generation also exercises a typed refusal.
MediaChoice : [NoQuery, Dark, Motion]

MediaState : { query : MediaChoice, shown : Bool, answers : Str }

MediaModel : { query : MediaChoice, shown : Bool, next : U32, current : U32, answers : Str, issued : U64, delivered : U64, stale : U64, refused : U64, cancelled : U64 }

MediaStep : [Choose(MediaChoice), Toggle, Answer(U32, Bool)]

media_query : MediaChoice -> Str
media_query = |query| match query {
	Dark => "(prefers-color-scheme: dark)"
	Motion => "(prefers-reduced-motion: reduce)"
	NoQuery => crash "media_query: no query was selected"
}

media_transition : MediaModel, MediaStep -> { model : MediaModel, fx : List(Dom.FxCmd) }
media_transition = |before, step| match step {
	Answer(id, matches) => {
		model = if id == before.current and id != 0 {
			{ ..before, delivered: before.delivered + 1, answers: "${before.answers}${if (matches) "T" else "F"}" }
		} else {
			{ ..before, stale: before.stale + 1 }
		}
		{ model, fx: [] }
	}
	_ => {
		changed = match step {
			Choose(query) => { ..before, query }
			Toggle => { ..before, shown: !before.shown }
			Answer(_, _) => before
		}
		if changed.query == before.query and changed.shown == before.shown {
			return { model: before, fx: [] }
		}
		var $model = changed
		var $fx = []
		if before.current != 0 {
			$model = { ..$model, current: 0, cancelled: $model.cancelled + 1 }
			$fx = $fx.append(Cancel(before.current))
		}
		if changed.shown and changed.query != NoQuery {
			id = $model.next
			$model = { ..$model, current: id, next: id + 2, issued: $model.issued + 1, refused: $model.refused + 1, delivered: $model.delivered + 1, answers: "${$model.answers}R" }
			$fx = $fx.append(MediaSub(id, media_query(changed.query)))
		}
		{ model: $model, fx: $fx }
	}
}

media_program : {} -> Engine.Program
media_program = |_args| {
	initial : MediaState
	initial = { query: NoQuery, shown: True, answers: "" }
	Engine.program_boot(
		{ media: [media_query(Dark), media_query(Motion)], max_inflight: 1 },
		|_boot| Engine.state(
			initial,
			|state| Engine.element(
				"section",
				[],
				[
					Engine.element("button", [Engine.attr("aria-label", "media one"), Engine.on_click(state.update(|value| { ..value, query: Dark }))], []),
					Engine.element("button", [Engine.attr("aria-label", "media two"), Engine.on_click(state.update(|value| { ..value, query: Motion }))], []),
					Engine.element("button", [Engine.attr("aria-label", "media none"), Engine.on_click(state.update(|value| { ..value, query: NoQuery }))], []),
					Engine.element("button", [Engine.attr("aria-label", "media toggle"), Engine.on_click(state.update(|value| { ..value, shown: !value.shown }))], []),
					Engine.element("p", [Engine.test_id("media answers")], [Engine.text_s(state.signal().map(|value| value.answers))]),
					Engine.when(
						state.signal().map(|value| value.shown),
						|| Engine.watch_latest(
							state.signal().map(|value| value.query),
							|query| if (query == NoQuery) [] else [Engine.media_changes(media_query(query)), Engine.media_changes(media_query(query))],
							state.on_result(
								|value, _query, result| {
									..value,
									answers: "${value.answers}${
										match result {
											Ok(True) => "T"
											Ok(False) => "F"
											Err(Refused) => "R"
										}
									}",
								},
							),
						),
						|| Engine.text(""),
					),
				],
			),
		),
	)
}

## Compare commands, counters, live ids and rendered answers after every
## transition. The model never reads the engine's state or live request data.
media_apply : { eng : Core.App({}), dom : Dom.Model, model : MediaModel }, MediaStep -> { eng : Core.App({}), dom : Dom.Model, model : MediaModel }
media_apply = |held, step| {
	{ eng, dom, model } = held
	expected = media_transition(model, step)
	changed = match step {
		Answer(id, matches) => Core.result(eng, id, Core.decode_res([22, if (matches) 1 else 0]))
		_ => {
			name = match step {
				Choose(NoQuery) => "media none"
				Choose(Dark) => "media one"
				Choose(_) => "media two"
				Toggle => "media toggle"
				Answer(_, _) => crash "answer already handled"
			}
			found = SpecRunner.find(dom, Role({ role: "button", name })) ?? crash "missing media control"
			target = Dom.target(dom, found, "click", True) ?? crash "missing media handler"
			Core.event(eng, target.node, target.handler, "")
		}
	}
	(next, commands) = Core.take_cmds(changed, [])
	(drawn, _, effects) = Dom.apply_fx(dom, commands)
	stats = Core.fx_stats(next)
	want = expected.model
	actual_counts = [stats.issued, stats.delivered, stats.stale, stats.refused, stats.cancelled, stats.reparented, stats.skipped, stats.live]
	expected_counts = [want.issued, want.delivered, want.stale, want.refused, want.cancelled, 0, 0, if (want.current == 0) 0 else 1]
	if effects != expected.fx or actual_counts != expected_counts {
		crash "media commands/counters disagree with model: ${Str.inspect(effects)} vs ${Str.inspect(expected.fx)}; ${Str.inspect(actual_counts)} vs ${Str.inspect(expected_counts)}"
	}
	live = if (want.current == 0) [] else [want.current]
	if Core.fx_live(next) != live {
		crash "media live ids disagree with model"
	}
	answers = Dom.text_of(drawn, SpecRunner.find(drawn, TestId("media answers")) ?? crash "missing media answers")
	if answers != want.answers {
		crash "media answer history disagrees with model"
	}
	if Core.settled(next).is_err() {
		crash "media result left a reader stale"
	}
	{ eng: next, dom: drawn, model: want }
}

run_media : List(U8) -> {}
run_media = |program| {
	driver = Core.driver(media_program({}))
	(initial, commands, _) = (driver.init)([])
	var $held = { eng: initial, dom: Dom.apply(Dom.new({}), commands), model: { query: NoQuery, shown: True, next: 1.U32, current: 0.U32, answers: "", issued: 0.U64, delivered: 0.U64, stale: 0.U64, refused: 0.U64, cancelled: 0.U64 } }
	var $at = 0.U64
	while $at + 1 < program.len() {
		op = (program.get($at) ?? 0) % 6
		arg = program.get($at + 1) ?? 0
		step = match op {
			0 => Choose(Dark)
			1 => Choose(Motion)
			2 => Choose(NoQuery)
			3 => Toggle
			4 => Answer((arg.to_u32() % $held.model.next) + 1, arg % 2 == 0)
			_ => Answer(if ($held.model.current == 0) $held.model.next - 1 else $held.model.current, arg % 2 == 0)
		}
		$held = media_apply($held, step)
		$at = $at + 2
	}
	if $held.model.shown {
		$held = media_apply($held, Toggle)
	}
	if !Core.fx_live($held.eng).is_empty() {
		crash "disposed media scope retained a subscription"
	}
	{}
}

## One history repeats reports, supersedes, disposes, delivers stale results,
## remounts and removes the subscription again, with refusals at every mount.
expect run_media([0, 0, 5, 1, 5, 0, 1, 0, 4, 0, 3, 0, 5, 0, 3, 0, 5, 1, 2, 0]) == {}

## A generated history checks the batch boundary itself against a plain
## value model: equality prunes, empty types still mark, and a Self result
## joins its caller's types. Initial Self turns remain part of mount.
run_transitions : List(U8) -> {}
run_transitions = |program| {
	view = Core.state(
		1.U64,
		|st| Core.element(
			"button",
			[Core.on_click(st.set_value(|_, payload| U64.from_str(payload) ?? 0))],
			[
				Core.watch(
					st.signal(),
					|n| if (n == 0) [] else if (n == 1) [Core.command(ViewTransition(["odd", "shared", "odd"])), Core.again({})] else if (n == 3) [Core.command(ViewTransition([]))] else [Core.command(ViewTransition([if (n % 2 == 0) "even" else "odd", "shared"]))],
					st.on_result(|before, _, _| if (before == 1) 2 else before),
				),
			],
		),
	)
	(initial, mount_bytes) = Core.take_cmds(Core.mount(view), [])
	if mount_bytes.get(0) != Ok(0) or Core.work_counters(initial).get(45) != Ok(0) {
		crash "mount transition"
	}
	var $engine = initial
	var $value = 2.U64
	var $count = 0.U64
	for byte in program {
		next = byte.to_u64() % 6
		marked = next != $value and next != 0
		types = if (next == 1) ["odd", "shared", "even"] else if (next == 3) [] else [if (next % 2 == 0) "even" else "odd", "shared"]
		var $want = if (marked) le32([1, 24], types.len()) else []
		if marked {
			$count = $count + 1
			for name in types {
				$want = wstr($want, name)
			}
		}
		(after, commands) = Core.take_cmds(Core.event($engine, 1, 0, next.to_str()), [])
		if commands != $want or Core.work_counters(after).get(45) != Ok($count) {
			crash "transition batch disagrees with value model"
		}
		if Core.settled(after).is_err() {
			crash "transition watcher left stale"
		}
		$engine = after
		$value = if (next == 1) 2 else next
	}
	{}
}

expect run_transitions([2, 1, 1, 3, 3, 0, 5, 4, 0, 1]) == {}

Input : { mode : U8, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program }| {
	if mode == 0 {
		Fuzz.reject
	} else {
		run_program!(program)
		run_media(program)
		run_transitions(program)
		run_persistence(program)
		run_progress(program)
		CurrentModel.run(program)
		Fuzz.keep
	}
}

ex : Str, U8, List(U8) -> Fuzz.Example(Input)
ex = |name, mode, program| Fuzz.example({ name, revision: "1", make: || { mode, program } })

target = Fuzz.target_with!({
	name: "fx-channel",
	examples: [
		ex("keep-current-lifecycle", 1, [18, 22, 12, 27, 30, 3, 10, 1, 8, 39, 1, 6, 5, 4, 9, 15, 21, 24, 27]),
		ex("keep-current-aba", 1, [18, 12, 9, 18, 9, 15]),
		ex("keep-current-follow-ups", 1, [18, 6, 16, 10, 15, 9]),
		ex("keep-current-orphans", 1, [18, 1, 10, 9, 1, 12, 1, 18, 16, 15, 10, 9]),
		ex("keep-current-empty-step", 1, [12, 24, 15, 9, 18, 30, 9]),
		ex("progress-lifecycle", 1, [0, 4, 3, 8, 1, 3, 2, 0, 5, 6, 12, 3, 16, 3, 9]),
		ex("post-send-time-reading", 1, [12, 0, 4, 0, 12, 0, 4, 0, 12, 0, 2, 5, 2, 6, 2, 7]),
		ex("persistence-lifetimes", 1, [3, 0, 2, 4, 1, 5, 1, 0, 8, 11, 0, 14, 1, 17, 1]),
		ex("transition-batches", 1, [2, 1, 1, 3, 3, 0, 5, 4, 0, 1]),
		ex("media-lifecycle", 1, [0, 0, 5, 1, 5, 0, 1, 0, 4, 0, 3, 0, 5, 0, 3, 0, 5, 1, 2, 0]),
		# issue 0 x3 (third refused + self), deliver, toggle 0 (cancel), deliver cancelled, show again
		ex("lifecycle", 1, [0, 0, 0, 0, 0, 0, 2, 1, 1, 0, 2, 2, 1, 0, 3, 7, 0, 1, 0, 2]),
		# saturate across sites, popstate, stale and never-issued ids
		ex("saturate", 1, [0, 0, 0, 1, 0, 2, 2, 3, 2, 4, 3, 5, 0, 1, 1, 1, 2, 9, 2, 255]),
		# six issues on site 1: the sixth's first follow-up hides the site mid-drain
		ex("self-dispose", 1, [0, 1, 2, 2, 0, 1, 2, 3, 0, 1, 0, 1, 2, 5, 0, 1, 0, 1, 1, 1, 0, 1]),
		# free two slots, then walk L through a request, an interval, a request
		# with follow-ups (the first supersedes the second) and a pure cancel
		ex("latest", 1, [1, 0, 1, 1, 4, 0, 2, 6, 4, 0, 7, 7, 4, 0, 4, 0, 4, 0, 2, 9, 7, 3, 4, 0, 2, 12]),
		# R: supersede a request, a request and a timer; hide with both in
		# flight (the timer stops, the request reparents and is skipped); show
		# again; an interval whose ticks are equal folds
		ex("resource", 1, [1, 0, 1, 1, 5, 0, 5, 0, 2, 3, 6, 0, 2, 4, 2, 5, 6, 0, 5, 0, 7, 8, 5, 0, 7, 9, 5, 0, 2, 13]),
		# at the in-flight bound: L's and R's refusals are queued follow-ups that
		# a later value supersedes or a disposal drops
		ex("supersede-queued", 1, [0, 0, 4, 0, 4, 0, 4, 0, 4, 0, 1, 2, 4, 0, 4, 0, 4, 0, 6, 0, 5, 0, 5, 0, 6, 0, 5, 0, 6, 0]),
		# R's third input issues an interval and a worker job: deliver the job's
		# output, then issue again, supersede the next job, and hide R with one
		# in flight (cancelled, not reparented), then lose one after showing R
		ex("work", 1, [1, 0, 1, 1, 5, 0, 5, 0, 5, 0, 7, 9, 5, 0, 5, 0, 5, 0, 5, 0, 5, 0, 5, 0, 6, 0, 6, 0, 7, 15, 7, 17]),
		# a flood past the bound: 65 or more refusals from one turn, each one
		# chain deep, then results for some of its timers; free slots and flood
		# again, with L and R adding their own requests
		ex("flood", 1, [8, 0, 2, 7, 7, 12, 1, 0, 1, 1, 8, 0, 4, 0, 5, 0, 2, 90, 8, 0, 7, 140]),
		# P: free slots, issue a call and a subscription, message the
		# subscription, supersede both, hide P with the call kept and the
		# subscription cancelled, answer the kept call, show P, close its
		# subscription and message it after
		ex("ports", 1, [1, 0, 1, 1, 9, 0, 10, 9, 9, 0, 9, 1, 10, 9, 9, 1, 10, 13, 10, 12, 10, 13]),
		# X: free slots, ask three jobs and answer them last first (the third,
		# then a failure for the second, then the first), ask again with one
		# job refused at the bound, supersede it, hide X with jobs in flight
		# (they reparent and their answers are skipped) and show it again
		ex("gather", 1, [1, 0, 1, 1, 1, 2, 11, 0, 11, 0, 2, 14, 2, 13, 2, 12, 11, 0, 11, 0, 11, 0, 11, 1, 2, 15, 11, 1, 2, 18]),
		# O: post an item, post an equal one (both sent), answer the second
		# first, then post past the bound: the refusal reaches the log with
		# its item
		ex("post", 1, [1, 0, 1, 1, 12, 0, 12, 0, 12, 0, 2, 13, 2, 12, 12, 0, 12, 0, 12, 0, 12, 0, 12, 0, 12, 0]),
	],
	generator: { mode: Fuzz.constant(1), program: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})

## A second generated effect model exercises page persistence and clipboard
## requests. It knows only their disposal classes, issued ids and subscription
## lifetimes, independently of the engine's paths or effect-table representation.
PersistLive : { id : U32, sub : Bool, keep : Bool, orphan : Bool }

PersistModel : { next : U32, live : List(PersistLive), max : U64, shown : Bool, query : U64, issued : U64, delivered : U64, refused : U64, stale : U64, cancelled : U64, reparented : U64 }

persist_plan : U64 -> List(Core.Request)
persist_plan = |query| [SessionStorageGet("draft${query.to_str()}"), StorageChanges("saved${query.to_str()}"), StorageWriteFailures, ClipboardWrite({ text: query.to_str(), html: if (query % 2 == 0) Plain else Html("<p>${query.to_str()}</p>") })]

persist_issue : PersistModel -> (PersistModel, List(Dom.FxCmd))
persist_issue = |model| {
	var $model = model
	var $commands = []
	for index in 0.U64..<4 {
		prior = $model
		id = prior.next
		if prior.live.len() >= prior.max {
			$model = { ..prior, next: id + 1, refused: prior.refused + 1, delivered: prior.delivered + 1 }
		} else {
			kept = index == 0 or index == 3
			command = match index {
				0 => SessionGet(id, "draft${prior.query.to_str()}")
				1 => StorageSub(id, "saved${prior.query.to_str()}")
				2 => StorageFailures(id)
				_ => Clipboard(id, { text: prior.query.to_str(), html: if (prior.query % 2 == 0) Plain else Html("<p>${prior.query.to_str()}</p>") })
			}
			$commands = $commands.append(command)
			$model = { ..prior, next: id + 1, issued: prior.issued + 1, live: prior.live.append({ id, sub: !kept, keep: kept, orphan: False }) }
		}
	}
	($model, $commands)
}

persist_check : Core.App({}), List(Dom.FxCmd), PersistModel, List(Dom.FxCmd) -> {}
persist_check = |engine, got, model, wanted| {
	stats = Core.fx_stats(engine)
	actual = { commands: got, live: Core.fx_live(engine), issued: stats.issued, delivered: stats.delivered, refused: stats.refused, stale: stats.stale, cancelled: stats.cancelled, reparented: stats.reparented }
	expected = { commands: wanted, live: model.live.map(|entry| entry.id), issued: model.issued, delivered: model.delivered, refused: model.refused, stale: model.stale, cancelled: model.cancelled, reparented: model.reparented }
	if actual != expected {
		crash "persistence effect model differs: ${Str.inspect(actual)} expected ${Str.inspect(expected)}"
	}
	if Core.settled(engine).is_err() {
		crash "persistence effect model left a reader stale"
	}
}

run_persistence : List(U8) -> {}
run_persistence = |bytes| {
	max = 2 + (bytes.first() ?? 0).to_u64() % 4
	view = Core.state(
		{ shown: True, query: 0.U64 },
		|state| Core.element(
			"main",
			[],
			[
				Core.element("button", [Core.on_click(state.update(|value| { ..value, query: value.query + 1 }))], [Core.text("query")]),
				Core.element("button", [Core.on_click(state.update(|value| { ..value, shown: !value.shown }))], [Core.text("toggle")]),
				Core.when(state.signal().map(|value| value.shown), || Core.watch_latest(state.signal().map(|value| value.query), |query| persist_plan(query).map(Core.raw), Core.ignore({})), || Core.text("")),
			],
		),
	)
	(initial, commands) = Core.take_cmds(Core.mount_with(max, view), [])
	(dom, _, emitted) = Dom.apply_fx(Dom.new({}), commands)
	(first, wanted) = persist_issue({ next: 1, live: [], max, shown: True, query: 0, issued: 0, delivered: 0, refused: 0, stale: 0, cancelled: 0, reparented: 0 })
	persist_check(initial, emitted, first, wanted)
	var $engine = initial
	var $dom = dom
	var $model = first
	for byte in bytes {
		model = $model
		var $wanted = []
		(engine, next) = if byte % 3 == 2 {
			id = byte.to_u32() % model.next + 1
			payload = if (byte % 2 == 0) [23] else [25, 2, 1, 'd']
			found = model.live.find_first(|entry| entry.id == id)
			after = match found {
				Ok(live) => { ..model, delivered: model.delivered + 1, live: if (live.sub) model.live else model.live.keep_if(|item| item.id != id) }
				Err(_) => { ..model, stale: model.stale + 1 }
			}
			(Core.result($engine, id, Core.decode_res(payload)), after)
		} else {
			toggles = byte % 3 == 1
			showing = if (toggles) !model.shown else model.shown
			query = model.query + if (toggles) 0 else 1
			owned = model.live.keep_if(|entry| !entry.orphan)
			cancel = if (!toggles and model.shown) owned else if (toggles and model.shown) owned.keep_if(|entry| !entry.keep) else []
			orphans = if (toggles and model.shown) owned.count_if(|entry| entry.keep) else 0
			$wanted = cancel.map(|entry| Cancel(entry.id))
			base = { ..model, shown: showing, query, live: model.live.keep_if(|entry| !cancel.any(|removed| removed.id == entry.id)).map(|entry| if (toggles and model.shown) { ..entry, orphan: True } else entry), cancelled: model.cancelled + cancel.len(), reparented: model.reparented + orphans }
			after = if showing {
				(issued, fresh) = persist_issue(base)
				$wanted = $wanted.concat(fresh)
				issued
			} else base
			label = if (toggles) "toggle" else "query"
			index = SpecRunner.find($dom, Text(label)) ?? crash "persistence model button absent"
			route = Dom.target($dom, index, "click", True) ?? crash "persistence model button has no handler"
			(Core.event($engine, route.node, route.handler, ""), after)
		}
		(taken, batch) = Core.take_cmds(engine, [])
		(dom2, _, got) = Dom.apply_fx($dom, batch)
		persist_check(taken, got, next, $wanted)
		$engine = taken
		$dom = dom2
		$model = next
	}
	{}
}

## Mixed refusals, supersession, repeated reports and reparenting use the same model.
expect run_persistence([3, 0, 2, 4, 1, 5, 1, 0, 8, 11, 0, 14, 1, 17, 1]) == {}

## Generated progress and final turns preserve issued-for identity across
## supersession and reparenting. The model tracks live owners independently;
## reports never retire an id or increase final delivery counters.
run_progress : List(U8) -> {}
run_progress = |bytes| {
	view = Core.state(
		{ shown: True, query: 0.U64, progress: 0.U64, answered: 0.U64 },
		|state| Core.element(
			"main",
			[],
			[
				Core.element("button", [Core.on_click(state.update(|value| { ..value, query: value.query + 1 }))], [Core.text("query")]),
				Core.element("button", [Core.on_click(state.update(|value| { ..value, shown: !value.shown }))], [Core.text("toggle")]),
				Core.text_s(state.signal().map(|value| "${value.progress.to_str()}/${value.answered.to_str()}")),
				Core.when(
					state.signal().map(|value| value.shown),
					|| Core.watch_latest(
						state.signal().map(|value| value.query),
						|query| [Core.http({ url: "/progress/${query.to_str()}", cache: NoStore, credentials: Include })],
						state.on_result(|value, query, _| { ..value, answered: value.answered + query + 1 }).with_progress({ every_ms: 1 }, state.on_progress(|value, query, transfer| { ..value, progress: value.progress + query + transfer.done })),
					),
					|| Core.text(""),
				),
			],
		),
	)
	(initial, mount) = Core.take_cmds(Core.mount_with(64, view), [])
	var $engine = initial
	var $dom = Dom.apply(Dom.new({}), mount)
	var $live = [{ id: 1.U32, query: 0.U64, orphan: False }]
	var $next = 2.U32
	var $shown = True
	var $query = 0.U64
	var $progress = 0.U64
	var $answered = 0.U64
	var $reports = 0.U64
	var $delivered = 0.U64
	var $stale = 0.U64
	var $cancelled = 0.U64
	var $reparented = 0.U64
	for byte in bytes {
		var $wanted = []
		engine = if byte % 4 < 2 {
			id = byte.to_u32() % $next + 1
			found = $live.find_first(|entry| entry.id == id)
			match found {
				Err(_) => {
					$stale = $stale + 1
				}
				Ok(entry) => if byte % 4 == 0 {
					$reports = $reports + 1
					$progress = $progress + entry.query + byte.to_u64()
				} else {
					$answered = $answered + entry.query + 1
					$delivered = $delivered + 1
					$live = $live.keep_if(|item| item.id != id)
				}
			}
			if (byte % 4 == 0) Core.progress($engine, id, { direction: Receiving, done: byte.to_u64(), total: Unknown }) else Core.result($engine, id, Timeout)
		} else {
			toggle = byte % 4 == 3
			if toggle {
				$shown = !$shown
				if !$shown {
					$reparented = $reparented + $live.count_if(|entry| !entry.orphan)
					$live = $live.map(|entry| { ..entry, orphan: True })
				}
			} else {
				$query = $query + 1
				if $shown {
					removed = $live.keep_if(|entry| !entry.orphan)
					$wanted = removed.map(|entry| Cancel(entry.id))
					$cancelled = $cancelled + removed.len()
					$live = $live.keep_if(|entry| entry.orphan)
				}
			}
			if $shown {
				id = $next
				$next = $next + 1
				$live = $live.append({ id, query: $query, orphan: False })
				$wanted = $wanted.append(Http(id, "GET", "/progress/${$query.to_str()}", [], "", 0, { cache: "no-store", credentials: "include", progress_ms: 16 }))
			}
			label = if (toggle) "toggle" else "query"
			index = SpecRunner.find($dom, Text(label)) ?? crash "progress model button absent"
			route = Dom.target($dom, index, "click", True) ?? crash "progress model button has no handler"
			Core.event($engine, route.node, route.handler, "")
		}
		(taken, commands) = Core.take_cmds(engine, [])
		(dom, _, effects) = Dom.apply_fx($dom, commands)
		stats = Core.fx_stats(taken)
		actual = { live: Core.fx_live(taken), effects, progress: Core.work_counters(taken).get(47), issued: stats.issued, delivered: stats.delivered, stale: stats.stale, cancelled: stats.cancelled, reparented: stats.reparented, text: Dom.text_of(dom, dom.root) }
		expected = { live: $live.map(|entry| entry.id), effects: $wanted, progress: Ok($reports), issued: ($next - 1).to_u64(), delivered: $delivered, stale: $stale, cancelled: $cancelled, reparented: $reparented, text: "querytoggle${$progress.to_str()}/${$answered.to_str()}" }
		if actual != expected {
			crash "progress lifecycle model differs: ${Str.inspect(actual)} expected ${Str.inspect(expected)}"
		}
		if Core.settled(taken).is_err() {
			crash "progress turn left a reader stale"
		}
		$engine = taken
		$dom = dom
	}
	{}
}

## Progress remains live through repeated reports, reparenting, final delivery and supersession.
expect run_progress([0, 4, 3, 8, 1, 3, 2, 0, 5, 6, 12, 3, 16, 3, 9]) == {}
