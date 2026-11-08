#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-07-ad3a5d2",
}

import src/Checks

## Fetch and build the platform's native inputs: the spec runner's `spec.o`
## and libc, and the fuzz platform's roc-fuzz host (see `src/PlatformTest.roc`).
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	Checks.prepare_platform!(o)
}
