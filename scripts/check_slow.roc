#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-09-9e85de7",
}

import src/Checks
import src/Slow

## The `check-slow` task: what takes too long for every pull request, the
## soak: every fuzz target's declared examples (leak-checked native soak
## walks with flat round trips), and a long session of every app in Chrome.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	problems = Slow.soak!(o)?
	Slow.finish!("check-slow", problems)
}
