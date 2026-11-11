app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import KanbanApp

## Kanban Board: walks of real user events over the live DOM, two bytes per
## event, from a fresh mount, settled after every event, which must free
## everything they allocated. "walk-10k" is a seeded walk of 10,000 events.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-add-and-delete-a-card.scm`).
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(KanbanApp.program), SpecRunner.mount(Core.driver(KanbanApp.program), "/", []), Soak.session_bytes(session), Soak.settled(Core.driver(KanbanApp.program))))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "kanban-board",
	examples: [Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } })],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
