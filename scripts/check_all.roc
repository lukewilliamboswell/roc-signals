#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.2/2H2hePe5iYTZaGdG9MbMqhS29yg4Zxxr7dPEbZJ96fME.tar.zst",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.Path
import src/Checks
import src/PlatformTest
import src/DocSamples
import src/ApiDocs
import src/ApiSurface
import src/ExampleFiles
import src/Release
import src/Proc
import src/SpecSuite
import src/Slow
import src/Targets
import src/ToolCheck
import src/Sizes

## The `check` task, the per-pull-request gate: the script pins,
## formatting, every file `www/data/examples.toml` names present, every
## public `Engine` and `Html` symbol documented, `roc test` (the platform,
## the engine package, the tool, the scripts, and every example's and test
## app's `expect`s),
## the platform inputs, the host's resource-heap tests, the spec runner's
## links for macOS and Windows, the fuzz targets under `fuzz/` and the
## examples' own, the docs samples, every
## app's `.scm` specs natively and in Chrome, a short walk of every app in
## the native runner, the broken-spec self-checks (both
## runners reject each spec with one wrong expectation, a lost worker job's
## fault class among them), the runtime's
## unit tests in Node and contract tests in Chrome (effects, controls,
## workers, Conduit journey), the
## recorded gzip sizes of shipped JavaScript and a report of each example's
## shipping module and development-only scripts, the
## js-framework-benchmark check, the release dry run, and the `signals.roc`
## tool run end to end from the dry run's copy. The long walks, the soaks
## and the test apps' fuzz targets are `check-slow`. Every problem is
## printed as a `FAIL` line at the end or, when a stage cannot run and
## aborts the task, before that stage's error (`Checks.gather!`).
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	var $problems = []

	Proc.note!("== script pins")
	$problems = Checks.gather!($problems, script_pins!())?

	Proc.note!("== file names")
	$problems = Checks.gather!($problems, file_names!())?

	Proc.note!("== formatting")
	$problems = Checks.gather!($problems, check!({ program: o.compiler, args: ["fmt", "--check", "platform", "examples", "tests/apps", "tests/fixtures", "fuzz", "www/samples", "cli", "benchmarks/js-framework-benchmark/roc-signals-keyed/app"], cwd: "." }, "roc fmt --check"))?
	$problems = Checks.gather!($problems, check!({ program: o.tooling, args: ["fmt", "--check", "scripts"], cwd: "." }, "roc-stable fmt --check scripts"))?

	Proc.note!("== example files")
	$problems = Checks.gather!($problems, ExampleFiles.check!(o.root))?

	Proc.note!("== platform JavaScript sizes")
	$problems = Checks.gather!($problems, Sizes.check_runtime!({ root: o.root, node: o.node }))?

	$problems = Checks.gather!($problems, platform_packages!(o.root))?

	Proc.note!("== API docs")
	$problems = Checks.gather!($problems, ApiDocs.check!({}))?
	$problems = Checks.gather!($problems, ApiDocs.internal_roots!(o))?
	$problems = Checks.gather!($problems, ApiDocs.bump!(o))?

	Proc.note!("== roc test")
	$problems = Checks.gather!($problems, check!({ program: o.compiler, args: ["test", "platform/main.roc"], cwd: "." }, "roc test platform/main.roc"))?
	$problems = Checks.gather!($problems, check!({ program: o.compiler, args: ["test", "platform/main-fuzz.roc"], cwd: "." }, "roc test platform/main-fuzz.roc"))?
	$problems = Checks.gather!($problems, check!({ program: o.compiler, args: ["test", "cli/main.roc"], cwd: "." }, "roc test cli/main.roc"))?
	$problems = Checks.gather!($problems, Checks.app_expects!(o))?
	$problems = Checks.gather!($problems, ToolCheck.bundle_current!(o))?
	$problems = Checks.gather!($problems, check!({ program: o.tooling, args: ["test", "scripts/check_all.roc"], cwd: "." }, "roc-stable test scripts"))?

	Proc.note!("== platform inputs")
	Checks.hold!($problems, Checks.prepare_platform!(o))?
	$problems = Checks.gather!($problems, Checks.key_contracts!(o))?
	$problems = Checks.gather!($problems, check!({ program: o.zig, args: ["test", "platform/host/resources.zig"], cwd: "." }, "zig test platform/host/resources.zig"))?
	$problems = Checks.gather!($problems, check!({ program: o.zig, args: ["test", "platform/host/dbg.zig"], cwd: "." }, "zig test platform/host/dbg.zig"))?
	$problems = Checks.gather!($problems, cross_links!(o))?
	$problems = Checks.gather!($problems, fuzz_smoke!(o))?

	Proc.note!("== docs samples")
	$problems = Checks.gather!($problems, DocSamples.check!(o))?

	Proc.note!("== specs")
	var $native = SpecSuite.empty_tally
	var $browser = SpecSuite.empty_tally
	var $kanban = { runner: "" }
	Checks.hold!($problems, SpecSuite.build_web_platform!(o))?
	Proc.note!("== example module and debug file sizes (reported)")
	$problems = Checks.gather!($problems, Sizes.report!(o))?
	# Every spec-bearing app is built for the browser too, from the one list in
	# SpecSuite, with the two test apps that have contract tests and no specs.
	Checks.hold!($problems, SpecSuite.build!(o, SpecSuite.spec_apps, SpecSuite.spec_apps.concat(["tests/apps/effects", "tests/apps/controls"])))?
	for example in SpecSuite.spec_apps {
		r = Checks.hold!($problems.concat($native.problems).concat($browser.problems), Checks.run_app!(o, example, Bool.True))?
		$native = SpecSuite.add($native, r.native)
		$browser = SpecSuite.add($browser, r.browser)
		if example == "kanban-board" {
			$kanban = { runner: r.runner }
		}
	}
	$problems = $problems.concat($native.problems).concat($browser.problems)

	Proc.note!("== native lifetime contracts")
	$problems = Checks.gather!($problems, Targets.native_contracts!(o))?

	Proc.note!("== short walks")
	$problems = Checks.gather!($problems, Slow.short_walks!(o))?

	Proc.note!("== grammar coverage")
	$problems = Checks.gather!($problems, Checks.grammar!(o, $kanban.runner))?

	Proc.note!("== broken-spec self-check")
	for broken in Checks.broken_specs {
		$problems = Checks.gather!($problems, Checks.broken_spec!(o, broken))?
	}

	Proc.note!("== declaration refusals before execution and emission")
	$problems = Checks.gather!($problems, Checks.declaration_refusals!(o, {}))?

	Proc.note!("== runtime unit tests")
	$problems = Checks.gather!($problems, Targets.runtime_unit!(o))?

	Proc.note!("== runtime contracts in Chrome")
	$problems = Checks.gather!($problems, Targets.browser_contracts!(o, "${o.build_dir}/wasm/conduit/app.wasm"))?

	Proc.note!("== js-framework-benchmark")
	$problems = Checks.gather!($problems, Targets.jfb!(o))?

	Proc.note!("== release dry run")
	$problems = Checks.gather!($problems, Release.build!(o, "0.0.1-dryrun", "${o.build_dir}/release"))?

	Proc.note!("== signals.roc")
	$problems = Checks.gather!($problems, ToolCheck.run!(o))?

	Proc.note!("")
	Proc.note!(SpecSuite.summary("all apps", Native, $native))
	Proc.note!(SpecSuite.summary("all apps", Browser, $browser))
	Checks.finish!("check", $problems)
}

## Run a check; a failure is a reported problem, not an abort.
check! : Proc.Job, Str => Try(List(Str), _)
check! = |job, label| {
	{ code, .. } = Proc.output!(job)?
	Ok(if (code == 0) [] else ["${label} failed (exit ${code.to_str()})"])
}

## The source directories whose file names must stay distinct on a file
## system that ignores letter case.
source_dirs : List(Str)
source_dirs = ["platform", "cli", "examples", "tests", "fuzz", "scripts", "www/samples", "www/content", "www/data", "www/static", "www/templates", "benchmarks"]

## No two source files have paths that differ only in letter case. macOS and
## Windows keep one file for such a pair, so a checkout there silently loses
## the other, and a build that needs both fails.
file_names! : () => Try(List(Str), _)
file_names! = || {
	var $files = []
	for dir in source_dirs {
		$files = $files.concat(SpecSuite.files_under!(dir, "")?)
	}
	Ok(case_collisions($files))
}

## One problem for each pair of paths that are equal once letter case is
## ignored.
case_collisions : List(Str) -> List(Str)
case_collisions = |paths| {
	keyed = paths.map(|path| { key: Str.from_utf8_lossy(path.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b)), path })
	sorted = keyed.sort_with(
		|a, b| match SpecSuite.compare_str(a.key, b.key) {
			Same => SpecSuite.compare_str(a.path, b.path)
			other => other
		},
	)
	var $out = []
	var $prev = { key: "", path: "" }
	for item in sorted {
		if item.key == $prev.key and item.path != $prev.path {
			$out = $out.append("${$prev.path} and ${item.path} differ only in letter case, so a checkout on macOS or Windows keeps only one of them")
		}
		$prev = item
	}
	$out
}

## Two paths that differ only in case are reported once, in a fixed order.
expect case_collisions(["platform/engine.roc", "a/b.roc", "platform/Engine.roc"]) == ["platform/Engine.roc and platform/engine.roc differ only in letter case, so a checkout on macOS or Windows keeps only one of them"]

## Paths that differ in more than case, and a path listed twice, are fine.
expect case_collisions(["a/B.roc", "a/c.roc", "A2/b.roc", "a/c.roc"]) == []

## Every script under `scripts/` names the tooling compiler Blueprint.roc pins,
## and nothing else pins a compiler: no `.roc-version`, and no `roc` header
## field in any Roc file outside `scripts/` (roc-automation's model; the
## package compiler floats).
script_pins! : () => Try(List(Str), _)
script_pins! = || {
	blueprint = Path.read_utf8!(Path.utf8("Blueprint.roc"))?
	tag = match blueprint.split_on("Recipes.roc_nightly(\"") {
		[_, rest, ..] => rest.split_on("\"").first() ?? ""
		_ => ""
	}
	if tag == "" {
		return Ok(["Blueprint.roc names no roc-stable nightly"])
	}
	scripts = SpecSuite.files_with!("scripts", ".roc")?
	var $out = []
	for s in scripts {
		text = Path.read_utf8!(Path.utf8(s))?
		if !text.contains("roc: \"${tag}\"") {
			$out = $out.append("${s} does not pin roc: \"${tag}\"")
		}
	}
	if Path.exists!(Path.utf8(".roc-version"))? {
		$out = $out.append(".roc-version pins a compiler; only scripts/ may")
	}
	for dir in ["platform", "examples", "tests", "fuzz", "www/samples", "cli", "benchmarks/js-framework-benchmark/roc-signals-keyed/app"] {
		for f in SpecSuite.files_under!(dir, ".roc")? {
			header = Path.read_utf8!(Path.utf8(f))?.split_on("\n").take_first(6)
			if header.any(|l| l.trim().starts_with("roc: \"")) {
				$out = $out.append("${f} pins a compiler in its header; only scripts/ may")
			}
		}
	}
	Ok($out)
}

## The spec runner links for every other system it builds for: a worker
## app's runner built for macOS and Windows from here, with the link inputs
## `prepare_platform!` made. Building shows a system's inputs are whole; CI
## runs the specs on each system.
cross_links! : SpecSuite.Options => Try(List(Str), _)
cross_links! = |o| {
	var $jobs = []
	for host in PlatformTest.spec_hosts {
		dir = "${o.build_dir}/cross/${host.target}"
		Path.create_all!(Path.utf8(dir))?
		$jobs = $jobs.append(SpecSuite.build_job(o, "dev", "tests/apps/tasks/main.roc", host.target, "${dir}/runner"))
	}
	results = Proc.parallel!($jobs, Proc.compiler_jobs!()?)?
	Ok(List.map2(PlatformTest.spec_hosts, results, |host, r| (host.target, r)).keep_if(|(_, r)| r.code != 0).map(|(target, r)| "spec runner for ${target} does not link: ${r.output.trim()}"))
}

## The fuzz targets under `fuzz/` and the examples' targets of their own
## logic build with `--fuzz` and pass their examples; the targets beside
## the test apps, which take minutes, are `check-slow`'s.
fuzz_smoke! : SpecSuite.Options => Try(List(Str), _)
fuzz_smoke! = |o| Targets.fuzz_check_all!(o, Targets.fuzz_targets.keep_if(|t| !t.main.starts_with("tests/")))

## Both platform roots must fetch the same internal dependencies. A drift
## would give the oracle/fuzz package a different codec from shipped apps.
platform_packages! : Str => Try(List(Str), _)
platform_packages! = |root| {
	platform_source = Path.read_utf8!(Path.utf8("${root}/platform/main.roc"))?
	package_source = Path.read_utf8!(Path.utf8("${root}/platform/main-fuzz.roc"))?
	platform_dependencies = ApiSurface.dependencies(platform_source)?
	package_dependencies = ApiSurface.dependencies(package_source)?
	Ok(
		["parser", "unicode", "cbor"].fold(
			[],
			|problems, name| {
				platform_urls = platform_dependencies.keep_if(|dependency| dependency.name == name).map(|dependency| dependency.url)
				package_urls = package_dependencies.keep_if(|dependency| dependency.name == name).map(|dependency| dependency.url)
				if platform_urls.len() == 1 and platform_urls == package_urls {
					problems
				} else {
					problems.append("platform roots must declare the same single ${name} dependency")
				}
			},
		),
	)
}
