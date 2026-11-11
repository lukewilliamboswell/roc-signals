#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-10-f7d1f19",
}

import cli.Path
import src/Checks
import src/PlatformTest
import src/DocSamples
import src/ApiDocs
import src/ExampleFiles
import src/Release
import src/Proc
import src/SpecSuite
import src/Targets
import src/ToolCheck

## The `check` task, the per-pull-request gate: the script pins,
## formatting, every file `www/data/examples.toml` names present, every
## public `Engine` and `Html` symbol documented, `roc test`,
## the platform inputs, the host's resource-heap tests, the spec runner's
## links for macOS and Windows, the `scm-parse` and
## `wire` fuzz targets, the docs samples, every
## app's `.scm` specs natively and in Chrome, the broken-spec self-checks (both
## runners reject each spec with one wrong expectation, a lost worker job's
## fault class among them), the runtime's
## unit tests in Node and contract tests in Chrome (effects, controls,
## workers, Conduit journey), the
## js-framework-benchmark check, the release dry run, and the `signals.roc`
## tool run end to end from the dry run's copy. The soaks and the
## app fuzz targets are `check-slow`.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	var $problems = []

	Proc.note!("== script pins")
	$problems = $problems.concat(script_pins!()?)

	Proc.note!("== formatting")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["fmt", "--check", "platform", "examples", "tests/apps", "fuzz", "www/samples", "cli", "benchmarks/js-framework-benchmark/roc-signals-keyed/app"], cwd: "." }, "roc fmt --check")?)
	$problems = $problems.concat(check!({ program: o.tooling, args: ["fmt", "--check", "scripts"], cwd: "." }, "roc-stable fmt --check scripts")?)

	Proc.note!("== example files")
	$problems = $problems.concat(ExampleFiles.check!(o.root)?)

	Proc.note!("== API docs")
	$problems = $problems.concat(ApiDocs.check!({})?)

	Proc.note!("== roc test")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "platform/main.roc"], cwd: "." }, "roc test platform/main.roc")?)
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "platform/engine.roc"], cwd: "." }, "roc test platform/engine.roc")?)
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "cli/main.roc"], cwd: "." }, "roc test cli/main.roc")?)
	$problems = $problems.concat(ToolCheck.bundle_current!(o)?)
	$problems = $problems.concat(check!({ program: o.tooling, args: ["test", "scripts/check_all.roc"], cwd: "." }, "roc-stable test scripts")?)

	Proc.note!("== platform inputs")
	Checks.prepare_platform!(o)?
	$problems = $problems.concat(check!({ program: o.zig, args: ["test", "platform/host/resources.zig"], cwd: "." }, "zig test platform/host/resources.zig")?)
	$problems = $problems.concat(cross_links!(o)?)
	$problems = $problems.concat(fuzz_smoke!(o)?)

	Proc.note!("== docs samples")
	$problems = $problems.concat(DocSamples.check!(o)?)

	Proc.note!("== specs")
	var $native = SpecSuite.empty_tally
	var $browser = SpecSuite.empty_tally
	var $kanban = { runner: "" }
	SpecSuite.build_web_platform!(o)?
	# Every spec-bearing app is built for the browser too, from the one list in
	# SpecSuite, with the two test apps that have contract tests and no specs.
	SpecSuite.build!(o, SpecSuite.spec_apps, SpecSuite.spec_apps.concat(["tests/apps/effects", "tests/apps/controls"]))?
	for example in SpecSuite.spec_apps {
		r = Checks.run_app!(o, example, Bool.True)?
		$native = Checks.add($native, r.native)
		$browser = Checks.add($browser, r.browser)
		if example == "kanban-board" {
			$kanban = { runner: r.runner }
		}
	}
	$problems = $problems.concat($native.problems).concat($browser.problems)

	Proc.note!("== grammar coverage")
	$problems = $problems.concat(Checks.grammar!(o, $kanban.runner)?)

	Proc.note!("== broken-spec self-check")
	for broken in Checks.broken_specs {
		$problems = $problems.concat(Checks.broken_spec!(o, broken)?)
	}

	Proc.note!("== runtime unit tests")
	$problems = $problems.concat(Targets.runtime_unit!(o)?)

	Proc.note!("== runtime contracts in Chrome")
	$problems = $problems.concat(Targets.browser_contracts!(o, "${o.build_dir}/wasm/conduit/app.wasm")?)

	Proc.note!("== js-framework-benchmark")
	$problems = $problems.concat(Targets.jfb!(o)?)

	Proc.note!("== release dry run")
	$problems = $problems.concat(Release.build!(o, "0.0.1-dryrun", "${o.build_dir}/release")?)

	Proc.note!("== signals.roc")
	$problems = $problems.concat(ToolCheck.run!(o)?)

	Proc.note!("")
	Proc.note!(SpecSuite.summary("all apps", Native, $native))
	Proc.note!(SpecSuite.summary("all apps", Browser, $browser))
	if $problems.is_empty() {
		Proc.note!("check: passed")
		Ok({})
	} else {
		for p in $problems {
			Proc.warn!("FAIL ${p}")
		}
		Err(Exit(1))
	}
}

## Run a check; a failure is a reported problem, not an abort.
check! : Proc.Job, Str => Try(List(Str), _)
check! = |job, label| {
	{ code, .. } = Proc.output!(job)?
	Ok(if (code == 0) [] else ["${label} failed (exit ${code.to_str()})"])
}

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
	results = Proc.parallel!($jobs, Proc.cpus!())?
	Ok(List.map2(PlatformTest.spec_hosts, results, |host, r| (host.target, r)).keep_if(|(_, r)| r.code != 0).map(|(target, r)| "spec runner for ${target} does not link: ${r.output.trim()}"))
}

## The shared-support fuzz targets (the `.scm` parser and the worker wire
## format) build with `--fuzz` and pass their examples; the app targets,
## which take minutes, are `check-slow`.
fuzz_smoke! : SpecSuite.Options => Try(List(Str), _)
fuzz_smoke! = |o| Targets.fuzz_check_all!(o, Targets.fuzz_targets.keep_if(|t| t.main.starts_with("fuzz/")))
