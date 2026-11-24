#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-23-b5c77fc",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Checks
import src/Proc
import src/SpecSuite

## The small startup boundary gate runs two corpora in three engines. App
## specs keep their ordinary native/Chrome gate; this never enumerates them.
## The Blueprint recipe locks the test-only Playwright archive. Its own CLI
## installs its matching browser revisions in the standard shared cache.
main! = |raw_args| {
	args = raw_args.map(OsStr.display).drop_if(|arg| arg == "--")
	with_deps = match args {
		[] => False
		["--with-deps"] => True
		_ => {
			Proc.warn!("usage: startup_browsers.roc -- [--with-deps]")
			return Err(Exit(2))
		}
	}
	configured = Checks.options!({ filter: "*" })?
	uname = Str.from_utf8_lossy(Proc.capture!({ program: "uname", args: ["-sm"], cwd: configured.root })?)
	target = SpecSuite.host_target(uname) ? |Unknown(value)| UnsupportedHost(value)
	o = { ..configured, build_dir: "${configured.build_dir}/startup-browsers", target }
	Path.create_all!(Path.utf8(o.build_dir))?
	version = Str.from_utf8_lossy(Proc.capture!({ program: "playwright-core", args: ["--version"], cwd: o.root })?).trim()
	if version != "Version 1.65.1" {
		return Err(UnsupportedPlaywright("expected locked playwright-core 1.65.1; got ${version}"))
	}
	module_path = playwright_module!()?
	Proc.run!({ program: "playwright-core", args: ["install"].concat(if (with_deps) ["--with-deps"] else []).concat(["chromium", "firefox", "webkit"]), cwd: o.root })?
	Checks.prepare_platform!(o)?
	main = "tests/apps/startup-corpus/main.roc"
	runner = "${o.build_dir}/runner"
	wasm = "${o.build_dir}/app.wasm"
	SpecSuite.note_profile!(o, "dev")
	Proc.run!(SpecSuite.build_job(o, "dev", main, target, runner))?
	Proc.run!(SpecSuite.build_job(o, "dev", main, "wasm32", wasm))?
	var $problems = []
	for browser in ["chromium", "firefox", "webkit"] {
		output = "${o.build_dir}/${browser}"
		Path.create_all!(Path.utf8(output))?
		for corpus in ["startup-annotations-browser.mjs", "startup-corpus-browser.mjs"] {
			Proc.note!("== ${browser} ${corpus} (${version})")
			browser_args = ["tests/browser/${corpus}", "--runtime", "${o.root}/${SpecSuite.runtime}", "--playwright", module_path, "--browser", browser]
			complete = if corpus == "startup-corpus-browser.mjs" {
				browser_args.concat(["--runner", runner, "--wasm", wasm, "--template", "${o.root}/tests/apps/startup-corpus/index.html", "--output", output])
			} else browser_args
			result = Proc.merged!({ program: o.node, args: complete, cwd: o.root })?
			Path.write_bytes!(Path.utf8("${output}/${corpus}.log"), result.stdout)?
			Proc.note!(Str.from_utf8_lossy(result.stdout))
			if result.code != 0 {
				$problems = $problems.append("${browser} ${corpus} exited ${result.code.to_str()}; see ${output}/${corpus}.log")
			}
		}
	}
	Checks.finish!("startup browser boundaries", $problems)
}

## Resolve the recipe's actual package beside its locked CLI. Blueprint
## preserves the whole archive; no node_modules or app dependency is needed.
playwright_module! : () => Try(Str, _)
playwright_module! = || {
	search = Env.var_str!("PATH")?
	for directory in search.split_on(":").drop_if(Str.is_empty) {
		candidate = Path.utf8("${directory}/playwright-core")
		if Path.exists!(candidate)? {
			actual = Path.canonicalize!(candidate)?
			parent = actual.parent() ? |_| MissingPlaywrightPackage
			module_path = parent.join("index.mjs")
			if !Path.exists!(module_path)? {
				return Err(MissingPlaywrightPackage)
			}
			return Ok(Path.display(module_path))
		}
	}
	Err(MissingPlaywrightPackage)
}
