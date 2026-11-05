app [target] {
	pf: platform "../../platform/test.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
	ts: "../../test-support/main.roc",
}

import pf.Core
import pf.Fuzz
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import StatusApp

## Status Page on the Roc-owned engine (its specs run through
## `main-test.roc`).
## - generated: walks of refreshes, interval ticks, visibility changes and
##   answers (healthy, degraded, garbled, failed, timed out, in any order),
##   which must free everything they allocated.
## - "soak-10k": 10k seeded steps, then "Refresh now" answered healthy 48
##   times on the engine alone with flat live bytes.

St : SpecRunner.S(Core.App)

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
answer_one : St, SpecRunner.Pending, U8 -> St
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
	SpecRunner.deliver(Core.driver(StatusApp.program), { ..s, browser: { ..br, pending: br.pending.keep_if(|q| q.id != p.id) } }, p.id, payload)
}

step : St, Scm.Op -> St
step = |s, op|
	match SpecRunner.one(Core.driver(StatusApp.program), s, op) {
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
start = |_| SpecRunner.mount(Core.driver(StatusApp.program), "/", [])

## Answer every in-flight request except the subscriptions `subs`, healthy,
## on the engine alone.
answer_app : List(U32), Core.App, List(U8) -> (Core.App, List(U8))
answer_app = |subs, a0, b0| {
	var $a = a0
	var $b = b0
	for id in Core.fx_live(a0).keep_if(|id| !subs.contains(id)) {
		(a1, b1) = Core.take_cmds(Core.result($a, id, Http({ status: 200, headers: [], body: "operational|99.99" })), $b)
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
	subs = Core.fx_live(s0.inst)
	i = SpecRunner.find(s0.dom, Role({ role: "button", name: "Refresh now" })) ?? crash "soak: no Refresh now"
	(node, h) = Dom.target(s0.dom, i, "click") ?? crash "soak: no click handler"
	counts = Soak.replay!(Core.driver(StatusApp.program), s0.inst, [(node, h, [])], 48, |a, b| answer_app(subs, a, b), begin!, net_bytes!)
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
	if mode == 2 {
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
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
