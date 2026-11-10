import Dom
import Scm
import SpecRunner

## Long-session soak over any app: a random walk of real user events chosen
## from the live DOM (every attached element with a handler, disabled
## controls skipped), plus cycle checks that a scripted round trip returns
## the engine to the same live allocation count. Used by every app's
## fuzz target (explorer inputs and a seeded 10k-event example).
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

	## Answer the oldest pending worker job, chosen by `b`: usually run its
	## program in process (`Work`), sometimes lose it with a fault class, time
	## it out when it has a deadline, or leave it pending (so disposal can
	## still cancel it). A crash in the program ends the walk: the UI produced
	## an input the program cannot handle, which is a finding.
	answer_work : SpecRunner.Program(state), SpecRunner.S(state), U8 -> SpecRunner.S(state)
	answer_work = |program, s, b| {
		match s.browser.pending.find_first(|p| Soak.is_work(p)) {
			Ok(p) if b % 8 != 7 => {
				n = (s.browser.issued.find_first_index(|id| id == p.id) ?? crash "soak: a pending job was issued") + 1
				op = match b % 8 {
					5 => LoseWork({ occurrence: n, fault: Soak.faults.get((b.to_u64() / 8) % Soak.faults.len()) ?? Executor })
					6 if Soak.deadline_of(p) > 0 => TimeOutWork(n)
					_ => RunEffect(n)
				}
				match SpecRunner.one(program, s, op) {
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
	step : SpecRunner.Program(state), SpecRunner.S(state), U8, U8 -> SpecRunner.S(state)
	step = |program, s, pick, b| {
		cs = Soak.candidates(s.dom)
		if pick >= 0xC0 and s.browser.pending.any(|p| Soak.is_work(p)) {
			Soak.answer_work(program, s, b)
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

	## A walk driven by explorer bytes (two per event).
	walk : SpecRunner.Program(state), SpecRunner.S(state), List(U8), (SpecRunner.S(state) -> SpecRunner.S(state)) -> SpecRunner.S(state)
	walk = |program, s0, bytes, after| {
		var $s = s0
		var $i = 0.U64
		while $i + 1 < bytes.len() {
			$s = after(Soak.step(program, $s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0))
			$i = $i + 2
		}
		$s
	}

	prng : U64 -> U64
	prng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

	## A seeded walk of `n` events.
	walk_n : SpecRunner.Program(state), SpecRunner.S(state), U64, U64, (SpecRunner.S(state) -> SpecRunner.S(state)) -> SpecRunner.S(state)
	walk_n = |program, s0, seed, n, after| {
		var $s = s0
		var $x = seed
		var $i = 0.U64
		while $i < n {
			$x = Soak.prng($x)
			$s = after(Soak.step(program, $s, $x.shr_zf_wrap(40).to_u8_wrap(), $x.shr_zf_wrap(24).to_u8_wrap()))
			$i = $i + 1
		}
		$s
	}

	## The (node, handler, payload) events of one scripted round trip, found
	## through the DOM model while applying them.
	triples : SpecRunner.Program(state), SpecRunner.S(state), List(Scm.Op), (SpecRunner.S(state) -> SpecRunner.S(state)) -> (SpecRunner.S(state), List((U32, U32, List(U8))))
	triples = |program, s0, steps, after| {
		var $s = s0
		var $out = []
		for st in steps {
			(loc, ev, payload, attr) = match st {
				Click(l) => (l, "click", "", "")
				Fill(l, v) => (l, "input", v, "value")
				SelectOption(l, v) => (l, "change", v, "value")
				Check(l) => (l, "change", "true", "checked")
				Uncheck(l) => (l, "change", "false", "checked")
				_ => crash "soak cycles take only user actions"
			}
			i = SpecRunner.find($s.dom, loc) ?? crash "cycle: no ${Scm.show_loc(loc)}"
			(node, h) = Dom.target($s.dom, i, ev) ?? crash "cycle: no ${ev} handler"
			s1 = if (attr == "") $s else SpecRunner.set_attr($s, i, attr, payload)
			$s = after(SpecRunner.fire(program, s1, i, ev, payload) ?? crash "cycle fire")
			$out = $out.append((node, h, payload.to_utf8()))
		}
		($s, $out)
	}

	## Replay a round trip on the engine alone (no DOM model, command buffer
	## reused) `k` times. Each cycle runs inside a measured region (`begin!`,
	## `end!`); `end!` reports the live bytes the cycle left behind (exit
	## minus entry), so probes never see their own bookkeeping.
	replay! : SpecRunner.Program(state), state, List((U32, U32, List(U8))), U64, (state, List(U8) -> (state, List(U8))), ({} => m), (m => I64) => List(I64)
	replay! = |program, inst0, evs, k, after, begin!, end!| {
		var $a = inst0
		var $buf = []
		var $wbuf = []
		var $counts = []
		var $c = 0.U64
		while $c < k {
			m = begin!({})
			for (node, h, payload) in evs {
				(a1, b1, w1) = (program.event)($a, $buf, $wbuf, node, h, payload)
				(a2, b2) = after(a1, b1)
				$a = a2
				$buf = b2
				$wbuf = w1
			}
			$counts = $counts.append(end!(m))
			$c = $c + 1
		}
		$counts
	}

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

	## After `warm` warm-up cycles every cycle must leave zero net live bytes.
	flat : List(I64), U64 -> Try({}, Str)
	flat = |nets, warm| {
		tail = nets.drop_first(warm)
		if (!tail.any(|c| c != 0)) Ok({}) else Err("cycles leave live bytes behind (net per cycle): ${Str.inspect(nets)}")
	}
}
