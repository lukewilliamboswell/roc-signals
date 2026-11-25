#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.5/822J9njyNR1vgyX1KG4ck496dBx3AnLfvn2zHXn15Ksw.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
}
import cli.Env
import cli.Path
import src/ClassCheck

## Run the same post-Tailwind check as the site task, without building the site.
main! = |_| ClassCheck.run!(Path.display(Env.cwd!()?))
