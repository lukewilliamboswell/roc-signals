#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Slow

## The `mutate` task: build each fuzz target against a deliberately broken
## engine (scripts/src/Mutations.roc); every mutant must be rejected.
## `mutate.roc -- NAME` runs one mutation.
main! = |args| {
	only = match args {
		[Utf8(name), ..] => name
		_ => ""
	}
	o = Checks.options!({ pending_phase3: Bool.True, filter: "*" })?
	Slow.finish!("mutate", Slow.mutate!(o, only)?)
}
