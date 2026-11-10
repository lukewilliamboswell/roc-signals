app [target] { pf: platform "../../../platform/fuzz.roc" }

import pf.Core
import pf.Fuzz
import pf.Scm
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
## - "soak-10k": 10k seeded steps (settle-checked and leak-checked), then a
##   round trip through the late branch 48 times on the engine alone with
##   flat live bytes.

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

walk_n : St, U64, U64 -> St
walk_n = |s0, seed, n| {
	check = Soak.settled(program)
	var $s = check(s0)
	var $x = seed
	var $i = 0.U64
	while $i < n {
		$x = Soak.prng($x)
		$s = check(walk_step($s, $x.shr_zf_wrap(40).to_u8_wrap(), $x.shr_zf_wrap(24).to_u8_wrap()))
		$i = $i + 1
	}
	$s
}

start : {} -> St
start = |_| SpecRunner.mount(program, "/", [])

## A round trip back to the initial shape: the late branch opened, its
## nested states written, and closed again.
cycle : List(Scm.Op)
cycle = [
	Click(Role({ role: "button", name: "Toggle late" })),
	Click(Role({ role: "button", name: "Inc derived" })),
	Click(Role({ role: "button", name: "Toggle inner" })),
	Click(Role({ role: "button", name: "Inc inner" })),
	Click(Role({ role: "button", name: "Toggle inner" })),
	Click(Role({ role: "button", name: "Toggle late" })),
]

## Soak, mode 2: an explorer-driven walk (two bytes per step) from a fresh
## mount, settle-checked at every step, which must free everything it
## allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |bytes| {
	Fuzz.expect_no_leaks!(|| walk(start({}), bytes))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded steps (settle-checked, leak-checked), then the
## late-branch round trip 48 times on the engine alone: live allocations
## flat after 2 warm-up cycles. The late branch issues a timer each time it
## opens; closing it cancels the timer, so the cycle needs no answers.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| walk_n(start({}), 7, 10000))
	(s1, evs) = Soak.triples(program, start({}), cycle, Soak.settled(program))
	counts = Soak.replay!(program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
	match Soak.flat(counts, 2) {
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
test! = |{ mode, program: bytes, .. }| {
	if mode == 2 {
		soak_walk!(bytes)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, List(U8) -> Fuzz.Example(Input)
ex = |name, mode, bytes| Fuzz.example({ name, revision: "1", make: || { mode, size: 0, program: bytes } })

target = Fuzz.target_with!({
	name: "supersede",
	examples: [
		ex("soak-10k", 3, []),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
