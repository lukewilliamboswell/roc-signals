#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
}

import cli.OsStr
import cli.Path
import src/Checks
import src/FuzzPlan
import src/Proc
import src/SpecSuite
import src/Targets

## The `fuzz` task, a campaign, run on a contributor's machine and never
## in CI: `fuzz.roc -- [--time SECONDS] [--timeout SECONDS] [TARGET...]`
## (default: every roc-fuzz target, 600 seconds of exploration each, and a
## 300-second timeout per input: an app target's inputs are whole sessions,
## leak-checked, and take seconds each). Each target is built instrumented
## and explores (roc-fuzz `explore`; its fixed examples are `check`'s and
## `check-slow`'s job) from its corpus under `.fuzz-out/<target>/corpus`,
## kept between campaigns on that machine, and writes its roc-fuzz report,
## findings included, to `.fuzz-out/<target>/report`. A target that does
## not build, or finds a failure, fails the task; reduce a finding to a
## `Fuzz.saved` example beside the target so every replay keeps it fixed.
## Targets not named are printed as `SKIP` lines, and the run ends with one
## line accounting for every registered target (`FuzzPlan`).
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	var $time = "600"
	var $timeout = "300"
	var $names = []
	var $i = 0.U64
	while $i < args.len() {
		a = args.get($i) ?? ""
		if a == "--time" {
			$i = $i + 1
			$time = args.get($i) ?? ""
		} else if a == "--timeout" {
			$i = $i + 1
			$timeout = args.get($i) ?? ""
		} else if Targets.fuzz_targets.any(|t| t.name == a) {
			$names = $names.append(a)
		} else {
			Proc.warn!("unknown argument ${a}; targets are ${Str.join_with(Targets.fuzz_targets.map(|t| t.name), ", ")}")
			return Err(Exit(2))
		}
		$i = $i + 1
	}
	if (U64.from_str($time) ?? 0) == 0 or (U64.from_str($timeout) ?? 0) == 0 {
		Proc.warn!("--time and --timeout take a positive number of seconds, got ${$time} and ${$timeout}")
		return Err(Exit(2))
	}
	o = Checks.options!({ filter: "*" })?
	selection = if ($names.is_empty()) Every else Named($names)
	# Published roc-fuzz supplies the pure targets' native link inputs.
	problems = FuzzPlan.run!(Targets.fuzz_targets, selection, |selected| campaign!(o, selected, { time: $time, timeout: $timeout }))?
	Checks.finish!("fuzz", problems)
}

## Build the selected targets instrumented and explore each one that
## built. One outcome per target: the failed builds', then the campaigns'.
campaign! : SpecSuite.Options, List(Targets.Fuzz), { time : Str, timeout : Str } => Try(List(FuzzPlan.Outcome), _)
campaign! = |o, selected, limits| {
	built = Targets.build_fuzz_all!(o, selected)?
	var $outcomes = built.keep_if(|b| !b.problems.is_empty())
	for t in selected {
		if built.any(|b| b.name == t.name and b.problems.is_empty()) {
			found = Checks.hold!($outcomes.map(|outcome| outcome.problems).join(), explore!(o, t, limits))?
			$outcomes = $outcomes.append({ name: t.name, problems: found })
		}
	}
	Ok($outcomes)
}

## Explore one target from its kept corpus into a fresh report. A target
## that finds a failure is a problem; one that cannot be started aborts the
## campaign, after the findings of the targets before it are printed.
explore! : SpecSuite.Options, Targets.Fuzz, { time : Str, timeout : Str } => Try(List(Str), _)
explore! = |o, t, { time, timeout }| {
	out = "${o.root}/.fuzz-out/${t.name}"
	Path.create_all!(Path.utf8("${out}/corpus"))?
	report = "${out}/report"
	if Path.exists!(Path.utf8(report))? {
		Path.delete_all!(Path.utf8(report))?
	}
	Proc.note!("== fuzz ${t.name} (${time} s)")
	code = Proc.status!({ program: Targets.exe_of(o, t), args: ["--target=${t.name}", "explore", "${out}/corpus", "--time=${time}", "--timeout=${timeout}", "--report-dir=${report}", "--print-final-stats"], cwd: out })?
	Ok(if (code == 0) [] else ["fuzz ${t.name}: exited with ${code.to_str()}; see ${report}"])
}
