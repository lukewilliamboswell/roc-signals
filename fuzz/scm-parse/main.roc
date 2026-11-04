app [target] {
	pf: platform "../../platform-test/main.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import ts.Scm

## The `.scm` parser is total: any text either parses or is refused with a
## position inside the text. A parsed spec has a name, at least one step, and
## every step's position lies inside the text.
test : Str -> Fuzz.Outcome
test = |text| {
	lines = text.split_on("\n").len()
	inside = |pos| pos.line >= 1 and pos.line <= lines and pos.column >= 1
	match Scm.parse(text) {
		Ok(spec) if spec.steps.is_empty() => crash "a parsed spec has no steps"
		Ok(spec) if !spec.steps.all(|s| inside(s.pos)) => crash "a step position lies outside the text"
		Ok(_) => Fuzz.keep
		Err(problem) if !inside(problem.pos) => crash "a parse error points outside the text: ${Str.inspect(problem)}"
		Err(_) => Fuzz.keep
	}
}

target = Fuzz.target_with({
	examples: [
		Fuzz.example({ name: "minimal", revision: "1", make: || "(test \"t\" (steps (click (text \"a\"))))" }),
		Fuzz.example({ name: "setup-and-stub", revision: "1", make: || "(test \"t\" (setup (manual-effects) (initial-location \"/x\")) (steps (stub-http \"s\" :url \"/a\" :status 200 :body \"{}\") (run-effect 1)))" }),
		Fuzz.example({ name: "unterminated", revision: "1", make: || "(test \"t\" (steps" }),
	],
	name: "scm-parse",
	generator: Fuzz.str,
	test,
	show: |text| Str.inspect(text),
})
