app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import SupersedeApp

## The supersession app (`SupersedeApp`): `latest` and `resource` sites at
## the top level, in rows and in a component, and layers that exist only in
## branches mounted after the first or below a `derive` or a `resource`.
## - generated: walks of clicks on any live control, answers to any pending
##   request or timer (a body, a 503 or a timeout, in any order) and interval
##   ticks, from a fresh mount. Every step must leave the engine settled (the
##   soak's settle check), and the walk must free everything it allocated.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-late-branch.scm`).

St : SpecRunner.S(Core.App)

program : SpecRunner.Program(Core.App)
program = Core.driver(SupersedeApp.program)

## Answer the pending request `b` picks (none when `b` points past the
## last): a timer fires; an HTTP request gets a body, a 503 or a timeout.
answer : St, U8 -> St
answer = |s, b| {
	br = s.browser
	match br.pending.get(b.to_u64() % (br.pending.len() + 1)) {
		Ok(p) => {
			payload = match p.kind {
				TimerRequest => [5]
				WorkRequest(_) => crash "the supersede app issues no worker jobs"
				ReadRequest(_) => crash "the supersede app reads no files"
				UploadRequest(_) => crash "the supersede app uploads no files"
				DigestRequest(_) => crash "the supersede app digests no files"
				UrlRequest(_) => crash "the supersede app asks for no file URLs"
				PortRequest(_) => crash "the supersede app declares no ports"
				FetchRequest => crash "the supersede app fetches no files"
				HttpRequest =>
					if b % 5 == 3 {
						SpecRunner.encode_http(503, [], "unavailable")
					} else if b % 5 == 4 {
						SpecRunner.encode_reject(Timeout, "")
					} else {
						SpecRunner.encode_http(200, [], "v${b.to_str()}")
					}
			}
			SpecRunner.deliver(program, { ..s, browser: { ..br, pending: br.pending.keep_if(|q| q.id != p.id) } }, p.id, payload)
		}
		Err(_) => s
	}
}

## One step chosen by two bytes: mostly a click on a live control, else an
## answer or an interval tick.
walk_step : St, U8, U8 -> St
walk_step = |s, op, b|
	match op % 8 {
		0 | 1 | 2 | 3 | 4 => Soak.step(program, s, b, op, Soak.no_jobs)
		5 | 6 => answer(s, b)
		_ => SpecRunner.tick(program, s, if (b % 2 == 0) 100 else 1000)
	}

walk : St, List(U8) -> St
walk = |s0, bytes| {
	check = Soak.settled(program)
	var $s = check(s0)
	var $i = 0.U64
	while $i + 1 < bytes.len() {
		$s = check(walk_step($s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0))
		$i = $i + 2
	}
	$s
}

start : {} -> St
start = |_| SpecRunner.mount(program, "/", [])

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
	name: "supersede",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
