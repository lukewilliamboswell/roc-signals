#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-07-ad3a5d2",
}

import cli.OsStr
import src/ApiDocs
import src/Checks
import src/Proc
import src/Release
import src/SpecSuite

## The `release` task: build every release asset into `dist-release/` (or
## `--output-dir DIR`) for `--version V` (default `0.0.1-dryrun`): the
## platform bundle, `runtime.mjs`, the examples archive, the API docs archive
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
