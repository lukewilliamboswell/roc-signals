app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import MdApp

## Markdown Editor: walks of real user events over the live DOM, two bytes per
## event, from a fresh mount, settled after every event, which must free
## everything they allocated. The examples are five seeded walks of 2,000 events (seeds 1 to
## 5): one walk of 10,000 exceeds the per-input timeout through the DOM
## oracle.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-load-two-documents.scm`).
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(MdApp.program), SpecRunner.mount(Core.driver(MdApp.program), "/", []), Soak.session_bytes(session), Soak.settled(Core.driver(MdApp.program))))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "markdown-editor",
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
