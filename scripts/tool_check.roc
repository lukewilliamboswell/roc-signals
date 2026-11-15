#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3/FTL1xt1rA9nXzoYkhFAW9yF75Kn52bS3cpBr7wZNfPq2.tar.zst",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.OsStr
import src/Checks
import src/Proc
import src/ToolCheck

## One scenario of the `signals.roc` tool's end-to-end check
## (`ToolCheck.scenarios`), run from the dry run's copy of the tool that
## `check`'s release stage made: `tool_check.roc SCENARIO`. `check` builds
## this script once and runs every scenario as its own process, in
## parallel (`ToolCheck.run!`); run it by hand to repeat one. Its problems
## are printed as `FAIL` lines and fail it.
main! : List(OsStr) => Try({}, _)
main! = |raw_args| {
	match raw_args.map(OsStr.display).drop_if(|arg| arg == "--") {
		[name] if ToolCheck.scenarios.contains(name) => {
			o = Checks.options!({ filter: "*" })?
			problems = ToolCheck.scenario!(o, name)?
			Checks.finish!("signals.roc ${name}", problems)
		}
		_ => {
			Proc.warn!("usage: tool_check.roc SCENARIO, one of ${Str.join_with(ToolCheck.scenarios, ", ")}")
			Err(Exit(2))
		}
	}
}
