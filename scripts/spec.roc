#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.OsStr
import src/Checks
import src/Proc
import src/SpecSuite

## Run apps' `.scm` specs: `spec.roc -- [--browser] [--filter GLOB]
## [--target TARGET] [APP...]` (default: every example and test app,
## natively). The native runners are built for TARGET, one of
## `SpecSuite.native_targets`; without it, for the system this runs on as
## `uname -sm` names it, and for `x64musl` where that names no system the
## runner builds for. The pull-request gate (`check_all.roc`) always builds
## for `x64musl`.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	var $browser = Bool.False
	var $filter = "*"
	var $apps = []
	var $target = ""
	var $i = 0.U64
	while $i < args.len() {
		a = args.get($i) ?? ""
		if a == "--browser" {
			$browser = Bool.True
		} else if a == "--filter" {
			$i = $i + 1
			$filter = args.get($i) ?? "*"
		} else if a == "--target" {
			$i = $i + 1
			$target = args.get($i) ?? ""
			if !SpecSuite.native_targets.contains($target) {
				Proc.warn!("--target takes one of ${Str.join_with(SpecSuite.native_targets, ", ")}")
				return Err(Exit(2))
			}
		} else if SpecSuite.spec_apps.contains(a) {
			$apps = $apps.append(a)
		} else {
			Proc.warn!("unknown argument ${a}; apps are ${Str.join_with(SpecSuite.spec_apps, ", ")}")
			return Err(Exit(2))
		}
		$i = $i + 1
	}
	apps = if ($apps.is_empty()) SpecSuite.spec_apps else $apps
	target =
		if $target.is_empty() {
			uname = Proc.capture!({ program: "uname", args: ["-sm"], cwd: "." }) ?? []
			SpecSuite.host_target(Str.from_utf8_lossy(uname)) ?? "x64musl"
		} else {
			$target
		}
	o = { ..Checks.options!({ filter: $filter })?, target }
	Proc.note!("native spec runners: ${target}")
	Checks.prepare_platform!(o)?
	if $browser {
		SpecSuite.build_web_platform!(o)?
	}
	SpecSuite.build!(o, apps, if ($browser) apps else [])?
	var $problems = []
	for example in apps {
		r = Checks.hold!($problems, Checks.run_app!(o, example, $browser))?
		$problems = $problems.concat(r.native.problems).concat(r.browser.problems)
	}
	Checks.finish!("spec", $problems)
}
