#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.2/2H2hePe5iYTZaGdG9MbMqhS29yg4Zxxr7dPEbZJ96fME.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import src/ApiDocs
import src/Checks
import src/Proc

## Build and audit the API reference without rebuilding site examples.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	site = ApiDocs.build!(o, "main")?
	Proc.note!("API documentation and member coverage passed: ${site}")
	Ok({})
}
