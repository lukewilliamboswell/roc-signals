#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import cli.Path
import src/Checks
import src/Proc
import src/SpecSuite

## The `site` task: build the documentation site into `dist/`. Tailwind
## writes `www/static/signals.css` (ignored), Zola checks and builds `www/`,
## and every example's `main-web.roc` is built (`--opt=size`, as it ships)
## to `dist/examples/<slug>/app.wasm` beside `dist/runtime.mjs`, which the
## site's `site.mjs` mounts it with.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	dist = "${o.root}/dist"
	Proc.run!({ program: "tailwindcss", args: ["-c", "tailwind.config.js", "-i", "www/input.css", "-o", "www/static/signals.css", "--minify"], cwd: o.root })?
	Proc.run!({ program: "zola", args: ["--root", "www", "check"], cwd: o.root })?
	Proc.run!({ program: "zola", args: ["--root", "www", "build", "--output-dir", dist, "--force"], cwd: o.root })?
	SpecSuite.build_web_platform!(o)?
	SpecSuite.build_with!(o, [], SpecSuite.apps, "size")?
	for example in SpecSuite.apps {
		dir = "${dist}/examples/${example}"
		Path.create_all!(Path.utf8(dir))?
		Path.copy!(Path.utf8(SpecSuite.wasm_of(o, example)), Path.utf8("${dir}/app.wasm"))?
	}
	Path.copy!(Path.utf8("${o.root}/${SpecSuite.runtime}"), Path.utf8("${dist}/runtime.mjs"))?
	Proc.note!("site: built ${dist}")
	Ok({})
}
