#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import src/Checks
import src/Slow
import src/SpecSuite
import src/Targets

## The `workers-scaling` task: build the Worker Lab with `--opt=size`, with
## and without `--specialize=no`, and run the full worker scaling
## measurement on each in Chrome (tests/browser/workers-scaling.mjs). Its
## timing assertions adapt to the machine's core count; run it on a quiet
## machine with several cores, and paste its tables into the pull request.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	SpecSuite.build_web_platform!(o)?
	Slow.finish!("workers-scaling", Targets.workers_scaling!(o)?)
}
