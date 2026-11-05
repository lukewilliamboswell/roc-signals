#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Slow

## The `soak` task: every fuzz target's declared examples against its
## committed allocation baseline (native soak walks, round-trip plateaus and
## bench transactions), then a long session of every app in Chrome.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	Slow.finish!("soak", Slow.soak!(o)?)
}
