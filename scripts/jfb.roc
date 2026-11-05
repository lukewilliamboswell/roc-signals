#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Slow
import src/SpecSuite
import src/Targets

## The `jfb` task: build the js-framework-benchmark app
## (benchmarks/js-framework-benchmark/roc-signals-keyed/dist) and check its
## keyed operations in Chrome.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	SpecSuite.build_web_platform!(o)?
	Slow.finish!("jfb", Targets.jfb!(o)?)
}
