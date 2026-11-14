#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.2/2H2hePe5iYTZaGdG9MbMqhS29yg4Zxxr7dPEbZJ96fME.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.OsStr
import src/ApiDocs
import src/Checks
import src/Proc
import src/Release
import src/SpecSuite

## The `release` task: build every release asset into `dist-release/` (or
## `--output-dir DIR`) for `--version V` (default `0.0.1-dryrun`): the
## platform bundle, `runtime.mjs` and `worker.mjs`, the `signals.roc` tool
## (its package and app), the examples archive, the API docs archive
## and the draft release notes. The release workflow publishes exactly these
## files; `check` builds them too, as the dry run.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	version = flag(args, "--version") ?? "0.0.1-dryrun"
	o = Checks.options!({ filter: "*" })?
	out = match flag(args, "--output-dir") {
		Ok(dir) if dir.starts_with("/") => dir
		Ok(dir) => "${o.root}/${dir}"
		Err(_) => "${o.root}/dist-release"
	}
	# The examples compile against `platform/targets`, which a fresh checkout
	# does not have; prepare both targets' inputs first, as `check` does.
	Checks.prepare_platform!(o)?
	SpecSuite.build_web_platform!(o)?
	SpecSuite.build!(o, [], SpecSuite.apps)?
	problems = Release.build!(o, version, out)?
	site = ApiDocs.build!(o, version)?
	Proc.run!({ program: "zip", args: ["-q", "-r", "-X", "${out}/roc-signals-docs-${version}.zip", "."], cwd: site })?
	for p in problems {
		Proc.warn!("FAIL ${p}")
	}
	if (problems.is_empty()) Ok({}) else Err(Exit(1))
}

## The value after `name` in the arguments.
flag : List(Str), Str -> Try(Str, [Missing])
flag = |args, name|
	match args.find_first_index(|a| a == name) {
		Ok(i) => args.get(i + 1).map_err(|_| Missing)
		Err(_) => Err(Missing)
	}
