#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks

## Fetch and build the platform's native inputs: the spec runner's `spec.o`
## and libc, and the fuzz platform's roc-fuzz host (see `src/PlatformTest.roc`).
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	Checks.prepare_platform!(o)
}
