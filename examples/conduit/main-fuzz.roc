app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import ConduitApp

## Conduit on the engine (its specs run through `main.roc`).

## One body that satisfies every RealWorld envelope the app decodes (each
## decoder reads its own key): the soak's answer to every request.
universal : Str
universal = "{\"articles\":[{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1,\"article\":{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}},\"tags\":[\"roc\",\"signals\"],\"comments\":[{\"id\":1,\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"body\":\"c\",\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"profile\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false},\"user\":{\"email\":\"kim@conduit.test\",\"token\":\"jwt.kim\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}"

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

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(ConduitApp.program), answer(SpecRunner.mount(Core.driver(ConduitApp.program), home, [])), Soak.session_bytes(session), answered))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "conduit",
	examples: [
		Fuzz.example({ name: "walk-2k-s1", revision: "1", make: || { program: [], seed: 1, steps: 2000 } }),
		Fuzz.example({ name: "walk-2k-s2", revision: "1", make: || { program: [], seed: 2, steps: 2000 } }),
		Fuzz.example({ name: "walk-2k-s3", revision: "1", make: || { program: [], seed: 3, steps: 2000 } }),
		Fuzz.example({ name: "walk-2k-s4", revision: "1", make: || { program: [], seed: 4, steps: 2000 } }),
		Fuzz.example({ name: "walk-2k-s5", revision: "1", make: || { program: [], seed: 5, steps: 2000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
