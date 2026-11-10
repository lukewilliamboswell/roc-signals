#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-09-9e85de7",
}

import cli.OsStr
import src/Checks
import src/Proc
import src/SpecSuite

## Run ported apps' `.scm` specs: `spec.roc -- [--browser] [--filter GLOB]
## [APP...]` (default: every ported example, natively).
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	var $browser = Bool.False
	var $filter = "*"
	var $apps = []
	var $i = 0.U64
	while $i < args.len() {
		a = args.get($i) ?? ""
		if a == "--browser" {
			$browser = Bool.True
		} else if a == "--filter" {
			$i = $i + 1
			$filter = args.get($i) ?? "*"
		} else if SpecSuite.spec_apps.contains(a) {
			$apps = $apps.append(a)
		} else {
			Proc.warn!("unknown argument ${a}; apps are ${Str.join_with(SpecSuite.spec_apps, ", ")}")
			return Err(Exit(2))
		}
		$i = $i + 1
	}
	apps = if ($apps.is_empty()) SpecSuite.spec_apps else $apps
	o = Checks.options!({ filter: $filter })?
	Checks.prepare_platform!(o)?
	if $browser {
		SpecSuite.build_web_platform!(o)?
	}
	SpecSuite.build!(o, apps, if ($browser) apps else [])?
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
