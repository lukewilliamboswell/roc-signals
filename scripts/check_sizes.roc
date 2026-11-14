#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Checks
import src/Proc
import src/Sizes
import src/SpecSuite

## Check shipped JavaScript and report the shipping modules. The runtime-only
## form needs no platform build and prints the figures for a source review.
main! : List(OsStr) => Try({}, _)
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|arg| arg == "--")
	if args != [] and args != ["--runtime-only"] {
		Proc.warn!("usage: sizes -- [--runtime-only]")
		return Err(Exit(2))
	}
	root = Path.display(Env.cwd!()?)
	var $problems = Sizes.check_runtime!({ root, node: "node" })?
	if args.is_empty() {
		o = Checks.options!({ filter: "*" })?
		SpecSuite.build_web_platform!(o)?
		$problems = $problems.concat(Sizes.report!(o)?)
	}
	for problem in $problems {
		Proc.warn!("FAIL ${problem}")
	}
	if $problems.is_empty() {
		Ok({})
	} else {
		Err(Exit(1))
	}
}
