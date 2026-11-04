#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import cli.OsStr
import src/Checks
import src/Proc
import src/Targets

## The `fuzz-accept` task: accept every fuzz target's exact allocation
## observations as its committed baseline (fuzz/baselines/). This is a review
## step: run it on purpose, read the diff, and commit it. CI never runs it.
## `fuzz_accept.roc -- NAME` accepts one target.
main! = |args| {
	only = match args.map(OsStr.display).drop_if(|s| s == "--") {
		[name, ..] => name
		_ => ""
	}
	o = Checks.options!({ pending_phase3: Bool.True, filter: "*" })?
	Checks.prepare_platform!(o)?
	for t in Targets.fuzz_targets.keep_if(|t| only == "" or t.name == only) {
		exe = Targets.build_fuzz!(o, t)?
		Targets.fuzz_accept!(o, t, exe)?
		Proc.note!("accepted ${Targets.baseline(t.name)}")
	}
	Ok({})
}
