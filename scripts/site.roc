#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "../../roc-parser/package/main.roc",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.OsStr
import cli.Path
import src/ApiDocs
import src/Checks
import src/ClassCheck
import src/DocSamples
import src/ExampleFiles
import src/Proc
import src/SpecSuite
import src/SiteCode

## The `site` task: build the documentation site into `dist/`
## (`-- --base-url URL` to browse it somewhere other than its published
## address, such as `http://127.0.0.1:8000/roc-signals` for the `serve` task). Tailwind
## writes `www/static/signals.css` (ignored), and the pinned Roc parser
## highlights samples, replacing relative header dependency URLs with a release-URL
## placeholder while preserving their other text. Zola checks the internal links
## and builds `www/`,
## roc-docs generates the API docs into `dist/api/`, and every example's
## `main.roc` is built for wasm32 (`--opt=size`, as it ships) to
## `dist/examples/<slug>/app.wasm` beside `dist/runtime.mjs` (and its worker
## script, `dist/worker.mjs`), which the
## site's `site.mjs` mounts it with. Every other file an example's page
## loads, as `www/data/examples.toml` names it (its scripts, port handlers,
## simulated service and data), is copied beside its app. The checked documentation
## sample sources are published under `dist/samples/` for readers to download.
## `--tool-url URL` points onboarding downloads at a matching candidate tool
## when reviewing an unreleased API; normal builds link the latest release.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|a| a == "--")
	options = parse_options(args) ?? {
		Proc.warn!("usage: site.roc -- [--base-url URL] [--tool-url URL]")
		return Err(Exit(2))
	}
	o = Checks.options!({ filter: "*" })?
	dist = "${o.root}/dist"
	config = match options.tool_url {
		Released => []
		Preview(url) => {
			source = Path.read_utf8!(Path.utf8("${o.root}/www/config.toml"))?
			configured = preview_config({ source, tool_url: url })?
			Path.create_all!(Path.utf8(o.build_dir))?
			path = "${o.build_dir}/site-config.toml"
			Path.write_utf8!(Path.utf8(path), configured)?
			["--config", path]
		}
	}
	zola = ["--root", "www"].concat(config)
	Proc.run!({ program: o.tooling, args: ["test", "scripts/site.roc"], cwd: o.root })?
	SiteCode.build!()?
	Proc.run!({ program: "tailwindcss", args: ["-c", "www/tailwind.config.js", "-i", "www/input.css", "-o", "www/static/signals.css", "--minify"], cwd: o.root })?
	ClassCheck.run!(o.root)?
	Proc.run!({ program: "zola", args: zola.concat(["check", "--skip-external-links"]), cwd: o.root })?
	Proc.run!({ program: "zola", args: zola.concat(["build", "--output-dir", dist, "--force"]).concat(options.base_url), cwd: o.root })?
	DocSamples.copy!({ root: o.root, dist, publish_roc: SiteCode.published_source })?
	api = ApiDocs.build!(o, "main")?
	Proc.run!({ program: "cp", args: ["-R", api, "${dist}/api"], cwd: o.root })?
	SpecSuite.build_web_platform!(o)?
	SpecSuite.build_with!(o, [], SpecSuite.apps, "size")?
	for example in SpecSuite.apps {
		dir = "${dist}/examples/${example}"
		Path.create_all!(Path.utf8(dir))?
		Path.copy!(Path.utf8(SpecSuite.wasm_of(o, example)), Path.utf8("${dir}/app.wasm"))?
	}
	ExampleFiles.copy_all!(o.root, dist)?
	SpecSuite.copy_runtime!(o.root, dist)?
	Proc.run!({ program: "node", args: ["tests/browser/site.mjs", dist], cwd: o.root })?
	Proc.note!("site: built ${dist}")
	Ok({})
}

SiteOptions : { base_url : List(Str), tool_url : [Released, Preview(Str)] }

## Accept each preview override once, in either order. Missing values and
## unknown arguments are usage errors rather than silently ignored options.
parse_options : List(Str) -> Try(SiteOptions, [Usage])
parse_options = |args| match args {
	[] => Ok({ base_url: [], tool_url: Released })
	["--base-url", url, .. as rest] if !url.starts_with("--") => {
		options = parse_options(rest)?
		if !options.base_url.is_empty() {
			return Err(Usage)
		}
		Ok({ ..options, base_url: ["--base-url", url] })
	}
	["--tool-url", url, .. as rest] if !url.starts_with("--") => {
		options = parse_options(rest)?
		if options.tool_url != Released {
			return Err(Usage)
		}
		Ok({ ..options, tool_url: Preview(url) })
	}
	_ => Err(Usage)
}

## Add the candidate URL to a separate Zola configuration, preserving the
## checked-in file. Refuse characters that cannot appear literally in this
## URL's TOML string, and require the existing extra section exactly once.
preview_config : { source : Str, tool_url : Str } -> Try(Str, [InvalidToolUrl, MissingExtraSection])
preview_config = |{ source, tool_url }| {
	if !(tool_url.starts_with("https://") or tool_url.starts_with("http://")) or tool_url.to_utf8().any(|b| b <= 32 or b == 127 or b == '"' or b == '\\') {
		return Err(InvalidToolUrl)
	}
	match source.split_on("[extra]\n") {
		[before, after] => Ok("${before}[extra]\nsignals_tool_url = \"${tool_url}\"\n${after}")
		_ => Err(MissingExtraSection)
	}
}

## Both override orders produce the same options; duplicate and incomplete
## flags are rejected before a site build starts.
expect {
	first = parse_options(["--tool-url", "http://127.0.0.1/candidate/signals.roc", "--base-url", "http://127.0.0.1"])?
	second = parse_options(["--base-url", "http://127.0.0.1", "--tool-url", "http://127.0.0.1/candidate/signals.roc"])?
	{
		order: first == second,
		duplicate: parse_options(["--tool-url", "a", "--tool-url", "b"]),
		missing: parse_options(["--tool-url"]),
		unknown: parse_options(["--unknown"]),
	} == { order: True, duplicate: Err(Usage), missing: Err(Usage), unknown: Err(Usage) }
}

## Candidate configuration retains the other extra keys and cannot inject
## a TOML setting through a quote or newline in the supplied URL.
expect {
	configured = preview_config({ source: "title = \"Roc\"\n[extra]\ngithub_url = \"upstream\"\n", tool_url: "http://127.0.0.1/candidate/signals.roc" })?
	{
		configured,
		quote: preview_config({ source: "[extra]\n", tool_url: "https://example.com/\"oops" }),
		newline: preview_config({ source: "[extra]\n", tool_url: "https://example.com/\ninjected" }),
		missing: preview_config({ source: "title = \"Roc\"\n", tool_url: "https://example.com/signals.roc" }),
	} == {
		configured: "title = \"Roc\"\n[extra]\nsignals_tool_url = \"http://127.0.0.1/candidate/signals.roc\"\ngithub_url = \"upstream\"\n",
		quote: Err(InvalidToolUrl),
		newline: Err(InvalidToolUrl),
		missing: Err(MissingExtraSection),
	}
}
