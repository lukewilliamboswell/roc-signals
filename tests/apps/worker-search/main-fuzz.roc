app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import SearchApp

## Worker search as a roc-fuzz target: soaks of an app whose work runs in
## worker tasks. The walks answer pending jobs as `Soak.step` does (answered
## by the app's pure functions through the tasks' stand-ins, lost with a
## fault class, timed out, or left pending), so every answer is computed
## inside the leak check, and a function that crashes on an input the UI
## produced is a finding.
## - generated: explorer-driven walks, settled after every step (a job's
##   answer included), which must free everything they allocated.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-search-and-report.scm`).

start : {} -> SpecRunner.S(Core.App)
start = |_| SpecRunner.mount(Core.driver(SearchApp.program), "/", [])

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| Soak.walk_with(Core.driver(SearchApp.program), start({}), Soak.session_bytes(session), SearchApp.stand_in, Soak.settled(Core.driver(SearchApp.program))))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "worker-search",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
