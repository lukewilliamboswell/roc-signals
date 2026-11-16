#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3/FTL1xt1rA9nXzoYkhFAW9yF75Kn52bS3cpBr7wZNfPq2.tar.zst",
	roc: "nightly-2026-11-14-a87808d",
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
## files; `check` builds them too, as the dry run. A version `X.Y.Z` must also
## be at least the bump the API's changes since the latest release require;
## a prerelease or the dry run is not compared here, as `check` compares
## every pull request.
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
	built = Release.build!(o, version, out)?
	problems = match api_claim(version) {
		Release(number) => Checks.gather!(built, ApiDocs.bump!(o, Release(number)))?
		Unchecked => built
	}
	site = Checks.hold!(problems, ApiDocs.build!(o, version))?
	Checks.hold!(problems, Proc.run!({ program: "zip", args: ["-q", "-r", "-X", "${out}/roc-signals-docs-${version}.zip", "."], cwd: site }))?
	Checks.finish!("release", problems)
}

## A plain `X.Y.Z` is a release whose number the API comparison holds to
## the bump its changes require; a prerelease (`0.6.0-rc.1`) or the dry run
## (`0.0.1-dryrun`) claims no such number.
api_claim : Str -> [Release(Str), Unchecked]
api_claim = |version| {
	parts = version.split_on(".")
	if parts.len() == 3 and parts.all(|part| !part.is_empty() and part.to_utf8().all(|byte| byte >= '0' and byte <= '9')) {
		Release(version)
	} else {
		Unchecked
	}
}

## Only a plain release number is held to the API comparison.
expect ["0.6.0", "0.6.0-rc.1", "0.0.1-dryrun", "1.2", "1..3"].map(api_claim) == [Release("0.6.0"), Unchecked, Unchecked, Unchecked, Unchecked]

## The value after `name` in the arguments.
flag : List(Str), Str -> Try(Str, [Missing])
flag = |args, name|
	match args.find_first_index(|a| a == name) {
		Ok(i) => args.get(i + 1).map_err(|_| Missing)
		Err(_) => Err(Missing)
	}
