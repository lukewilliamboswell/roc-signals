app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import FxApp

## Effect channel against a reference model.
## - generated: a byte program of issue / toggle (mount or dispose a site) /
##   deliver a result for an arbitrary id (live, delivered, cancelled,
##   refused or never issued) / popstate. After every step the effect
##   commands the engine emitted (decoded by Dom, in stream order), the
##   rendered reaction log and the engine's effect counters must equal the
##   model's. The in-flight bound is 3 (the popstate subscription holds one).
## - "bench": a fixed sequence with exact allocation baselines per step.

Live : { id : U32, k : U64, c : U64, sub : Bool }

M : {
	counts : List(U64),
	shown : List(Bool),
	log : List(Str),
	next : U32,
	live : List(Live),
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	cancelled : U64,
	max : U64,
	fx : List(Dom.FxCmd),
}

model_new : U64 -> M
model_new = |max| {
	counts: [0, 0, 0],
	shown: [True, True, True],
	log: [],
	next: 2,
	live: [{ id: 1, k: 9, c: 0, sub: True }],
	issued: 1,
	delivered: 0,
	stale: 0,
	refused: 0,
	cancelled: 0,
	max,
	fx: [Pop(1)],
}

## Site k issues for count c: the GET (admitted or refused), then the Self
## follow-up when c is a multiple of 3. Follow-ups are delivered after the
## turn, in order.
request : M, U64, U64 -> M
request = |m, k, c| {
	if c == 0 {
		m
	} else {
		id = m.next
		url = FxApp.url_of(k, c)
		m1 = if m.live.len() >= m.max {
			{ ..m, next: id + 1, refused: m.refused + 1, log: m.log.append(FxApp.describe(k, c, Refused)), delivered: m.delivered + 1 }
		} else {
			{ ..m, next: id + 1, issued: m.issued + 1, live: m.live.append({ id, k, c, sub: False }), fx: m.fx.append(Http(id, "GET", url, [("accept", "text/plain")], "")) }
		}
		if c % 3 == 0 {
			{ ..m1, log: m1.log.append(FxApp.describe(k, c, Now)), delivered: m1.delivered + 1 }
		} else {
			m1
		}
	}
}

model_issue : M, U64 -> M
model_issue = |m, k| {
	c = (m.counts.get(k) ?? 0) + 1
	m1 = { ..m, counts: m.counts.set(k, c) ?? m.counts }
	if m.shown.get(k) ?? False request(m1, k, c) else m1
}

model_toggle : M, U64 -> M
model_toggle = |m, k| {
	if m.shown.get(k) ?? False {
		var $m = { ..m, shown: m.shown.set(k, False) ?? m.shown }
		for l in m.live {
			if l.k == k {
				$m = { ..$m, fx: $m.fx.append(Cancel(l.id)), cancelled: $m.cancelled + 1 }
			}
		}
		{ ..$m, live: $m.live.keep_if(|l| l.k != k) }
	} else {
		m1 = { ..m, shown: m.shown.set(k, True) ?? m.shown }
		request(m1, k, m.counts.get(k) ?? 0)
	}
}

model_deliver : M, U32, Engine.Res -> M
model_deliver = |m, id, res| {
	match m.live.find_first(|l| l.id == id) {
		Ok(l) => {
			live = if l.sub m.live else m.live.keep_if(|x| x.id != id)
			{ ..m, live, log: m.log.append(FxApp.describe(l.k, l.c, res)), delivered: m.delivered + 1 }
		}
		Err(_) => { ..m, stale: m.stale + 1 }
	}
}

E : { s : Spec.S, fx : List(Dom.FxCmd) }

apply! : Spec.S, Engine.App, List(U8) => E
apply! = |s, a, c| {
	(d2, _, fx) = Dom.apply_fx(s.dom, c)
	{ s: { eng: a, dom: d2, steps: s.steps + 1 }, fx }
}

click! : Spec.S, Str => E
click! = |s, name| {
	i = Spec.find(s.dom, Role("button", name)) ?? crash "no button ${name}"
	(node, h) = Dom.target(s.dom, i, "click") ?? crash "no handler"
	(a, c) = Engine.take_cmds(Engine.event(s.eng, node, h, ""), [])
	apply!(s, a, c)
}

deliver! : Spec.S, U32, Engine.Res => E
deliver! = |s, id, res| {
	(a, c) = Engine.take_cmds(Engine.result(s.eng, id, res), [])
	apply!(s, a, c)
}

show_fx : List(Dom.FxCmd) -> Str
show_fx = |l| Str.inspect(l)

check! : Str, E, M => {}
check! = |what, e, m| {
	if e.fx != m.fx {
		crash "${what}: effect commands ${show_fx(e.fx)}, model ${show_fx(m.fx)}"
	}
	log = Dom.text_of(e.s.dom, Spec.find(e.s.dom, TestId("log")) ?? crash "no log")
	want = Str.join_with(m.log, "|")
	if log != want {
		crash "${what}: log \"${log}\", model \"${want}\""
	}
	st = Engine.fx_stats(e.s.eng)
	got = [st.issued, st.delivered, st.stale, st.refused, st.cancelled, st.live]
	exp = [m.issued, m.delivered, m.stale, m.refused, m.cancelled, m.live.len()]
	if got != exp {
		crash "${what}: counters ${Str.inspect(got)} (issued delivered stale refused cancelled live), model ${Str.inspect(exp)}"
	}
	if Engine.fx_live(e.s.eng) != m.live.map(|l| l.id) {
		crash "${what}: live ids ${Str.inspect(Engine.fx_live(e.s.eng))}, model ${Str.inspect(m.live.map(|l| l.id))}"
	}
}

run_program! : List(U8) => {}
run_program! = |prog| {
	max = 3
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
			res = Http({ status: 200, body })
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

## Fixed sequence with measured steps (exact allocation baselines).
bench! : {} => Fuzz.Outcome
bench! = |_| {
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount_with(3, FxApp.main({})), [])
	_ = w.finish!()
	var $s = { eng: a0, dom: Dom.apply(Dom.new({}), c0), steps: 0 }
	step! = |s, name, f| {
		wm = Fuzz.start_measure!(name)
		(a, c) = Engine.take_cmds(f(s.eng), [])
		_ = wm.finish!()
		{ eng: a, dom: Dom.apply(s.dom, c), steps: s.steps + 1 }
	}
	node_of = |s, name| {
		i = Spec.find(s.dom, Role("button", name)) ?? crash "no ${name}"
		Dom.target(s.dom, i, "click") ?? crash "no handler"
	}
	(n0, h0) = node_of($s, "issue 0")
	(t0, th0) = node_of($s, "toggle 0")
	$s = step!($s, "issue", |a| Engine.event(a, n0, h0, ""))
	$s = step!($s, "issue-again", |a| Engine.event(a, n0, h0, ""))
	$s = step!($s, "issue-saturated-self", |a| Engine.event(a, n0, h0, ""))
	$s = step!($s, "deliver", |a| Engine.result(a, 2, Http({ status: 200, body: "ok" })))
	$s = step!($s, "deliver-stale", |a| Engine.result(a, 2, Http({ status: 200, body: "late" })))
	$s = step!($s, "popstate", |a| Engine.result(a, 1, Location("/next")))
	$s = step!($s, "dispose-cancel", |a| Engine.event(a, t0, th0, ""))
	$s = step!($s, "deliver-cancelled", |a| Engine.result(a, 3, Http({ status: 200, body: "gone" })))
	$s = step!($s, "remount-issue", |a| Engine.event(a, t0, th0, ""))
	st = Engine.fx_stats($s.eng)
	Fuzz.mark!("issued=${st.issued.to_str()} delivered=${st.delivered.to_str()} stale=${st.stale.to_str()} refused=${st.refused.to_str()} cancelled=${st.cancelled.to_str()} live=${st.live.to_str()}")
	Fuzz.keep
}

Input : { mode : U8, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program }| {
	if mode == 0 {
		bench!({})
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
		ex("bench", 0, []),
		# issue 0 x3 (third refused + self), deliver, toggle 0 (cancel), deliver cancelled, show again
		ex("lifecycle", 1, [0, 0, 0, 0, 0, 0, 2, 1, 1, 0, 2, 2, 1, 0, 3, 7, 0, 1, 0, 2]),
		# saturate across sites, popstate, stale and never-issued ids
		ex("saturate", 1, [0, 0, 0, 1, 0, 2, 2, 3, 2, 4, 3, 5, 0, 1, 1, 1, 2, 9, 2, 255]),
	],
	generator: { mode: Fuzz.constant(1), program: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
