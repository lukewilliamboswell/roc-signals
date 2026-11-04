#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Slow

## The `check-slow` task: what takes too long for every pull request, the
## soak: every fuzz target's declared examples against its committed exact
## allocation baseline (the native soak walks and the bench transactions),
## and a long session of every app in Chrome.
main! = |_args| {
	o = Checks.options!({ pending_phase3: Bool.True, filter: "*" })?
	problems = Slow.soak!(o)?
	Slow.finish!("check-slow", problems)
}
