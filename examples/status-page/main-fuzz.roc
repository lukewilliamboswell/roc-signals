app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/main-fuzz.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
}

import fz.Fuzz
import pf.Core
import pf.Scm
import pf.Soak
import pf.SpecRunner
import StatusApp

## Status Page on the Roc-owned engine (its specs run through
## `main.roc`).
## - generated: walks of refreshes, interval ticks, visibility changes and
##   answers (healthy, degraded, garbled, failed, timed out, in any order),
##   which must leave the engine settled at every step and free everything
##   they allocated.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-refresh-answered-healthy.scm`).

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

## The settle check after every step (`Soak.settled`).
settled : St -> St
settled = Soak.settled(Core.driver(StatusApp.program))

walk : St, List(U8) -> St
walk = |s0, bytes| {
	var $s = s0
	var $i = 0.U64
	while $i + 1 < bytes.len() {
		$s = settled(walk_step($s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0))
		match SpecRunner.check_counters($s) {
			Ok(_) => {}
			Err(m) => crash "status walk: work counters: ${m}"
		}
		$i = $i + 2
	}
	$s
}

start : {} -> St
start = |_| SpecRunner.mount(Core.driver(StatusApp.program), "/", [])

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| walk(start({}), Soak.session_bytes(session)))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "status-page",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
