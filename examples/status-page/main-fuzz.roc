app [target] {
	pf: platform "../../platform/test.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import StatusApp

## Status Page on the Roc-owned engine (its specs run through
## `main-test.roc`).
## - "bench": one measured region per engine transaction: the first
##   results, a timed refresh with a degraded service and a two-incident
##   feed, an edited incident, hiding and showing the page, a manual refresh.
## - generated: walks of refreshes, interval ticks, visibility changes and
##   answers (healthy, degraded, garbled, failed, timed out, in any order),
##   which must free everything they allocated.
## - "soak-10k": 10k seeded steps, then "Refresh now" answered healthy 48
##   times on the engine alone with flat live bytes.

St : SpecRunner.S(Engine.App)

checks : List(Str)
checks = ["operational|99.98", "degraded|97.40", "outage|10.00", "garbled", ""]

feeds : List(Str)
feeds = [
	"",
	"inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy",
	"inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses#inc-51~minor~Delayed notification delivery~11:10@Investigating a backlog",
	"inc-51~major~Delayed notification delivery~11:10@Investigating a backlog^11:40@Identified queue saturation#inc-42~minor~Elevated API error rate",
]

pick : List(Str), U8 -> Str
pick = |pool, b| pool.get(b.to_u64() % pool.len()) ?? ""

## Answer pending request `p` with the `b`-th answer for its URL: a body
## from the pools, or (every seventh) a 503 or a timeout.
answer_one : St, { id : U32, url : Str, body : Str }, U8 -> St
answer_one = |s, p, b| {
	payload =
		if b % 7 == 5 {
			SpecRunner.encode_http(503, [], "unavailable")
		} else if b % 7 == 6 {
			SpecRunner.encode_reject(Timeout, "")
		} else {
			SpecRunner.encode_http(200, [], pick(if (p.url.ends_with("incidents")) feeds else checks, b))
		}
	br = s.browser
	SpecRunner.deliver(StatusApp.program, { ..s, browser: { ..br, pending: br.pending.keep_if(|q| q.id != p.id) } }, p.id, payload)
}

step : St, Scm.Op -> St
step = |s, op|
	match SpecRunner.one(StatusApp.program, s, op) {
		Ok(s2) => s2
		Err(e) => crash "status walk: ${Str.inspect(e)}"
	}

## One step of a walk, chosen by two bytes.
walk_step : St, U8, U8 -> St
walk_step = |s, op, b|
	match op % 6 {
		0 => step(s, Click(Role({ role: "button", name: "Refresh now" })))
		1 => step(s, TickIntervalIfActive(5000))
		2 => step(s, SetVisibility(if (b % 2 == 0) Hidden else Visible))
		3 | 4 =>
			match s.browser.pending.get(b.to_u64() % (s.browser.pending.len() + 1)) {
				Ok(p) => answer_one(s, p, b)
				Err(_) => s
			}
		_ => {
			var $s = s
			for p in s.browser.pending {
				$s = answer_one($s, p, 0)
			}
			$s
		}
	}

walk : St, List(U8) -> St
walk = |s0, bytes| {
	var $s = s0
	var $i = 0.U64
	while $i + 1 < bytes.len() {
		$s = walk_step($s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0)
		match SpecRunner.check_counters($s) {
			Ok(_) => {}
			Err(m) => crash "status walk: work counters: ${m}"
		}
		$i = $i + 2
	}
	$s
}

prng : U64 -> U64
prng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

walk_n : St, U64, U64 -> St
walk_n = |s0, seed, n| {
	var $s = s0
	var $x = seed
	var $i = 0.U64
	while $i < n {
		$x = prng($x)
		$s = walk_step($s, $x.shr_zf_wrap(40).to_u8_wrap(), $x.shr_zf_wrap(24).to_u8_wrap())
		$i = $i + 1
	}
	$s
}

start : {} -> St
start = |_| SpecRunner.mount(StatusApp.program, "/", [])

## One measured engine transaction (the oracle's model kept in step).
measured! : St, Str, (Engine.App -> Engine.App) => St
measured! = |st, name, f| {
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(f(st.inst), [])
	_ = w.finish!()
	SpecRunner.take_batch(st, a, c)
}

## Answer the pending request for `url` (the oldest) with `body`.
respond! : St, Str, Str, Str => St
respond! = |st, name, url, body| {
	p = st.browser.pending.find_first(|q| q.url == url) ?? crash "bench ${name}: nothing pending for ${url}"
	br = st.browser
	s1 = { ..st, browser: { ..br, pending: br.pending.keep_if(|q| q.id != p.id) } }
	measured!(s1, name, |a| Engine.result(a, p.id, Http({ status: 200, headers: [], body })))
}

## Deliver a subscription result (`payload` per Appendix B) to every live
## subscription of kind `sub`.
broadcast! : St, Str, SpecRunner.Sub, Engine.Res => St
broadcast! = |st, name, sub, res| {
	var $s = st
	for x in st.browser.subs.keep_if(|x| x.sub == sub) {
		$s = measured!($s, name, |a| Engine.result(a, x.id, res))
	}
	$s
}

answer_round! : St, Str, Str => St
answer_round! = |st, prefix, api| {
	var $s = st
	$s = respond!($s, "${prefix}-api", "/api/status/api", api)
	$s = respond!($s, "${prefix}-web", "/api/status/web", "operational|99.99")
	$s = respond!($s, "${prefix}-database", "/api/status/database", "operational|99.90")
	$s = respond!($s, "${prefix}-notifications", "/api/status/notifications", "operational|99.95")
	$s
}

bench! : {} => Fuzz.Outcome
bench! = |_| {
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(StatusApp.main(Bool.True)), [])
	_ = w.finish!()
	var $s = SpecRunner.adopt(a0, c0, "/", [])
	$s = answer_round!($s, "first", "operational|99.98")
	$s = respond!($s, "first-incidents", "/api/status/incidents", "")
	$s = broadcast!($s, "tick", Interval(5000), Fired)
	$s = answer_round!($s, "tick", "degraded|97.40")
	$s = respond!($s, "tick-incidents", "/api/status/incidents", feeds.get(2) ?? "")
	$s = broadcast!($s, "tick-2", Interval(5000), Fired)
	$s = answer_round!($s, "tick-2", "degraded|97.40")
	$s = respond!($s, "tick-2-incidents", "/api/status/incidents", feeds.get(3) ?? "")
	$s = broadcast!($s, "hide", VisibilitySub, Visible(Bool.False))
	$s = broadcast!($s, "show", VisibilitySub, Visible(Bool.True))
	$s = answer_round!($s, "show", "operational|99.98")
	$s = respond!($s, "show-incidents", "/api/status/incidents", "")
	i = SpecRunner.find($s.dom, Role({ role: "button", name: "Refresh now" })) ?? crash "bench: no Refresh now"
	(node, h) = Dom.target($s.dom, i, "click") ?? crash "bench: no click handler"
	$s = measured!($s, "refresh", |a| Engine.event(a, node, h, ""))
	_ = $s
	Fuzz.keep
}

## Answer every in-flight request except the subscriptions `subs`, healthy,
## on the engine alone.
answer_app : List(U32), Engine.App, List(U8) -> (Engine.App, List(U8))
answer_app = |subs, a0, b0| {
	var $a = a0
	var $b = b0
	for id in Engine.fx_live(a0).keep_if(|id| !subs.contains(id)) {
		(a1, b1) = Engine.take_cmds(Engine.result($a, id, Http({ status: 200, headers: [], body: "operational|99.99" })), $b)
		$a = a1
		$b = b1
	}
	($a, $b)
}

answer_all : St -> St
answer_all = |s0| {
	var $s = s0
	for p in s0.browser.pending {
		$s = answer_one($s, p, 0)
	}
	$s
}

## Soak, mode 2: an explorer-driven walk (two bytes per step) from a fresh
## mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| walk(start({}), program))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded steps (leak-checked), then "Refresh now" with
## every check answered, 48 times on the engine alone: live allocations flat
## after 3 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| walk_n(start({}), 7, 10000))
	s0 = answer_all(start({}))
	subs = Engine.fx_live(s0.inst)
	i = SpecRunner.find(s0.dom, Role({ role: "button", name: "Refresh now" })) ?? crash "soak: no Refresh now"
	(node, h) = Dom.target(s0.dom, i, "click") ?? crash "soak: no click handler"
	counts = Soak.replay!(StatusApp.program, s0.inst, [(node, h, [])], 48, |a, b| answer_app(subs, a, b), begin!, net_bytes!)
	# Three warm-up cycles: the first changes the board (every request now
	# answers "operational|99.99", which the feed parses as one incident)
	# and the next two settle the buffers that change grew.
	match Soak.flat(counts, 3) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle net live bytes ${Str.inspect(counts.sublist({ start: 0, len: 4 }))} ... (${counts.len().to_str()} cycles)")
	Fuzz.keep
}

## Soak probes: a measured region around one cycle; its net live bytes.
begin! : {} => Fuzz.Measurement
begin! = |_| Fuzz.start_measure!("cycle")

net_bytes! : Fuzz.Measurement => I64
net_bytes! = |w| {
	stats = w.finish!()
	stats.exit_live_bytes.to_i64_wrap() - stats.entry_live_bytes.to_i64_wrap()
}

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program, .. }| {
	if mode == 0 {
		bench!({})
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "status-page",
	examples: [
		ex("soak-10k", 3, 0),
		ex("bench", 0, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
