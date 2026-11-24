#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.5/822J9njyNR1vgyX1KG4ck496dBx3AnLfvn2zHXn15Ksw.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
}

import cli.OsStr
import src/ApiDocs
import src/Checks
import src/Proc

## Build and audit the API reference without rebuilding site examples.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	site = ApiDocs.build!(o, "main")?
	Proc.note!("API documentation and member coverage passed: ${site}")
	Ok({})
}
