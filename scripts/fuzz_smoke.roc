#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.OsStr
import src/Checks
import src/FuzzPlan
import src/Proc
import src/Targets

## The `fuzz-smoke` task: every registered fuzz target's fixed examples
## (declared examples and saved regressions) on ordinary optimized native
## builds, which shows each target compiles, links and runs; nothing
## explores. `fuzz-smoke -- [TARGET...]` runs the named targets, and
## `fuzz-smoke -- --shard K/N` runs the K-th of N disjoint parts of the
## registry, as each leg of CI's Fuzz smoke job does. Every target not run
## is printed as a `SKIP` line with its reason, and the run ends with one
## line accounting for every registered target (`FuzzPlan`).
main! : List(OsStr) => Try({}, _)
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|arg| arg == "--")
	selected = match selection(args) {
		Ok(Help) => {
			Proc.note!("fuzz-smoke [TARGET... | --shard K/N]: fixed examples, plain optimized builds; default every target")
			Proc.note!("Targets: ${Str.join_with(Targets.fuzz_targets.map(|target| target.name), ", ")}")
			return Ok({})
		}
		Ok(Run(chosen)) => chosen
		Err(Unknown(name)) => {
			Proc.warn!("unknown fuzz-smoke target or option ${name}; use --help")
			return Err(Exit(2))
		}
	}
	o = Checks.options!({ filter: "*" })?
	problems = FuzzPlan.run!(Targets.fuzz_targets, selected, |fuzzes| Targets.fuzz_smoke_all!(o, fuzzes))?
	Checks.finish!("fuzz-smoke", problems)
}

## What the arguments select: help, every target, those named, or one
## shard. A name that is not a target, an option other than `--shard`, and
## a shard given with names or twice are refused; `FuzzPlan.plan` refuses a
## shard outside its total or one that would receive no target.
selection : List(Str) -> Try([Help, Run(FuzzPlan.Selection)], [Unknown(Str)])
selection = |args| match args {
	["--help"] => Ok(Help)
	[] => Ok(Run(Every))
	["--shard", text] => match FuzzPlan.parse_shard(text) {
		Ok(shard) => Ok(Run(InShard(shard)))
		Err(BadShard(bad)) => Err(Unknown("--shard ${bad}"))
	}
	names => {
		for name in names {
			if !Targets.fuzz_targets.any(|target| target.name == name) {
				return Err(Unknown(name))
			}
		}
		Ok(Run(Named(names)))
	}
}

## No arguments select every registered target, test-app targets included.
expect selection([]) == Ok(Run(Every))

## Names select those targets.
expect selection(["controls", "url", "controls"]) == Ok(Run(Named(["controls", "url", "controls"])))

## A shard is `--shard K/N`.
expect selection(["--shard", "2/6"]) == Ok(Run(InShard({ index: 2, total: 6 })))
expect selection(["--shard", "two"]) == Err(Unknown("--shard two"))
expect selection(["--shard"]) == Err(Unknown("--shard"))
expect selection(["url", "--shard", "1/2"]) == Err(Unknown("--shard"))

## A smoke command cannot accept campaign or leak-disabling options.
expect selection(["--no-detect-leaks"]) == Err(Unknown("--no-detect-leaks"))
