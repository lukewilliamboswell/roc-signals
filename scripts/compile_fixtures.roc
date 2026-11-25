#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.5/822J9njyNR1vgyX1KG4ck496dBx3AnLfvn2zHXn15Ksw.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
}

import src/Checks
import src/Proc

## Check declaration and default-mount fixtures without rebuilding app runners.
## Expected failures must name their rule; constant crashes must also name the
## fixture's own declaration. Must-compile cases keep unreachable code legal.
main! = |_args| {
	options = Checks.options!({ filter: "*" })?
	problems = Checks.key_type_errors!(options)?
	for problem in problems {
		Proc.warn!(problem)
	}
	if !problems.is_empty() {
		return Err(Exit(1))
	}
	Proc.note!("Compile fixtures passed")
	Ok({})
}
