#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "../../roc-parser/package/main.roc",
	roc: "nightly-2026-11-10-f7d1f19",
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
