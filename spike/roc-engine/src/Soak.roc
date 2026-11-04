import Engine
import Dom
import Spec

## Long-session soak over any app: a random walk of real user events chosen
## from the live DOM (every attached element with a handler, disabled
## controls skipped), plus cycle checks that a scripted round trip returns
## the engine to the same live allocation count. Used by every app's
## fuzz target (explorer inputs and a seeded 10k-event example).
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
				if Dom.attr_of(n, "checked") == "true" "false" else "true"
			} else if n.tag == "select" {
				opts = n.kids.map(|k| Dom.attr_of(Dom.node(dom, k), "value"))
				if opts.is_empty() "" else opts.get(b.to_u64() % opts.len()) ?? ""
			} else {
				Soak.pool.get(b.to_u64() % Soak.pool.len()) ?? ""
			}
		} else if ev == "focus" or ev == "blur" {
			Dom.attr_of(n, "value")
		} else {
			""
		}
	}

	## One random event (none when nothing is interactive).
	step : Spec.S, U8, U8 -> Spec.S
	step = |s, pick, b| {
		cs = Soak.candidates(s.dom)
		if cs.is_empty() {
			s
		} else {
			(i, ev) = cs.get(pick.to_u64() % cs.len()) ?? crash "candidate"
			payload = Soak.payload_for(s.dom, i, ev, b)
			s1 = if ev == "input" or ev == "change" {
				name = if Dom.attr_of(Dom.node(s.dom, i), "type") == "checkbox" "checked" else "value"
				Spec.set_attr(s, i, name, payload)
			} else {
				s
			}
			match Spec.fire(s1, i, ev, payload) {
				Ok(s2) => s2
				Err(msg) => crash "soak: ${msg}"
			}
		}
	}

	## A walk driven by explorer bytes (two per event).
	walk : Spec.S, List(U8), (Spec.S -> Spec.S) -> Spec.S
	walk = |s0, bytes, after| {
		var $s = s0
		var $i = 0.U64
		while $i + 1 < bytes.len() {
			$s = after(Soak.step($s, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0))
			$i = $i + 2
		}
		$s
	}

	prng : U64 -> U64
	prng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

	## A seeded walk of `n` events.
	walk_n : Spec.S, U64, U64, (Spec.S -> Spec.S) -> Spec.S
	walk_n = |s0, seed, n, after| {
		var $s = s0
		var $x = seed
		var $i = 0.U64
		while $i < n {
			$x = Soak.prng($x)
			$s = after(Soak.step($s, $x.shr_zf_wrap(40).to_u8_wrap(), $x.shr_zf_wrap(24).to_u8_wrap()))
			$i = $i + 1
		}
		$s
	}

	## The (node, handler, payload) events of one scripted round trip, found
	## through the DOM model while applying them.
	triples : Spec.S, List(Spec.Step), (Spec.S -> Spec.S) -> (Spec.S, List((U32, U32, Str)))
	triples = |s0, steps, after| {
		var $s = s0
		var $out = []
		for st in steps {
			(loc, ev, payload, attr) = match st {
				Click(l) => (l, "click", "", "")
				Fill(l, v) => (l, "input", v, "value")
				Choose(l, v) => (l, "change", v, "value")
				Check(l, b) => (l, "change", Spec.bool_str(b), "checked")
				_ => crash "soak cycles take only user actions"
			}
			i = Spec.find($s.dom, loc) ?? crash "cycle: no ${Spec.show_loc(loc)}"
			(node, h) = Dom.target($s.dom, i, ev) ?? crash "cycle: no ${ev} handler"
			s1 = if attr == "" $s else Spec.set_attr($s, i, attr, payload)
			$s = after(Spec.fire(s1, i, ev, payload) ?? crash "cycle fire")
			$out = $out.append((node, h, payload))
		}
		($s, $out)
	}

	## Replay a round trip on the engine alone (no DOM model, command buffer
	## reused) `k` times. Each cycle runs inside a measured region (`begin!`,
	## `end!`); `end!` reports the live bytes the cycle left behind (exit
	## minus entry), so probes never see their own bookkeeping.
	replay! : Engine.App, List((U32, U32, Str)), U64, (Engine.App, List(U8) -> (Engine.App, List(U8))), ({} => m), (m => I64) => List(I64)
	replay! = |app0, evs, k, after, begin!, end!| {
		var $a = app0
		var $buf = []
		var $counts = []
		var $c = 0.U64
		while $c < k {
			m = begin!({})
			for (node, h, payload) in evs {
				(a1, b1) = Engine.take_cmds(Engine.event($a, node, h, payload), $buf)
				(a2, b2) = after(a1, b1)
				$a = a2
				$buf = b2
			}
			$counts = $counts.append(end!(m))
			$c = $c + 1
		}
		$counts
	}

	## After `warm` warm-up cycles every cycle must leave zero net live bytes.
	flat : List(I64), U64 -> Try({}, Str)
	flat = |nets, warm| {
		tail = nets.drop_first(warm)
		if !tail.any(|c| c != 0) Ok({}) else Err("cycles leave live bytes behind (net per cycle): ${Str.inspect(nets)}")
	}
}
