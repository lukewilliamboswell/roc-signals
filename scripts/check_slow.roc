#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Slow

## The `check-slow` task: what takes too long for every pull request. The
## soak (every fuzz target's declared examples against its committed exact
## allocation baseline, which include the native soak walks and the bench
## transactions, and a long session of every app in Chrome) and the engine
## mutation gate.
main! = |_args| {
	o = Checks.options!({ pending_phase3: Bool.True, filter: "*" })?
	problems = Slow.soak!(o)?.concat(Slow.mutate!(o, "")?)
	Slow.finish!("check-slow", problems)
}
