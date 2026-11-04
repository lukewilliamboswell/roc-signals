import Engine
import Dom
import Spec

## Replays specs with effects (Conduit's `.scm`, converted by
## tools/scm2fxroc.py) against an app on the engine, with a modelled browser:
## a location and history stack, the document title, local storage, the
## pending awaited requests and the live subscriptions, all driven only by the
## effect commands the engine emits (decoded by `Dom.apply_fx`).
##
## Semantics follow the original native spec runner:
## - `run-effect N` answers the N-th awaited non-subscription request the
##   app issued (issue order; subscriptions such as popstate are not
##   counted). It must still be pending. Its answer is the first queued stub
##   whose URL equals the request's (a reject stub matches any request);
## - a network reject becomes `Network("detail")`, a timeout `Timeout`,
##   the text the original platform's inspected HTTP error produced;
## - `expect-pending-effects` counts pending awaited non-subscription
##   requests;
## - `navigate` and `history-back/forward` change the location as the user
##   would (a new entry / moving in the stack) and deliver the new URL to
##   every live popstate subscription. App pushes and replaces update the
##   modelled location without a popstate, as browsers do.
FxSpec := [].{
	Setup : { url : Str, storage : List((Str, Str)) }

	Step : [
		Ui(Spec.Step),
		ExpLocation(Str),
		ExpTitle(Str),
		ExpStorage(Str, Str),
		ExpNoStorage(Str),
		ExpPending(U64),
		Run(U64),
		Stub(Str, U16, Str),
		Reject(Str, Str),
		Back,
		Forward,
		Navigate(Str),
	]

	Stub : [Resp(Str, U16, Str), Rej(Str, Str)]

	B : {
		loc : Str,
		back : List(Str),
		fwd : List(Str),
		title : Str,
		storage : List((Str, Str)),
		pending : List({ id : U32, url : Str }),
		issued : List(U32),
		subs : List(U32),
		stubs : List(Stub),
	}

	S : { s : Spec.S, b : B }

	set_store : List((Str, Str)), Str, Str -> List((Str, Str))
	set_store = |l, k, v| l.keep_if(|(k2, _)| k2 != k).append((k, v))

	## Apply the effect commands of one batch to the modelled browser.
	absorb : B, List(Dom.FxCmd) -> B
	absorb = |b0, fx| {
		var $b = b0
		for c in fx {
			b = $b
			$b = match c {
				Http(id, _, url, _, _, _) => { ..b, pending: b.pending.append({ id, url }), issued: b.issued.append(id) }
				Get(id, key) => { ..b, pending: b.pending.append({ id, url: "storage:${key}" }), issued: b.issued.append(id) }
				Timer(id, _) => { ..b, pending: b.pending.append({ id, url: "timer" }), issued: b.issued.append(id) }
				Interval(id, _) => { ..b, subs: b.subs.append(id) }
				Pop(id) => { ..b, subs: b.subs.append(id) }
				Cancel(id) => { ..b, pending: b.pending.keep_if(|p| p.id != id), subs: b.subs.keep_if(|s| s != id) }
				Push(url) => { ..b, back: b.back.append(b.loc), loc: url, fwd: [] }
				Replace(url) => { ..b, loc: url }
				Set(k, v) => { ..b, storage: FxSpec.set_store(b.storage, k, v) }
				Remove(k) => { ..b, storage: b.storage.keep_if(|(k2, _)| k2 != k) }
				Title(t) => { ..b, title: t }
				Focus(_, _) => b
			}
		}
		$b
	}

	## Hand one batch to both the DOM model and the browser model.
	take : S, Engine.App, List(U8) -> S
	take = |{ s, b }, a, c| {
		(d2, _, fx) = Dom.apply_fx(s.dom, c)
		{ s: { eng: a, dom: d2, steps: s.steps + 1 }, b: FxSpec.absorb(b, fx) }
	}

	start : (Engine.Boot -> Engine.Elem(Engine.Root)), Setup -> S
	start = |view, setup| {
		(a, c) = Engine.take_cmds(Engine.mount_with(32, view({ url: setup.url, storage: setup.storage })), [])
		b0 = { loc: setup.url, back: [], fwd: [], title: "", storage: setup.storage, pending: [], issued: [], subs: [], stubs: [] }
		(d, _, fx) = Dom.apply_fx(Dom.new({}), c)
		{ s: { eng: a, dom: d, steps: 0 }, b: FxSpec.absorb(b0, fx) }
	}

	fire : S, U64, Str, Str -> Try(S, Str)
	fire = |st, i, ev, payload| {
		match Dom.target(st.s.dom, i, ev) {
			Err(_) => Err("no ${ev} handler")
			Ok((node, h)) => {
				(a, c) = Engine.take_cmds(Engine.event(st.s.eng, node, h, payload), [])
				Ok(FxSpec.take(st, a, c))
			}
		}
	}

	deliver : S, U32, Engine.Res -> S
	deliver = |st, id, res| {
		(a, c) = Engine.take_cmds(Engine.result(st.s.eng, id, res), [])
		FxSpec.take(st, a, c)
	}

	## The browser moved to b.loc on its own: every popstate subscription hears it.
	popstate : S -> S
	popstate = |st0| {
		var $st = st0
		for id in st0.b.subs {
			$st = FxSpec.deliver($st, id, Location(st0.b.loc))
		}
		$st
	}

	## A rejected request: a typed Timeout, or a network failure whose text is
	## what the original platform showed.
	reject_res : Str, Str -> Engine.Res
	reject_res = |kind, detail| if kind == "timeout" Timeout else Network(FxSpec.reject_text(kind, detail))

	reject_text : Str, Str -> Str
	reject_text = |kind, detail| if kind == "timeout" "Timeout" else if kind == "network" "Network(\"${detail}\")" else "${kind}(\"${detail}\")"

	run_effect : S, U64 -> Try(S, Str)
	run_effect = |st, n| {
		b = st.b
		id = b.issued.get(n - 1) ?? 0
		if id == 0 {
			return Err("effect occurrence ${n.to_str()} was never issued (${b.issued.len().to_str()} issued)")
		}
		p = b.pending.find_first(|q| q.id == id) ?? { id: 0, url: "" }
		if p.id == 0 {
			return Err("effect occurrence ${n.to_str()} is not pending (cancelled or done)")
		}
		pos = b.stubs.find_first_index(
			|stub| match stub {
				Resp(u, _, _) => u == p.url
				Rej(_, _) => True
			},
		)
		match pos {
			Err(_) => Err("no spec stub for ${p.url}")
			Ok(k) => {
				stub = b.stubs.get(k) ?? crash "stub"
				b2 = { ..b, stubs: b.stubs.drop_at(k), pending: b.pending.keep_if(|q| q.id != id) }
				res = match stub {
					Resp(_, status, body) => Http({ status, headers: [("content-type", "application/json")], body })
					Rej(kind, detail) => FxSpec.reject_res(kind, detail)
				}
				Ok(FxSpec.deliver({ s: st.s, b: b2 }, id, res))
			}
		}
	}

	one : S, Step -> Try(S, Str)
	one = |st, step| {
		b = st.b
		dom = st.s.dom
		need = |loc| Spec.find(dom, loc).map_err(|_| "no element ${Spec.show_loc(loc)}")
		match step {
			Ui(Click(loc)) => {
				i = need(loc)?
				if Dom.attr_of(Dom.node(dom, i), "disabled") == "true" Ok(st) else FxSpec.fire(st, i, "click", "")
			}
			Ui(Fill(loc, v)) => {
				i = need(loc)?
				{ s, b: bb } = st
				s2 = Spec.set_attr(s, i, "value", v)
				FxSpec.fire({ s: s2, b: bb }, i, "input", v)
			}
			Ui(ui) => {
				s2 = Spec.one(st.s, ui)?
				Ok({ s: s2, b })
			}
			ExpLocation(want) => if b.loc == want Ok(st) else Err("location \"${b.loc}\", expected \"${want}\"")
			ExpTitle(want) => if b.title == want Ok(st) else Err("title \"${b.title}\", expected \"${want}\"")
			ExpStorage(k, want) => {
				got = b.storage.find_first(|(k2, _)| k2 == k).map_ok(|(_, v)| v) ?? "<missing>"
				if got == want Ok(st) else Err("storage ${k} = \"${got}\", expected \"${want}\"")
			}
			ExpNoStorage(k) => if b.storage.any(|(k2, _)| k2 == k) Err("storage ${k} is present") else Ok(st)
			ExpPending(n) => if b.pending.len() == n Ok(st) else Err("expected ${n.to_str()} pending effects, got ${b.pending.len().to_str()}")
			Run(n) => FxSpec.run_effect(st, n)
			Stub(url, status, body) => Ok({ s: st.s, b: { ..b, stubs: b.stubs.append(Resp(url, status, body)) } })
			Reject(kind, detail) => Ok({ s: st.s, b: { ..b, stubs: b.stubs.append(Rej(kind, detail)) } })
			Navigate(url) => Ok(FxSpec.popstate({ s: st.s, b: { ..b, back: b.back.append(b.loc), loc: url, fwd: [] } }))
			Back => match b.back.last() {
				Ok(prev) => Ok(FxSpec.popstate({ s: st.s, b: { ..b, back: b.back.drop_last(1), fwd: [b.loc].concat(b.fwd), loc: prev } }))
				Err(_) => Err("history-back with no history")
			}
			Forward => match b.fwd.first() {
				Ok(nx) => Ok(FxSpec.popstate({ s: st.s, b: { ..b, fwd: b.fwd.drop_first(1), back: b.back.append(b.loc), loc: nx } }))
				Err(_) => Err("history-forward with no forward entry")
			}
		}
	}

	## Lenient replay: a pending-count mismatch is recorded instead of failing,
	## and `run-effect` of an issued request that is no longer pending
	## (cancelled when its owner was disposed) still delivers the stubbed
	## result to the engine, which must drop it as stale. Returns the
	## recorded deviations; Err still names the first hard failure.
	run_lenient : (Engine.Boot -> Engine.Elem(Engine.Root)), Setup, List(Step) -> Try((S, List(Str)), Str)
	run_lenient = |view, setup, steps| {
		var $s = FxSpec.start(view, setup)
		var $dev = []
		var $i = 0.U64
		for st in steps {
			b = $s.b
			soft = match st {
				ExpPending(n) => if b.pending.len() == n Err(Hard) else Ok("step ${$i.to_str()}: ${n.to_str()} pending expected, ${b.pending.len().to_str()} here")
				Run(n) => {
					id = b.issued.get(n - 1) ?? 0
					if id != 0 and !b.pending.any(|q| q.id == id) Ok("step ${$i.to_str()}: effect ${n.to_str()} was cancelled; its late result is delivered and dropped") else Err(Hard)
				}
				_ => Err(Hard)
			}
			match soft {
				Ok(note) => {
					$dev = $dev.append(note)
					match st {
						Run(n) => {
							id = b.issued.get(n - 1) ?? 0
							stale0 = Engine.fx_stats($s.s.eng).stale
							k = b.stubs.find_first_index(|_| True) ?? crash "lenient: no stub"
							res = match b.stubs.get(k) ?? crash "stub" {
								Resp(_, status, body) => Http({ status, headers: [("content-type", "application/json")], body })
								Rej(kind, detail) => FxSpec.reject_res(kind, detail)
							}
							$s = FxSpec.deliver({ s: $s.s, b: { ..b, stubs: b.stubs.drop_at(k) } }, id, res)
							if Engine.fx_stats($s.s.eng).stale != stale0 + 1 {
								return Err("step ${$i.to_str()}: late result for cancelled effect was not counted stale")
							}
						}
						_ => {}
					}
				}
				Err(Hard) => match FxSpec.one($s, st) {
					Ok(s2) => {
						$s = s2
					}
					Err(msg) => {
						return Err("step ${$i.to_str()}: ${msg}")
					}
				}
			}
			$i = $i + 1
		}
		Ok(($s, $dev))
	}

	## Replay one spec from a fresh mount. Err names the failing step.
	run : (Engine.Boot -> Engine.Elem(Engine.Root)), Setup, List(Step) -> Try(S, Str)
	run = |view, setup, steps| {
		var $s = FxSpec.start(view, setup)
		var $i = 0.U64
		for st in steps {
			match FxSpec.one($s, st) {
				Ok(s2) => {
					$s = s2
				}
				Err(msg) => {
					return Err("step ${$i.to_str()}: ${msg}")
				}
			}
			$i = $i + 1
		}
		Ok($s)
	}
}
