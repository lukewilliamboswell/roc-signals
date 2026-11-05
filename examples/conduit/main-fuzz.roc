app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import ConduitApp
import Bench

## Conduit on the engine (its specs run through `main-test.roc`).
## - "bench-N": the Bench scenario with N feed articles, one measured
##   region per engine transaction (exact allocation baselines).

measured! : SpecRunner.S(Engine.App), Str, (Engine.App -> Engine.App) => SpecRunner.S(Engine.App)
measured! = |st, name, f| {
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(f(st.inst), [])
	_ = w.finish!()
	SpecRunner.take_batch(st, a, c)
}

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	view = ConduitApp.main(Bench.boot)
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount_with(32, view), [])
	_ = w.finish!()
	var $st = Bench.start_from(a0, c0)
	tags_id = Bench.id_of($st, 2)
	$st = measured!($st, "tags", |a| Engine.result(a, tags_id, Http({ status: 200, headers: [], body: Bench.tags_json })))
	feed_id = Bench.id_of($st, 1)
	feed = Bench.feed_json(n)
	$st = measured!($st, "feed", |a| Engine.result(a, feed_id, Http({ status: 200, headers: [], body: feed })))
	(fn, fh) = Bench.click_target($st, Role({ role: "button", name: Bench.favorite_label(n) }))
	$st = measured!($st, "favorite", |a| Engine.event(a, fn, fh, ""))
	fav_id = Bench.id_of($st, 3)
	resp = Bench.favorite_response(n)
	$st = measured!($st, "favorite-response", |a| Engine.result(a, fav_id, Http({ status: 200, headers: [], body: resp })))
	_ = Bench.expect_visible($st, Role({ role: "button", name: "Unfavorite Article ${Bench.mid(n).to_str()} (${(Bench.mid(n) % 5 + 1).to_str()})" }))
	(tn, th) = Bench.click_target($st, Role({ role: "link", name: "signals" }))
	$st = measured!($st, "tag-click", |a| Engine.event(a, tn, th, ""))
	if $st.browser.loc != "/roc-signals/examples/conduit/#/?tag=signals" {
		crash "bench: tag click went to ${$st.browser.loc}"
	}
	Fuzz.keep
}

## One body that satisfies every RealWorld envelope the app decodes (each
## decoder reads its own key): the soak's answer to every request.
universal : Str
universal = "{\"articles\":[{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1,\"article\":{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}},\"tags\":[\"roc\",\"signals\"],\"comments\":[{\"id\":1,\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"body\":\"c\",\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"profile\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false},\"user\":{\"email\":\"kim@conduit.test\",\"token\":\"jwt.kim\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}"

## Answer every in-flight request (id 1 is the popstate subscription), a few
## rounds deep (an answer may issue more requests).
answer_app : Engine.App, List(U8) -> (Engine.App, List(U8))
answer_app = |a0, b0| {
	var $a = a0
	var $b = b0
	var $round = 0.U64
	while $round < 4 {
		ids = Engine.fx_live($a).keep_if(|id| id != 1)
		for id in ids {
			(a1, b1) = Engine.take_cmds(Engine.result($a, id, Http({ status: 200, headers: [], body: universal })), $b)
			$a = a1
			$b = b1
		}
		$round = $round + 1
	}
	($a, $b)
}

## The same, keeping the DOM model in step.
answer : SpecRunner.S(Engine.App) -> SpecRunner.S(Engine.App)
answer = |s0| {
	var $s = s0
	var $round = 0.U64
	while $round < 4 {
		ids = Engine.fx_live($s.inst).keep_if(|id| id != 1)
		for id in ids {
			(a1, c) = Engine.take_cmds(Engine.result($s.inst, id, Http({ status: 200, headers: [], body: universal })), [])
			$s = SpecRunner.take_batch($s, a1, c)
		}
		$round = $round + 1
	}
	$s
}

home : Str
home = "/roc-signals/examples/conduit/#/"

cycle : List(Scm.Op)
cycle = [Click(Role({ role: "link", name: "Sign in" })), Click(Role({ role: "link", name: "Home" }))]

## Soak, mode 2: explorer-driven walk with every request answered; leak-free.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(ConduitApp.program, answer(SpecRunner.mount(ConduitApp.program, home, [])), program, answer))
	Fuzz.keep
}

## Soak, mode 3: 2,000 seeded events per example (five examples, seeds 1-5:
## 10k events; one 10k walk exceeds the per-input timeout through the DOM
## oracle), leak-checked, then Home -> Sign in -> Home 48 times on the
## engine alone: live allocations flat.
soak_10k! : U64 => Fuzz.Outcome
soak_10k! = |seed| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(ConduitApp.program, answer(SpecRunner.mount(ConduitApp.program, home, [])), seed, 2000, answer))
	(s1, evs) = Soak.triples(ConduitApp.program, answer(SpecRunner.mount(ConduitApp.program, home, [])), cycle, answer)
	counts = Soak.replay!(ConduitApp.program, s1.inst, evs, 48, answer_app, begin!, net_bytes!)
	match Soak.flat(counts, 2) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle net live bytes ${Str.inspect(counts.sublist({ start: 0, len: 4 }))} ... (${counts.len().to_str()} cycles)")
	Fuzz.keep
}

Input : { mode : U8, size : U64, program : List(U8) }

## Soak probes: a measured region around one cycle; its net live bytes.
begin! : {} => Fuzz.Measurement
begin! = |_| Fuzz.start_measure!("cycle")

net_bytes! : Fuzz.Measurement => I64
net_bytes! = |w| {
	stats = w.finish!()
	stats.exit_live_bytes.to_i64_wrap() - stats.entry_live_bytes.to_i64_wrap()
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, program }| {
	if mode == 0 {
		if (size > 1000) Fuzz.reject else bench!(size)
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!(size)
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "conduit",
	examples: [
		ex("soak-2k-s1", 3, 1),
		ex("soak-2k-s2", 3, 2),
		ex("soak-2k-s3", 3, 3),
		ex("soak-2k-s4", 3, 4),
		ex("soak-2k-s5", 3, 5),
		ex("bench-20", 0, 20),
		ex("bench-200", 0, 200),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
