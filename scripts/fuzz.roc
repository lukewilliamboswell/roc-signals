#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.OsStr
import cli.Path
import src/Checks
import src/Proc
import src/Targets

## The `fuzz` task, a campaign: `fuzz.roc -- [--time SECONDS] [--timeout
## SECONDS] [TARGET...]` (default: every roc-fuzz target, 600 seconds of
## exploration each, and a 300-second timeout per input: an app target's
## inputs are whole sessions, leak-checked, and take seconds each). Each target explores
## (roc-fuzz `explore`; its declared examples are `check`'s and
## `check-slow`'s job) from its corpus under `.fuzz-out/<target>/corpus`
## (kept between campaigns, and in CI by the Actions cache) and writes its
## roc-fuzz report, findings included, to `.fuzz-out/<target>/report`. A target that finds a failure
## fails the task; reduce the finding to a `Fuzz.saved` example beside the
## target so `check` replays it.
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
	selected = if ($names.is_empty()) Targets.fuzz_targets else Targets.fuzz_targets.keep_if(|t| $names.contains(t.name))
	Checks.prepare_platform!(o)?
	Targets.build_fuzz_all!(o, selected)?
	var $failed = []
	for t in selected {
		out = "${o.root}/.fuzz-out/${t.name}"
		Path.create_all!(Path.utf8("${out}/corpus"))?
		report = "${out}/report"
		if Path.exists!(Path.utf8(report))? {
			Path.delete_all!(Path.utf8(report))?
		}
		Proc.note!("== fuzz ${t.name} (${$time} s)")
		code = Proc.status!({ program: Targets.exe_of(o, t), args: ["explore", "${out}/corpus", "--time=${$time}", "--timeout=${$timeout}", "--report-dir=${report}", "--print-final-stats"], cwd: out })?
		if code != 0 {
			$failed = $failed.append("fuzz ${t.name}: exited with ${code.to_str()}; see ${report}")
		}
	}
	for f in $failed {
		Proc.warn!("FAIL ${f}")
	}
	if ($failed.is_empty()) Ok({}) else Err(Exit(1))
}
