#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "../../roc-parser/package/main.roc",
	roc: "nightly-2026-11-10-f7d1f19",
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
