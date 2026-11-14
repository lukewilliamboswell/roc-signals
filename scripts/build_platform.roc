#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import src/Checks

## Fetch and build the platform's native inputs: the spec runner's `spec.o`
## and libc (see `src/PlatformTest.roc`).
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	Checks.prepare_platform!(o)
}
