app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import Notes
import NotesApp

## Field Notes on the Roc-owned engine (its specs run through
## `main.roc`).
## - generated: explorer-driven random walks over the live DOM, with every
##   sync request answered, which must free everything they allocated.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-draft-filter-and-reorder.scm`).

St : SpecRunner.S(Core.App)

## Two restored notes: one queued, one draft.
storage : List({ key : Str, value : Str })
storage = [{ key: Notes.notes_key, value: "n0|0|1|r7|Generator hours;n1|1|0|r7|Fence line check" }]

start : {} -> St
start = |_| SpecRunner.mount(Core.driver(NotesApp.program), "/", storage)

## Answer every pending sync request as the server would (it echoes the
## token), a few rounds deep: a settled sync starts the next one.
answer : St -> St
answer = |s0| {
	var $s = s0
	var $round = 0.U64
	while $round < 4 {
		for p in $s.browser.pending {
			b = $s.browser
			$s = SpecRunner.deliver(Core.driver(NotesApp.program), { ..$s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != p.id) } }, p.id, SpecRunner.encode_http(200, [], p.body))
		}
		$round = $round + 1
	}
	$s
}

## A walk's `after` hook: answer what is pending, then the settle check.
answered : St -> St
answered = |s| Soak.settled(Core.driver(NotesApp.program))(answer(s))

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(NotesApp.program), answer(start({})), Soak.session_bytes(session), answered))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "field-notes",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
