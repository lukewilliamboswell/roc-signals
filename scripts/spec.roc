#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import src/Checks
import src/Proc
import src/SpecSuite

## Run ported apps' `.scm` specs: `spec.roc -- [--browser] [--strict]
## [--filter GLOB] [APP...]` (default: every ported example, natively).
##
## `--strict` runs work assertions as the failures they are until Phase 3
## adds the engine's counters; by default they are counted as pending-phase3.
main! = |raw_args| {
	args = raw_args.keep_oks(
		|a|
			match a {
				Utf8(s) => Ok(s)
				_ => Err(NotUtf8)
			},
	)
	var $browser = Bool.False
	var $strict = Bool.False
	var $filter = "*"
	var $apps = []
	var $i = 0.U64
	while $i < args.len() {
		a = args.get($i) ?? ""
		if a == "--browser" {
			$browser = Bool.True
		} else if a == "--strict" {
			$strict = Bool.True
		} else if a == "--filter" {
			$i = $i + 1
			$filter = args.get($i) ?? "*"
		} else if SpecSuite.apps.contains(a) {
			$apps = $apps.append(a)
		} else {
			Proc.warn!("unknown argument ${a}; apps are ${Str.join_with(SpecSuite.apps, ", ")}")
			return Err(Exit(2))
		}
		$i = $i + 1
	}
	apps = if ($apps.is_empty()) SpecSuite.apps else $apps
	o = Checks.options!({ pending_phase3: !$strict, filter: $filter })?
	Checks.prepare_platform!(o)?
	if $browser {
		SpecSuite.build_web_platform!(o)?
	}
	var $problems = []
	for example in apps {
		r = Checks.run_app!(o, example, $browser)?
		$problems = $problems.concat(r.native.problems).concat(r.browser.problems)
	}
	for p in $problems {
		Proc.warn!("FAIL ${p}")
	}
	if ($problems.is_empty()) Ok({}) else Err(Exit(1))
}
