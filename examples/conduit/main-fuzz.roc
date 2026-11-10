app [target] { pf: platform "../../platform/fuzz.roc" }

import pf.Core
import pf.Fuzz
import pf.Dom
import pf.Scm
import pf.Soak
import pf.SpecRunner
import ConduitApp

## Conduit on the engine (its specs run through `main.roc`).

## One body that satisfies every RealWorld envelope the app decodes (each
## decoder reads its own key): the soak's answer to every request.
universal : Str
universal = "{\"articles\":[{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1,\"article\":{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}},\"tags\":[\"roc\",\"signals\"],\"comments\":[{\"id\":1,\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"body\":\"c\",\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"profile\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false},\"user\":{\"email\":\"kim@conduit.test\",\"token\":\"jwt.kim\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}"

## Answer every in-flight request (id 1 is the popstate subscription), a few
## rounds deep (an answer may issue more requests).
answer_app : Core.App, List(U8) -> (Core.App, List(U8))
answer_app = |a0, b0| {
	var $a = a0
	var $b = b0
	var $round = 0.U64
	while $round < 4 {
		ids = Core.fx_live($a).keep_if(|id| id != 1)
		for id in ids {
			(a1, b1) = Core.take_cmds(Core.result($a, id, Http({ status: 200, headers: [], body: universal })), $b)
			$a = a1
			$b = b1
		}
		$round = $round + 1
	}
	($a, $b)
}

## The same, keeping the DOM model in step.
answer : SpecRunner.S(Core.App) -> SpecRunner.S(Core.App)
answer = |s0| {
	var $s = s0
	var $round = 0.U64
	while $round < 4 {
		ids = Core.fx_live($s.inst).keep_if(|id| id != 1)
		for id in ids {
			(a1, c) = Core.take_cmds(Core.result($s.inst, id, Http({ status: 200, headers: [], body: universal })), [])
			$s = SpecRunner.take_batch($s, a1, c)
		}
		$round = $round + 1
	}
	$s
}

## A walk's `after` hook: answer what is pending, then the settle check.
answered : SpecRunner.S(Core.App) -> SpecRunner.S(Core.App)
answered = |s| Soak.settled(Core.driver(ConduitApp.program))(answer(s))

home : Str
home = "/roc-signals/examples/conduit/#/"

cycle : List(Scm.Op)
cycle = [Click(Role({ role: "link", name: "Sign in" })), Click(Role({ role: "link", name: "Home" }))]

## Soak, mode 2: explorer-driven walk with every request answered; leak-free.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(ConduitApp.program), answer(SpecRunner.mount(Core.driver(ConduitApp.program), home, [])), program, answered))
	Fuzz.keep
}

## Soak, mode 3: 2,000 seeded events per example (five examples, seeds 1-5:
## 10k events; one 10k walk exceeds the per-input timeout through the DOM
## oracle), settle-checked and leak-checked, then Home -> Sign in -> Home 48 times on the
## engine alone: live allocations flat.
soak_10k! : U64 => Fuzz.Outcome
soak_10k! = |seed| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Core.driver(ConduitApp.program), answer(SpecRunner.mount(Core.driver(ConduitApp.program), home, [])), seed, 2000, answered))
	(s1, evs) = Soak.triples(Core.driver(ConduitApp.program), answer(SpecRunner.mount(Core.driver(ConduitApp.program), home, [])), cycle, answered)
	counts = Soak.replay!(Core.driver(ConduitApp.program), s1.inst, evs, 48, answer_app, begin!, net_bytes!)
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
	if mode == 2 {
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
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
