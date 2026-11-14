#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.2/2H2hePe5iYTZaGdG9MbMqhS29yg4Zxxr7dPEbZJ96fME.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}
import cli.Env
import cli.Path
import src/ClassCheck

## Run the same post-Tailwind check as the site task, without building the site.
main! = |_| ClassCheck.run!(Path.display(Env.cwd!()?))
