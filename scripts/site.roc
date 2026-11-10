#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-09-9e85de7",
}

import cli.OsStr
import cli.Path
import src/ApiDocs
import src/Checks
import src/Proc
import src/SpecSuite

## The `site` task: build the documentation site into `dist/`
## (`-- --base-url URL` to browse it somewhere other than its published
## address, such as `http://127.0.0.1:8000/roc-signals` for the `serve` task). Tailwind
## writes `www/static/signals.css` (ignored), Zola checks the internal links
## and builds `www/`,
## roc-docs generates the API docs into `dist/api/`, and every example's
## `main.roc` is built for wasm32 (`--opt=size`, as it ships) to
## `dist/examples/<slug>/app.wasm` beside `dist/runtime.mjs` (and its worker
## script, `dist/worker.mjs`), which the
## site's `site.mjs` mounts it with. The status page's `plume-chart.mjs` and
## the worker lab's `pool-panel.mjs` are copied beside their apps.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	base_url = match args {
		["--base-url", url] => ["--base-url", url]
		[] => []
		_ => {
			Proc.warn!("usage: site.roc -- [--base-url URL]")
			return Err(Exit(2))
		}
	}
	o = Checks.options!({ filter: "*" })?
	dist = "${o.root}/dist"
	Proc.run!({ program: "tailwindcss", args: ["-c", "www/tailwind.config.js", "-i", "www/input.css", "-o", "www/static/signals.css", "--minify"], cwd: o.root })?
	Proc.run!({ program: "zola", args: ["--root", "www", "check", "--skip-external-links"], cwd: o.root })?
	Proc.run!({ program: "zola", args: ["--root", "www", "build", "--output-dir", dist, "--force"].concat(base_url), cwd: o.root })?
	api = ApiDocs.build!(o, "main")?
	Proc.run!({ program: "cp", args: ["-R", api, "${dist}/api"], cwd: o.root })?
	SpecSuite.build_web_platform!(o)?
	SpecSuite.build_with!(o, [], SpecSuite.apps, "size")?
	for example in SpecSuite.apps {
		dir = "${dist}/examples/${example}"
		Path.create_all!(Path.utf8(dir))?
		Path.copy!(Path.utf8(SpecSuite.wasm_of(o, example)), Path.utf8("${dir}/app.wasm"))?
	}
	# Scripts an example's page loads beside its app (www/data/examples.toml).
	Path.copy!(Path.utf8("${o.root}/examples/status-page/plume-chart.mjs"), Path.utf8("${dist}/examples/status-page/plume-chart.mjs"))?
	Path.copy!(Path.utf8("${o.root}/examples/worker-lab/pool-panel.mjs"), Path.utf8("${dist}/examples/worker-lab/pool-panel.mjs"))?
	SpecSuite.copy_runtime!(o.root, dist)?
	Proc.note!("site: built ${dist}")
	Ok({})
}
