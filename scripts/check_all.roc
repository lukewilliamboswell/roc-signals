#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import cli.Path
import src/Checks
import src/DocSamples
import src/ApiDocs
import src/Release
import src/Proc
import src/SpecSuite
import src/Targets

## The `check` task, the per-pull-request gate: the script pins,
## formatting, every public `Engine` and `Html` symbol documented, `roc test`,
## the test platform and the `scm-parse` fuzz target, the docs samples, every
## app's `.scm` specs natively and in Chrome, the broken-spec self-check (both
## runners reject a spec with one wrong expectation), the runtime contract
## tests in Chrome (effects, controls, Conduit journey), the
## js-framework-benchmark check, and the release dry run. The soaks and the
## app fuzz targets are `check-slow`.
main! = |_args| {
	o = Checks.options!({ filter: "*" })?
	var $problems = []

	Proc.note!("== script pins")
	$problems = $problems.concat(script_pins!()?)

	Proc.note!("== formatting")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["fmt", "--check", "scripts", "platform", "test-support", "examples", "tests/apps", "fuzz", "www/samples", "benchmarks/js-framework-benchmark/roc-signals-keyed/app"], cwd: "." }, "roc fmt --check")?)

	Proc.note!("== API docs")
	$problems = $problems.concat(ApiDocs.check!({})?)

	Proc.note!("== roc test")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "test-support/main.roc"], cwd: "." }, "roc test test-support")?)
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "scripts/check_all.roc"], cwd: "." }, "roc test scripts")?)

	Proc.note!("== platform-test")
	Checks.prepare_platform!(o)?
	$problems = $problems.concat(fuzz_smoke!(o)?)

	Proc.note!("== docs samples")
	$problems = $problems.concat(DocSamples.check!(o)?)

	Proc.note!("== specs")
	var $native = SpecSuite.empty_tally
	var $browser = SpecSuite.empty_tally
	var $kanban = { runner: "", wasm: "" }
	SpecSuite.build_web_platform!(o)?
	SpecSuite.build!(o, SpecSuite.spec_apps, SpecSuite.apps.concat(["tests/apps/effects", "tests/apps/controls", "tests/apps/services"]))?
	for example in SpecSuite.spec_apps {
		r = Checks.run_app!(o, example, Bool.True)?
		$native = Checks.add($native, r.native)
		$browser = Checks.add($browser, r.browser)
		if example == "kanban-board" {
			$kanban = { runner: r.runner, wasm: "${o.build_dir}/wasm/${example}/app.wasm" }
		}
	}
	$problems = $problems.concat($native.problems).concat($browser.problems)

	Proc.note!("== broken-spec self-check")
	$problems = $problems.concat(Checks.broken_spec!(o, $kanban.runner, $kanban.wasm)?)

	Proc.note!("== runtime contracts in Chrome")
	$problems = $problems.concat(Targets.browser_contracts!(o, "${o.build_dir}/wasm/conduit/app.wasm")?)

	Proc.note!("== js-framework-benchmark")
	$problems = $problems.concat(Targets.jfb!(o)?)

	Proc.note!("== release dry run")
	$problems = $problems.concat(Release.build!(o, "0.0.1-dryrun", "${o.build_dir}/release")?)

	Proc.note!("")
	Proc.note!(SpecSuite.summary("all apps", Native, $native))
	Proc.note!(SpecSuite.summary("all apps", Browser, $browser))
	for x in SpecSuite.expected_failures {
		Proc.note!("expected failure: ${x.example} ${Str.inspect(x.runner)} ${x.id}: ${x.reason}")
	}
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

## Every script under `scripts/` names the tooling compiler Blueprint.roc pins.
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
	Ok($out)
}

## The parser's fuzz target builds with `--fuzz` and passes its examples;
## the app targets, which take minutes, are `check-slow`.
fuzz_smoke! : SpecSuite.Options => Try(List(Str), _)
fuzz_smoke! = |o| {
	target = { name: "scm-parse", main: "fuzz/scm-parse/main.roc" }
	exe = Targets.build_fuzz!(o, target)?
	Targets.fuzz_check!(o, target, exe)
}
