app [target] {
	pf: platform "../../../platform/test.roc",
	ts: "../../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.SpecRunner
import FxApp

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Engine.App, dom : Dom.Model, steps : U64 }

start : Engine.Elem(Engine.Root) -> S
start = |view| {
	(a, c) = Engine.take_cmds(Engine.mount(view), [])
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

Kind : [G, H, Tick, Pop]

Live : { id : U32, k : U64, c : U64, kind : Kind, orphan : Bool }

## A queued follow-up: a refusal for G or H, or a Self (first or second).
Follow : { k : U64, c : U64, what : [RefG, RefH, RefT, Self1, Self2] }

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

model_deliver : M, U32, Engine.Res -> M
model_deliver = |m, id, res| {
	match m.live.find_first(|l| l.id == id) {
		Ok(l) => {
			sub = l.kind == Tick or l.kind == Pop
			live = if (sub) m.live else m.live.keep_if(|x| x.id != id)
			m1 = { ..m, live, delivered: m.delivered + 1 }
			match l.kind {
				H => if (l.orphan) { ..m1, skipped: m1.skipped + 1 } else { ..m1, hits: m1.hits.update(l.k, |h| h + 1) ?? m1.hits }
				_ => { ..m1, log: m1.log.append(FxApp.describe(l.k, l.c, res)) }
			}
		}
		Err(_) => { ..m, stale: m.stale + 1 }
	}
}

E : { s : S, fx : List(Dom.FxCmd) }

## Apply one batch to the oracle. The engine's per-opcode work counters must
## have moved by exactly the commands the oracle decoded from it.
apply! : S, Engine.App, List(U8) => E
apply! = |s, a, c| {
	(d2, ops, fx) = Dom.apply_fx(s.dom, c)
	before = Engine.work_counters(s.eng)
	after = Engine.work_counters(a)
	var $op = 1.U64
	while $op <= 18 {
		moved = (after.get($op) ?? 0) - (before.get($op) ?? 0)
		seen = ops.count_if(|o| o.to_u64() == $op)
		if moved != seen {
			crash "work counter for ${Dom.op_name($op.to_u8_wrap())} moved by ${moved.to_str()}, the batch holds ${seen.to_str()}"
		}
		$op = $op + 1
	}
	{ s: { eng: a, dom: d2, steps: s.steps + 1 }, fx }
}

click! : S, Str => E
click! = |s, name| {
	i = SpecRunner.find(s.dom, Role({ role: "button", name })) ?? crash "no button ${name}"
	(node, h) = Dom.target(s.dom, i, "click") ?? crash "no handler"
	(a, c) = Engine.take_cmds(Engine.event(s.eng, node, h, ""), [])
	apply!(s, a, c)
}

## Results go through the wire: an independent encoder here, the engine's
## decoder there (the round trip is part of what the model checks).
deliver! : S, U32, Engine.Res => E
deliver! = |s, id, res| {
	(a, c) = Engine.take_cmds(Engine.result(s.eng, id, Engine.decode_res(encode_res(res))), [])
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
	st = Engine.fx_stats(e.s.eng)
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
	# The FX and CANCEL work counters are the model's issued and cancelled
	# requests: every admitted request is one FX, every stop one CANCEL.
	w = Engine.work_counters(e.s.eng)
	if (w.get(13) ?? 0) != m.issued or (w.get(14) ?? 0) != m.cancelled {
		crash "${what}: FX/CANCEL work counters ${(w.get(13) ?? 0).to_str()}/${(w.get(14) ?? 0).to_str()}, model issued/cancelled ${m.issued.to_str()}/${m.cancelled.to_str()}"
	}
	if Engine.fx_live(e.s.eng) != m.live.map(|l| l.id) {
		crash "${what}: live ids ${Str.inspect(Engine.fx_live(e.s.eng))}, model ${Str.inspect(m.live.map(|l| l.id))}"
	}
}

run_program! : List(U8) => {}
run_program! = |prog| {
	max = 5
	(a0, c0) = Engine.take_cmds(Engine.mount_with(max, FxApp.main({})), [])
	(d0, _, fx0) = Dom.apply_fx(Dom.new({}), c0)
	var $s = { eng: a0, dom: d0, steps: 0 }
	var $m = model_new(max)
	check!("mount", { s: $s, fx: fx0 }, $m)
	var $i = 0.U64
	while $i + 1 < prog.len() {
		op = (prog.get($i) ?? 0) % 4
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
		} else {
			url = "/u${arg.to_str()}"
			(deliver!($s, 1, Location(url)), model_deliver(m0, 1, Location(url)), "popstate ${url}")
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
	],
	generator: { mode: Fuzz.constant(1), program: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
