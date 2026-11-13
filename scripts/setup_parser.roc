#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/ParserSource

## Prepare the pinned sibling source before compiling a dependent script.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	requested = flag(args, "--root") ?? Path.display(Env.cwd!()?)
	root = Path.display(Path.absolute!(Path.utf8(requested))?)
	_ = ParserSource.prepare!(root)?
	Ok({})
}

flag : List(Str), Str -> Try(Str, [Missing])
flag = |args, name|
	match args.find_first_index(|a| a == name) {
		Ok(i) => args.get(i + 1).map_err(|_| Missing)
		Err(_) => Err(Missing)
	}
