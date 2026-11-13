#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "../../roc-parser/package/main.roc",
	roc: "nightly-2026-11-10-f7d1f19",
}
import cli.Env
import cli.Path
import src/ClassCheck

## Run the same post-Tailwind check as the site task, without building the site.
main! = |_| ClassCheck.run!(Path.display(Env.cwd!()?))
