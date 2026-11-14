#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import src/Checks
import src/Slow

## The `check-slow` task: what takes too long for every pull request:
## every fuzz target's declared examples, a long seeded walk of every app
## in its native spec runner (settled after every step, leaving nothing
## allocated), the native soak of each app's round-trip spec (flat live
## allocations and bytes), and a long session of every app in Chrome.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	problems = Slow.soak!(o)?
	Slow.finish!("check-slow", problems)
}
