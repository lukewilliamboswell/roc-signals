import cli.Path
import Proc
import SpecSuite

## The roc-fuzz targets, the browser contract tests, the soak runs and the
## js-framework-benchmark check.
##
## An app's fuzz target is its `main-fuzz.roc`, beside its modules: Roc
## resolves an app's sibling modules from the directory of its main file, so a
## target that drives an app's own modules lives with the app. Targets that
## test only the shared support live under `fuzz/`.
Targets := [].{
	Fuzz : { name : Str, main : Str }

	fuzz_targets : List(Fuzz)
	fuzz_targets = [
		{ name: "scm-parse", main: "fuzz/scm-parse/main.roc" },
		{ name: "form-builder", main: "examples/form-builder/main-fuzz.roc" },
		{ name: "kanban-board", main: "examples/kanban-board/main-fuzz.roc" },
		{ name: "data-grid", main: "examples/data-grid/main-fuzz.roc" },
		{ name: "markdown-editor", main: "examples/markdown-editor/main-fuzz.roc" },
		{ name: "conduit", main: "examples/conduit/main-fuzz.roc" },
		{ name: "fx-channel", main: "tests/apps/effects/main-fuzz.roc" },
		{ name: "controls", main: "tests/apps/controls/main-fuzz.roc" },
	]

	## The committed exact allocation baseline of a target. Only
	## `blueprint run fuzz-accept` writes it; CI only checks against it.
	baseline : Str -> Str
	baseline = |name| "fuzz/baselines/${name}_baseline.json"

	## Build a fuzz target (`--fuzz --opt=speed`); returns the executable.
	build_fuzz! : SpecSuite.Options, Fuzz => Try(Str, _)
	build_fuzz! = |o, { name, main }| {
		dir = "${o.build_dir}/fuzz/${name}"
		SpecSuite.fresh_dir!(dir)?
		Proc.run!({ program: o.compiler, args: ["build", "--fuzz", "--opt=speed", main, "--output=${dir}/target"], cwd: o.root })?
		Ok("${dir}/target")
	}

	## Run a target's declared examples once each against its committed
	## baseline. A finding, a changed baseline or a missing one is a problem.
	fuzz_check! : SpecSuite.Options, Fuzz, Str => Try(List(Str), _)
	fuzz_check! = |o, { name, .. }, exe| {
		{ code, stdout } = Proc.output!({ program: exe, args: ["check", "--baseline=${o.root}/${Targets.baseline(name)}", "--timeout=1800"], cwd: "${o.build_dir}/fuzz/${name}" })?
		out = Str.from_utf8_lossy(stdout)
		Proc.note!(out)
		Ok(
			if code != 0 or !out.contains("${name}: passed") {
				["fuzz ${name}: ${out.trim()}"]
			} else if !out.contains("baseline matched") {
				["fuzz ${name}: no accepted baseline (${Targets.baseline(name)}); review the observations and run `blueprint run fuzz-accept`"]
			} else {
				[]
			},
		)
	}

	## Accept a target's allocation observations as its baseline: an explicit
	## review step, never run by CI.
	fuzz_accept! : SpecSuite.Options, Fuzz, Str => Try({}, _)
	fuzz_accept! = |o, { name, .. }, exe| {
		Path.create_all!(Path.utf8("${o.root}/fuzz/baselines"))?
		Proc.run!({ program: exe, args: ["accept", "--baseline=${o.root}/${Targets.baseline(name)}", "--timeout=1800"], cwd: "${o.build_dir}/fuzz/${name}" })
	}

	## Build a test app (`tests/apps/<name>`) for the browser.
	build_test_wasm! : SpecSuite.Options, Str => Try(Str, _)
	build_test_wasm! = |o, name| {
		dir = "${o.build_dir}/wasm/${name}"
		Path.create_all!(Path.utf8(dir))?
		Proc.run!({ program: o.compiler, args: ["build", "--target=wasm32", "--opt=size", "tests/apps/${name}/main-web.roc", "--output=${dir}/app.wasm"], cwd: o.root })?
		Ok("${dir}/app.wasm")
	}

	browser! : SpecSuite.Options, Str, List(Str) => Try(List(Str), _)
	browser! = |o, script, args| {
		code = Proc.status!({ program: o.node, args: ["tests/browser/${script}", "--runtime", SpecSuite.runtime, "--chrome", o.chrome].concat(args), cwd: o.root })?
		Ok(if (code == 0) [] else ["${script} ${Str.join_with(args, " ")} failed (exit ${code.to_str()})"])
	}

	## The runtime contract tests in Chrome: the effect channel (tests/apps/effects),
	## controlled inputs, focus and containment (tests/apps/controls), and
	## Conduit's user journey against the RealWorld mock backend.
	browser_contracts! : SpecSuite.Options, Str => Try(List(Str), _)
	browser_contracts! = |o, conduit_wasm| {
		fx = Targets.build_test_wasm!(o, "effects")?
		controls = Targets.build_test_wasm!(o, "controls")?
		Ok(
			Targets.browser!(o, "fx-browser.mjs", ["--wasm", fx])?
				.concat(Targets.browser!(o, "controls-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "conduit-journey.mjs", ["--wasm", conduit_wasm])?),
		)
	}

	## A long session of one app in Chrome: a seeded random walk without a
	## fault, then 30 round trips with flat Wasm pages and live allocations.
	browser_soak! : SpecSuite.Options, Str, Str => Try(List(Str), _)
	browser_soak! = |o, example, wasm| Targets.browser!(o, "soak.mjs", ["--wasm", wasm, "--app", example])

	jfb_dir = "benchmarks/js-framework-benchmark/roc-signals-keyed"

	## Build the js-framework-benchmark app into its `dist/` (`--opt=speed`,
	## as the benchmark measures it) and run the keyed-operation checks.
	jfb! : SpecSuite.Options => Try(List(Str), _)
	jfb! = |o| {
		dist = "${o.root}/${Targets.jfb_dir}/dist"
		Path.create_all!(Path.utf8(dist))?
		Proc.run!({ program: o.compiler, args: ["build", "--target=wasm32", "--opt=speed", "${Targets.jfb_dir}/app/main.roc", "--output=${dist}/app.wasm"], cwd: o.root })?
		Path.copy!(Path.utf8("${o.root}/${SpecSuite.runtime}"), Path.utf8("${dist}/runtime.mjs"))?
		Path.copy!(Path.utf8("${o.root}/${Targets.jfb_dir}/src/main.mjs"), Path.utf8("${dist}/main.mjs"))?
		code = Proc.status!({ program: o.node, args: ["tests/browser/jfb-check.mjs", "--dist", dist, "--chrome", o.chrome], cwd: o.root })?
		Ok(if (code == 0) [] else ["jfb-check failed (exit ${code.to_str()})"])
	}
}
