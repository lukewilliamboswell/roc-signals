#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-11-03-34bd006",
}

import cli.Path
import src/Checks
import src/Proc
import src/SpecSuite

## The `check` task (Phase 2a scope): formatting, the script pins, `roc test`
## on the test support, the `--fuzz` build of the test platform, every ported
## app's original `.scm` specs natively and in Chrome, and the mutation check
## that both spec runners reject a broken spec.
##
## Work assertions cannot run until Phase 3 adds the engine's counters, so the
## suite runs with `--pending-phase3`: they are counted and reported, never
## passed. `scripts/spec.roc -- --strict` shows the failures they become.
main! = |_args| {
	o = Checks.options!({ pending_phase3: Bool.True, filter: "*" })?
	var $problems = []

	Proc.note!("== script pins")
	$problems = $problems.concat(script_pins!()?)

	Proc.note!("== formatting")
	spec_mains = SpecSuite.apps.map(|a| "${SpecSuite.apps_dir}/${a}/SpecMain.roc")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["fmt", "--check", "scripts", "test-support", "platform-test", "fuzz"].concat(spec_mains), cwd: "." }, "roc fmt --check")?)

	Proc.note!("== roc test")
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "test-support/main.roc"], cwd: "." }, "roc test test-support")?)
	$problems = $problems.concat(check!({ program: o.compiler, args: ["test", "scripts/check_all.roc"], cwd: "." }, "roc test scripts")?)

	Proc.note!("== platform-test")
	Checks.prepare_platform!(o)?
	$problems = $problems.concat(spec_runner_tests!(o)?)
	$problems = $problems.concat(fuzz_smoke!(o)?)

	Proc.note!("== specs")
	var $native = SpecSuite.empty_tally
	var $browser = SpecSuite.empty_tally
	var $kanban = { runner: "", wasm: "" }
	_ = SpecSuite.build_web_platform!(o)?
	for example in SpecSuite.apps {
		r = Checks.run_app!(o, example, Bool.True)?
		$native = Checks.add($native, r.native)
		$browser = Checks.add($browser, r.browser)
		if example == "kanban-board" {
			$kanban = { runner: r.runner, wasm: "${o.build_dir}/wasm/${example}/app.wasm" }
		}
	}
	$problems = $problems.concat($native.problems).concat($browser.problems)

	Proc.note!("== mutation check")
	$problems = $problems.concat(Checks.mutation!(o, $kanban.runner, $kanban.wasm)?)

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

## The runner's own expects, compiled against a stand-in program so they need
## no engine build.
spec_runner_tests! : SpecSuite.Options => Try(List(Str), _)
spec_runner_tests! = |o| {
	dir = "${o.build_dir}/spec-runner-tests"
	SpecSuite.fresh_dir!(dir)?
	for f in [SpecSuite.oracle].concat(SpecSuite.support) {
		SpecSuite.copy!(f, dir)?
	}
	platform_main = SpecSuite.relative("${o.root}/platform-test/main.roc", dir)
	main =
		\\app [target] { pf: platform "${platform_main}" }
		\\
		\\import pf.Target
		\\import SpecRunner
		\\
		\\program = { keys: || [0, 0, 0, 0], init: |_| ({}, []), event: |s, _, _, _, _| (s, []) }
		\\
		\\target = Target.cli({ name: "spec-runner-tests", main!: |args| SpecRunner.main!(program, args) })
		\\
	Path.write_utf8!(Path.utf8("${dir}/main.roc"), main)?
	check!({ program: o.compiler, args: ["test", "main.roc"], cwd: dir }, "roc test SpecRunner")
}

## Every fuzz target builds with `--fuzz` against platform-test and passes
## `check` (its declared examples, once each).
fuzz_smoke! : SpecSuite.Options => Try(List(Str), _)
fuzz_smoke! = |o| {
	var $out = []
	for target in ["scm-parse"] {
		dir = "fuzz/${target}"
		exe = "${o.build_dir}/fuzz-${target}"
		$out = $out.concat(check!({ program: o.compiler, args: ["build", "--fuzz", "--opt=speed", "${dir}/main.roc", "--output=${exe}"], cwd: "." }, "roc build --fuzz ${dir}")?)
		if $out.is_empty() {
			$out = $out.concat(check!({ program: exe, args: ["check", "--baseline=${o.build_dir}/fuzz-${target}_baseline.json"], cwd: o.build_dir }, "${target} check")?)
		}
	}
	Ok($out)
}
