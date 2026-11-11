import Dom
import Scm
import SpecRunner

## Long-session walks over any app: a random walk of real user events chosen
## from the live DOM (every attached element with a handler, disabled
## controls skipped), settle-checked at every step. Used by every app's fuzz
## target, on explorer inputs and on a seeded input (`seeded`) each target
## declares as an example. The flat round trips are specs the native
## runner soaks (`--soak`).
##
## It drives the app's `Program` (as `SpecRunner` does), so it shares no code
## with the engine.
Soak := [].{

	## Payloads typed into text boxes.
	pool : List(Str)
	pool = ["", "a", "Ada", "10", "-3", "2x", "x@y.z", "Lorem ipsum dolor", "Node-0007", "# Title", "Renamed"]

	## (node index, event name) for every attached node with a handler.
	candidates : Dom.Model -> List((U64, Str))
	candidates = |dom| {
		var $stack = [dom.root]
		var $out = []
		while !$stack.is_empty() {
			i = $stack.last() ?? 0
			$stack = $stack.drop_last(1)
			n = Dom.node(dom, i)
			if Dom.attr_of(n, "disabled") != "true" {
				for (ev, _) in n.hs {
					base = ev.split_on(":").first() ?? ev
					$out = $out.append((i, base))
				}
			}
			var $k = n.kids.len()
			while $k > 0 {
				$k = $k - 1
				$stack = $stack.append(n.kids.get($k) ?? 0)
			}
		}
		$out
	}

	## The payload a browser would send for this event on this node.
	payload_for : Dom.Model, U64, Str, U8 -> Str
	payload_for = |dom, i, ev, b| {
		n = Dom.node(dom, i)
		if ev == "input" {
			Soak.pool.get(b.to_u64() % Soak.pool.len()) ?? ""
		} else if ev == "change" {
			if Dom.attr_of(n, "type") == "checkbox" {
				if (Dom.attr_of(n, "checked") == "true") "false" else "true"
			} else if n.tag == "select" {
				opts = n.kids.map(|k| Dom.attr_of(Dom.node(dom, k), "value"))
				if (opts.is_empty()) "" else opts.get(b.to_u64() % opts.len()) ?? ""
			} else {
				Soak.pool.get(b.to_u64() % Soak.pool.len()) ?? ""
			}
		} else if ev == "focus" or ev == "blur" {
			Dom.attr_of(n, "value")
		} else {
			""
		}
	}

	## The fault classes a walk loses a worker job to, in the order a byte
	## picks them.
	faults : List(Scm.WorkFault)
	faults = [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## A walk's stand-in for a worker: the answer a job of the task named
	## first gives for the input bytes second, as `SpecRunner.answer_work`
	## takes it. A walk has no host to run a job's effects on, so a target
	## whose app issues work answers with the app's pure function, through
	## `Worker`'s `stand_in`.
	StandIn : Str, List(U8), List(U8) -> List(U8)

	## The stand-in of a walk over an app that issues no worker jobs: any job
	## is a finding.
	no_jobs : Str, List(U8), List(U8) -> List(U8)
	no_jobs = |task, _, _| crash "soak: the app issued a job of worker task \"${task}\"; walk it with walk_with and a stand-in"

	## Answer the oldest pending worker job, chosen by `b`: usually answer it
	## with `stand_in`, sometimes lose it with a fault class, time it out when
	## it has a deadline, or leave it pending (so disposal can still cancel
	## it). A crash in the stand-in ends the walk: the UI produced an input
	## the app's function cannot handle, which is a finding.
	answer_work : SpecRunner.Program(state), SpecRunner.S(state), U8, StandIn -> SpecRunner.S(state)
	answer_work = |program, s, b, stand_in| {
		match s.browser.pending.find_first(|p| Soak.is_work(p)) {
			Ok(p) if b % 8 != 7 => {
				n = (s.browser.issued.find_first_index(|id| id == p.id) ?? crash "soak: a pending job was issued") + 1
				answered = match b % 8 {
					5 => SpecRunner.one(program, s, LoseWork({ occurrence: n, fault: Soak.faults.get((b.to_u64() / 8) % Soak.faults.len()) ?? Executor }))
					6 if Soak.deadline_of(p) > 0 => SpecRunner.one(program, s, TimeOutWork(n))
					_ => SpecRunner.answer_work(program, s, n, stand_in)
				}
				match answered {
					Ok(s2) =>
						match SpecRunner.check_counters(s2) {
							Ok(_) => s2
							Err(msg) => crash "soak: work counters: ${msg}"
						}
					Err(msg) => crash "soak: answering worker job ${n.to_str()}: ${msg}"
				}
			}
			_ => s
		}
	}

	is_work : SpecRunner.Pending -> Bool
	is_work = |p|
		match p.kind {
			WorkRequest(_) => Bool.True
			_ => Bool.False
		}

	deadline_of : SpecRunner.Pending -> U32
	deadline_of = |p|
		match p.kind {
			WorkRequest(w) => w.deadline_ms
			_ => 0
		}

	## One random event (none when nothing is interactive). While a worker job
	## is pending, a pick byte of 0xC0 or more answers one (`answer_work`)
	## instead; a walk of an app that issues no work is unchanged.
	step : SpecRunner.Program(state), SpecRunner.S(state), U8, U8, StandIn -> SpecRunner.S(state)
	step = |program, s, pick, b, stand_in| {
		cs = Soak.candidates(s.dom)
		if pick >= 0xC0 and s.browser.pending.any(|p| Soak.is_work(p)) {
			Soak.answer_work(program, s, b, stand_in)
		} else if cs.is_empty() {
			s
		} else {
			(i, ev) = cs.get(pick.to_u64() % cs.len()) ?? crash "candidate"
			payload = Soak.payload_for(s.dom, i, ev, b)
			s1 = if ev == "input" or ev == "change" {
				name = if (Dom.attr_of(Dom.node(s.dom, i), "type") == "checkbox") "checked" else "value"
				SpecRunner.set_attr(s, i, name, payload)
			} else {
				s
			}
			match SpecRunner.fire(program, s1, i, ev, payload) {
				Ok(s2) =>
					match SpecRunner.check_counters(s2) {
						Ok(_) => s2
						Err(msg) => crash "soak: work counters: ${msg}"
					}
				Err(msg) => crash "soak: ${msg}"
			}
		}
	}

	## A walk driven by explorer bytes (two per event), of an app that
	## issues no worker jobs.
	walk : SpecRunner.Program(state), SpecRunner.S(state), List(U8), (SpecRunner.S(state) -> SpecRunner.S(state)) -> SpecRunner.S(state)
	walk = |program, s0, bytes, after| Soak.walk_with(program, s0, bytes, Soak.no_jobs, after)

	## Like `walk`, answering the app's worker jobs with `stand_in`.
	walk_with : SpecRunner.Program(state), SpecRunner.S(state), List(U8), StandIn, (SpecRunner.S(state) -> SpecRunner.S(state)) -> SpecRunner.S(state)
	walk_with = |program, s0, bytes, stand_in, after| {
		var $s = s0
		var $i = 0.U64
		while $i + 1 < bytes.len() {
			$s = after(Soak.step(program, $s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0, stand_in))
			$i = $i + 2
		}
		$s
	}

	## The step of a linear congruential generator the seeded inputs use.
	prng : U64 -> U64
	prng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

	## The input of a seeded walk of `n` steps (two bytes each) from `seed`:
	## a long session a target declares as an example of its walk, so the
	## same property that explores arbitrary input replays it.
	seeded : U64, U64 -> List(U8)
	seeded = |seed, n| {
		var $out = List.with_capacity(2 * n)
		var $x = seed
		var $i = 0.U64
		while $i < n {
			$x = Soak.prng($x)
			$out = $out.append($x.shr_zf_wrap(40).to_u8_wrap()).append($x.shr_zf_wrap(24).to_u8_wrap())
			$i = $i + 1
		}
		$out
	}

	## A fuzz target's walk input: explorer bytes, then `steps` seeded steps
	## from `seed`. A target's generator fixes `steps` at 0 and explores the
	## bytes; its examples name a long seeded walk, which roc-fuzz could not
	## hold as explicit bytes (an example decodes at most 4,096 values).
	Session : { program : List(U8), seed : U64, steps : U64 }

	## The longest seeded walk a session may name. A session decoded from a
	## mutated corpus entry can name any count; a target rejects one over
	## this bound rather than allocate its bytes (`walkable`).
	max_steps : U64
	max_steps = 10000

	## Whether a target walks `session`: its seeded part is at most
	## `max_steps` long.
	walkable : Session -> Bool
	walkable = |session| session.steps <= Soak.max_steps

	## The bytes of a session's walk: its own, then its seeded ones.
	session_bytes : Session -> List(U8)
	session_bytes = |{ program, seed, steps }| program.concat(Soak.seeded(seed, steps))

	## The settle check as a walk's `after` hook: after every step the engine's
	## pass over every layer must emit nothing (`SpecRunner.check_settled`), so
	## a walk that leaves a reader stale fails at the step that did it. The
	## pass runs on a discarded copy and frees all it allocates before the
	## walk goes on, so a leak-checked walk measures what it did without it.
	settled : SpecRunner.Program(state) -> (SpecRunner.S(state) -> SpecRunner.S(state))
	settled = |program| |s|
		match SpecRunner.check_settled(program, s) {
			Ok(_) => s
			Err(msg) => crash "soak: ${msg}"
		}
}

## A seeded input holds two bytes per step, taken from the generator as it
## advances, so a walk over it is the walk the seed names.
expect {
	x = Soak.prng(7)
	Soak.seeded(7, 1) == [x.shr_zf_wrap(40).to_u8_wrap(), x.shr_zf_wrap(24).to_u8_wrap()] and Soak.seeded(7, 3).len() == 6
}
