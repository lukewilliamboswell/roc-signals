app [target] { pf: platform "../../../platform/fuzz.roc" }

import pf.Core
import pf.Fuzz
import pf.Engine
import pf.Dom
import pf.Scm
import pf.SpecRunner
import FxApp

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Core.App, dom : Dom.Model, steps : U64 }

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

Kind : [G, H, Tick, Pop, Lh, Li, Rh, Rt, Ri, Rw, Ft, Pc, Ps]

Live : { id : U32, k : U64, c : U64, kind : Kind, orphan : Bool }

## A queued follow-up: a refusal for G, H, an interval, L, R or F, or a
## Self (G's first or second, or L's).
Follow : { k : U64, c : U64, what : [RefG, RefH, RefT, Self1, Self2, RefL, SelfL, RefR, RefF, RefP] }

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
}

model_new : U64 -> M
model_new = |max| {
	m0 = {
		counts: [0, 0, 0],
		shown: [True, True, True],
		hits: [0, 0, 0],
		log: [],
		next: 2,
		live: [{ id: 1, k: 9, c: 0, kind: Pop, orphan: False }],
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
		rl: FxApp.begin_r(FxApp.load0, 0),
		f: 0,
		p: 0,
		pshown: True,
	}
	# each shown branch mounts its interval (counts are 0: no G/H)
	tick(tick(tick(m0, 0), 1), 2)
}

tick : M, U64 -> M
tick = |m, k| {
	id = m.next
	if m.live.len() >= m.max {
		# a refused interval: its reaction logs the refusal in a follow-up
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c: 0, what: RefT }) }
	} else {
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c: 0, kind: Tick, orphan: False }), fx: m.fx.append(Interval(id, 1000)) }
	}
}

## Admit (or refuse) one GET of kind G or H.
admit : M, U64, U64, Kind -> M
admit = |m, k, c, kind| {
	id = m.next
	if m.live.len() >= m.max {
		what = if (kind == G) RefG else RefH
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c, what }) }
	} else {
		url = if (kind == G) FxApp.url_of(k, c) else "/h${k.to_str()}/${c.to_str()}"
		headers = if (kind == G) [("accept", "text/plain")] else []
		# G asks for 300 ms (odd c) or c * 250 s, capped at 600 s; H for none
		asked = if (c % 2 == 1) 300 else c * 250000
		timeout = if (kind == G) (if (asked > 600000) 600000 else asked.to_u32_wrap()) else 0
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c, kind, orphan: False }), fx: m.fx.append(Http(id, "GET", url, headers, "", timeout)) }
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
			{ ..m1, queue: m1.queue.concat([{ k, c, what: Self1 }, { k, c, what: Self2 }]) }
		} else if c % 3 == 0 {
			{ ..m1, queue: m1.queue.append({ k, c, what: Self1 }) }
		} else {
			m1
		}
		admit(m2, k, c, H)
	}
}

## Admit (or refuse, queueing `refusal`) one awaited request of L, R or F:
## `cmd` is its effect command given the id.
admit_x : M, U64, U64, Kind, (U32 -> Dom.FxCmd), [RefL, RefR, RefF, RefP] -> M
admit_x = |m, k, c, kind, cmd, refusal| {
	id = m.next
	if m.live.len() >= m.max {
		what = match refusal {
			RefL => RefL
			RefR => RefR
			RefF => RefF
			RefP => RefP
		}
		{ ..m, next: id + 1, refused: m.refused + 1, queue: m.queue.append({ k, c, what }) }
	} else {
		{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c, kind, orphan: False }), fx: m.fx.append(cmd(id)) }
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
		admit_x(m, k_l, q, Lh, |id| Http(id, "GET", url, [], "", 5000), RefL)
	} else if q % 4 == 2 {
		admit_x(m, k_l, q, Li, |id| Interval(id, 500), RefL)
	} else if q % 4 == 3 {
		m1 = admit_x(m, k_l, q, Lh, |id| Http(id, "GET", url, [], "", 0), RefL)
		{ ..m1, queue: m1.queue.concat([{ k: k_l, c: q, what: SelfL }, { k: k_l, c: q, what: SelfL }]) }
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
		admit_x(m, k_r, r, Rh, |id| Http(id, "GET", url, [], "", 0), RefR)
	} else if r % 3 == 2 {
		m1 = admit_x(m, k_r, r, Rh, |id| Http(id, "GET", url, [], "", 0), RefR)
		admit_x(m1, k_r, r, Rt, |id| Timer(id, 100), RefR)
	} else {
		m1 = admit_x(m, k_r, r, Ri, |id| Interval(id, 700), RefR)
		admit_x(m1, k_r, r, Rw, |id| Work(id, FxApp.echo_name, [r.to_u8_wrap()], 100), RefR)
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
			RefR => { ..m, rl: FxApp.fold_r(m.rl, f.c, Refused), delivered: m.delivered + 1 }
			RefF => { ..m, log: m.log.append(FxApp.describe(k_f, f.c, Refused)), delivered: m.delivered + 1 }
			RefP => { ..m, log: m.log.append(FxApp.describe(k_p, f.c, Refused)), delivered: m.delivered + 1 }
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
		drain(issue_r({ ..m1, rl: FxApp.begin_r(m1.rl, r) }, r))
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
		drain(issue_r({ ..m, rshown: True, rl: FxApp.begin_r(FxApp.load0, m.r) }, m.r))
	}
}

model_deliver : M, U32, Engine.Res -> M
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
				Rh | Rt | Ri | Rw => if (l.orphan) { ..m1, skipped: m1.skipped + 1 } else { ..m1, rl: FxApp.fold_r(m1.rl, l.c, res) }
				_ => { ..m1, log: m1.log.append(FxApp.describe(l.k, l.c, res)) }
			}
		}
		Err(_) => { ..m, stale: m.stale + 1 }
	}
}

E : { s : S, fx : List(Dom.FxCmd) }

## Apply one batch to the oracle. The engine's per-opcode work counters must
## have moved by exactly the commands the oracle decoded from it.
apply! : S, Core.App, List(U8) => E
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
settle! : Core.App, Dom.Model => {}
settle! = |a, dom|
	match Core.settled(a) {
		Ok(_) => {}
		Err({ cmds, note }) => crash "a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(dom, cmds).1)} ${note}"
	}

click! : S, Str => E
click! = |s, name| {
	i = SpecRunner.find(s.dom, Role({ role: "button", name })) ?? crash "no button ${name}"
	(node, h) = Dom.target(s.dom, i, "click") ?? crash "no handler"
	(a, c) = Core.take_cmds(Core.event(s.eng, node, h, ""), [])
	apply!(s, a, c)
}

## Results go through the wire: an independent encoder here, the engine's
## decoder there (the round trip is part of what the model checks).
deliver! : S, U32, Engine.Res => E
deliver! = |s, id, res| {
	(a, c) = Core.take_cmds(Core.result(s.eng, id, Core.decode_res(encode_res(res))), [])
	apply!(s, a, c)
}

le32 : List(U8), U64 -> List(U8)
le32 = |b, v| b.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

wstr : List(U8), Str -> List(U8)
wstr = |b, s| le32(b, s.count_utf8_bytes()).concat(Str.to_utf8(s))

encode_res : Engine.Res -> List(U8)
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
	Fired => [5]
	Location(u) => [6].concat(Str.to_utf8(u))
	Work(out) => [10].concat(out)
	WorkLost(AppCrash) => [11, 4]
	PortReply({ json, .. }) => le32(le32(wstr([14], json), 0), 0)
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
		op = (prog.get($i) ?? 0) % 11
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
		} else if op == 10 {
			# A port's message, its close or its failure, for an arbitrary id.
			id = (arg.to_u32() % $m.next) + 1
			res = if (arg % 3 == 0) PortReply({ json: "\"m${arg.to_str()}\"", blobs: [], files: [] }) else if (arg % 3 == 1) PortFailed(Closed) else PortFailed(Threw("t${arg.to_str()}"))
			(deliver!($s, id, res), model_deliver(m0, id, res), "port result ${id.to_str()}")
		} else {
			# A tick, a job's output or a lost job for an arbitrary id: a tick
			# is an equal fold for R and "other" for logs.
			id = (arg.to_u32() % $m.next) + 1
			res = if (arg % 4 == 1) Work([arg]) else if (arg % 4 == 3) WorkLost(AppCrash) else Fired
			(deliver!($s, id, res), model_deliver(m0, id, res), "result ${id.to_str()}")
		}
		check!("step ${($i // 2).to_str()} ${what}", e, m2)
		$s = e.s
		$m = m2
		$i = $i + 2
	}
}

Input : { mode : U8, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program }| {
	if mode == 0 {
		Fuzz.reject
	} else {
		run_program!(program)
		Fuzz.keep
	}
}

ex : Str, U8, List(U8) -> Fuzz.Example(Input)
ex = |name, mode, program| Fuzz.example({ name, revision: "1", make: || { mode, program } })

target = Fuzz.target_with!({
	name: "fx-channel",
	examples: [
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
	],
	generator: { mode: Fuzz.constant(1), program: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
