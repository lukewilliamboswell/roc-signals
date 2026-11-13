#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.OsStr
import src/Checks
import src/Proc
import src/Targets

## Run actual roc-fuzz fixed examples on ordinary optimized native builds.
## No names selects every maintained target, including test-app targets.
## Covered checks and campaigns keep their separate builds and defaults.
main! : List(OsStr) => Try({}, _)
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|arg| arg == "--")
	selected = match selection(args) {
		Ok(Help) => {
			Proc.note!("fuzz-smoke [TARGET...]: actual fixed examples, plain optimized builds; default all targets")
			Proc.note!("Targets: ${Str.join_with(Targets.fuzz_targets.map(|target| target.name), ", ")}")
			return Ok({})
		}
		Ok(Run(targets)) => targets
		Err(UnknownTarget(name)) => {
			Proc.warn!("unknown fuzz-smoke target or option ${name}; use --help")
			return Err(Exit(2))
		}
	}
	o = Checks.options!({ filter: "*" })?
	problems = Targets.fuzz_smoke_all!(o, selected)?
	for problem in problems {
		Proc.warn!("FAIL ${problem}")
	}
	if problems.is_empty() {
		Proc.note!("fuzz-smoke: all ${selected.len().to_str()} selected targets passed")
		Ok({})
	} else {
		Err(Exit(1))
	}
}

selection : List(Str) -> Try([Help, Run(List(Targets.Fuzz))], [UnknownTarget(Str)])
selection = |names| {
	if names == ["--help"] { return Ok(Help) }
	for name in names {
		if !Targets.fuzz_targets.any(|target| target.name == name) {
			return Err(UnknownTarget(name))
		}
	}
	Ok(Run(if names.is_empty() { Targets.fuzz_targets } else { Targets.fuzz_targets.keep_if(|target| names.contains(target.name)) }))
}

## The default includes the complete registry, including test-app targets.
expect {
	match selection([]) {
		Ok(Run(targets)) => targets == Targets.fuzz_targets and targets.any(|target| target.name == "controls") and targets.any(|target| target.name == "fx-channel")
		_ => False
	}
}

## Selection keeps registry order and checks a repeated target only once.
expect {
	match selection(["controls", "url", "controls"]) {
		Ok(Run(targets)) => targets.map(|target| target.name) == ["url", "controls"]
		_ => False
	}
}

## A smoke command cannot accept campaign or leak-disabling options.
expect {
	match selection(["--no-detect-leaks"]) {
		Err(UnknownTarget("--no-detect-leaks")) => True
		_ => False
	}
}
