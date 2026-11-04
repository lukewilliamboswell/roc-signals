import cli.Path
import Proc

## Builds the ported apps for the native and the browser spec runners and runs
## their `.scm` specs.
##
## Phase 2a interim layout: the apps still live under `spike/roc-engine/apps`,
## and their modules `import Engine` as a sibling module rather than
## `pf.Engine`. Each build therefore copies the app's modules, the engine and
## the test support flat into one build directory (a copy, not a rewrite) and
## writes a two-line `main.roc` naming the platform. Phase 2b moves the apps to
## `examples/<app>/` with committed `main-web.roc` and `main-test.roc`, at
## which point this copying goes away.
SpecSuite := [].{

	## Where everything is, relative to the repository root.
	apps_dir = "spike/roc-engine/apps"
	engine = "spike/roc-engine/platform/Engine.roc"
	web_platform_dir = "spike/roc-engine/platform"
	runtime = "spike/roc-engine/platform/runtime.mjs"
	oracle = "spike/roc-engine/src/Dom.roc"
	html_helpers = "spike/roc-engine/src/H.roc"
	support = ["test-support/Scm.roc", "test-support/JsonOut.roc", "test-support/SpecRunner.roc"]

	## The apps ported to the engine, with their original specs.
	apps : List(Str)
	apps = ["form-builder", "kanban-board", "data-grid", "markdown-editor", "conduit"]

	Runner : [Native, Browser]

	## A spec that fails for a reason recorded here and must keep failing
	## until the reason is resolved: an expected failure that starts passing
	## fails the suite, so the entry cannot go stale.
	expected_failures : List({ example : Str, runner : Runner, id : Str, reason : Str })
	expected_failures = [
		{
			example: "form-builder",
			runner: Browser,
			id: "adding-a-number-field",
			reason: "the spec types \"2x\" into an <input type=number>, which a real browser cannot hold; the oracle accepts it (unchanged from the spike's Phase 5b Chrome run, 12/13)",
		},
	]

	Tally : { passed : U64, failed : U64, pending : U64, pending_steps : U64, xfail : U64, problems : List(Str) }

	empty_tally : Tally
	empty_tally = { passed: 0, failed: 0, pending: 0, pending_steps: 0, xfail: 0, problems: [] }

	## `root` and `build_dir` are absolute.
	Options : { root : Str, build_dir : Str, compiler : Str, zig : Str, node : Str, chrome : Str, pending_phase3 : Bool, filter : Str }

	# -------------------------------------------------------------- files

	path_str : Path -> Str
	path_str = |p| Path.display(p)

	fresh_dir! : Str => Try({}, _)
	fresh_dir! = |dir| {
		if Path.exists!(Path.utf8(dir))? {
			Path.delete_all!(Path.utf8(dir))?
		}
		Path.create_all!(Path.utf8(dir))
	}

	copy! : Str, Str => Try({}, _)
	copy! = |src, dir| {
		name = src.split_on("/").last() ?? src
		Path.copy!(Path.utf8(src), Path.utf8("${dir}/${name}"))
	}

	## The `.roc` files of a directory, by name, sorted.
	roc_files! : Str => Try(List(Str), _)
	roc_files! = |dir| SpecSuite.files_with!(dir, ".roc")

	files_with! : Str, Str => Try(List(Str), _)
	files_with! = |dir, suffix| {
		entries = Path.list!(Path.utf8(dir))?
		names = entries.keep_oks(|p| Path.filename(p).map_ok(Path.display)).keep_if(|n| n.ends_with(suffix))
		Ok(names.sort_with(|a, b| SpecSuite.compare_str(a, b)).map(|n| "${dir}/${n}"))
	}

	compare_str : Str, Str -> [Before, Same, After]
	compare_str = |a, b| SpecSuite.compare_bytes(a.to_utf8(), b.to_utf8())

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |a, b|
		match (a, b) {
			([], []) => Same
			([], _) => Before
			(_, []) => After
			([x, .. as xs], [y, .. as ys]) => if (x < y) Before else if (x > y) After else SpecSuite.compare_bytes(xs, ys)
		}

	## The app's own modules: everything but its entry points and the spike's
	## generated spec data.
	app_modules! : Str => Try(List(Str), _)
	app_modules! = |example| {
		files = SpecSuite.roc_files!("${SpecSuite.apps_dir}/${example}")?
		Ok(files.drop_if(|f| f.ends_with("-main.roc") or f.ends_with("Specs.roc")))
	}

	## `path` from `from_dir`, both relative to the repository root or both
	## absolute, as `..` steps and names.
	relative : Str, Str -> Str
	relative = |path, from_dir| {
		target = path.split_on("/").drop_if(|s| s == "" or s == ".")
		base = from_dir.split_on("/").drop_if(|s| s == "" or s == ".")
		common = SpecSuite.common_prefix(target, base)
		ups = List.repeat("..", base.len() - common)
		Str.join_with(ups.concat(target.drop_first(common)), "/")
	}

	common_prefix : List(Str), List(Str) -> U64
	common_prefix = |a, b| {
		var $n = 0.U64
		while $n < a.len() and $n < b.len() and a.get($n) == b.get($n) {
			$n = $n + 1
		}
		$n
	}

	# ------------------------------------------------------------- native

	## Assemble and build the native spec runner for `example`; returns its path.
	build_native! : Options, Str => Try(Str, _)
	build_native! = |o, example| {
		dir = "${o.build_dir}/native/${example}"
		SpecSuite.fresh_dir!(dir)?
		for f in SpecSuite.app_modules!(example)?.concat([SpecSuite.engine, SpecSuite.oracle, SpecSuite.html_helpers]).concat(SpecSuite.support) {
			SpecSuite.copy!(f, dir)?
		}
		platform_main = SpecSuite.relative("${o.root}/platform-test/main.roc", dir)
		main =
			\\app [target] { pf: platform "${platform_main}" }
			\\
			\\import pf.Target
			\\import SpecRunner
			\\import SpecMain
			\\
			\\target = Target.cli({ name: "${example}-specs", main!: |args| SpecRunner.main!(SpecMain.main, args) })
			\\
		Path.write_utf8!(Path.utf8("${dir}/main.roc"), main)?
		Proc.run!({ program: o.compiler, args: ["build", "--opt=dev", "main.roc", "--output=runner"], cwd: dir })?
		Ok("${dir}/runner")
	}

	spec_files! : Str => Try(List(Str), _)
	spec_files! = |example| SpecSuite.files_with!("examples-web/${example}/specs", ".scm")

	## The value of `"key":"..."` in a JSON line (no escapes inside).
	json_field : Str, Str -> Str
	json_field = |line, key|
		match line.split_on("\"${key}\":\"") {
			[_, rest, ..] => rest.split_on("\"").first() ?? ""
			_ => ""
		}

	## A failure's message, escapes left as written.
	json_message : Str -> Str
	json_message = |line|
		match line.split_on("\"message\":\"") {
			[_, rest, ..] => rest.split_on("\",\"step\":").first() ?? rest
			_ => SpecSuite.json_field(line, "status")
		}

	is_expected_failure : Str, Runner, Str -> Bool
	is_expected_failure = |example, runner, id| SpecSuite.expected_failures.any(|x| x.example == example and x.runner == runner and x.id == id)

	## Fold one runner's result lines into the tally, judging expected
	## failures.
	tally : Tally, Str, Runner, List(Str) -> Tally
	tally = |t0, example, runner, lines| {
		var $t = t0
		for line in lines.keep_if(|l| l.starts_with("{")) {
			id = SpecSuite.json_field(line, "id")
			status = SpecSuite.json_field(line, "status")
			xfail = SpecSuite.is_expected_failure(example, runner, id)
			t = $t
			$t = match status {
				"passed" if xfail => { ..t, failed: t.failed + 1, problems: t.problems.append("${example} ${Str.inspect(runner)} ${id}: passed but is listed as an expected failure; remove the entry") }
				"pending-phase3" if xfail => { ..t, failed: t.failed + 1, problems: t.problems.append("${example} ${Str.inspect(runner)} ${id}: no longer fails but is listed as an expected failure; remove the entry") }
				"passed" => { ..t, passed: t.passed + 1 }
				"pending-phase3" => { ..t, pending: t.pending + 1, pending_steps: t.pending_steps + SpecSuite.count_pending(line) }
				_ if xfail => { ..t, xfail: t.xfail + 1 }
				_ => { ..t, failed: t.failed + 1, problems: t.problems.append("${example} ${Str.inspect(runner)} ${id}: ${SpecSuite.json_message(line)}") }
			}
		}
		$t
	}

	count_pending : Str -> U64
	count_pending = |line| line.split_on("\"op\":").len() - 1

	## Run the native specs; returns the result lines.
	run_native! : Options, Str, List(Str) => Try(List(Str), _)
	run_native! = |o, runner, specs| {
		flags = if (o.pending_phase3) ["--pending-phase3"] else []
		{ stdout, .. } = Proc.output!({ program: runner, args: ["spec", "--filter", o.filter].concat(flags).concat(specs), cwd: "." })?
		Ok(Str.from_utf8_lossy(stdout).split_on("\n"))
	}

	# ------------------------------------------------------------ browser

	## Build the web platform's host once per build directory.
	build_web_platform! : Options => Try(Str, _)
	build_web_platform! = |o| {
		dir = "${o.build_dir}/wasm/platform"
		SpecSuite.fresh_dir!("${dir}/targets/wasm32")?
		Path.create_all!(Path.utf8("${dir}/host"))?
		SpecSuite.copy!("${SpecSuite.web_platform_dir}/main.roc", dir)?
		SpecSuite.copy!(SpecSuite.engine, dir)?
		SpecSuite.copy!("${SpecSuite.web_platform_dir}/host/host.zig", "${dir}/host")?
		Proc.run!({ program: o.zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: dir })?
		Ok(dir)
	}

	## Assemble and build `example` for the browser; returns the Wasm path.
	build_wasm! : Options, Str => Try(Str, _)
	build_wasm! = |o, example| {
		dir = "${o.build_dir}/wasm/${example}"
		SpecSuite.fresh_dir!(dir)?
		for f in SpecSuite.app_modules!(example)?.concat([SpecSuite.engine, SpecSuite.html_helpers]) {
			SpecSuite.copy!(f, dir)?
		}
		main =
			\\app [Instance, main] { pf: platform "../platform/main.roc" }
			\\
			\\import Engine
			\\import SpecMain
			\\
			\\Instance : Engine.App
			\\
			\\main = SpecMain.main
			\\
		Path.write_utf8!(Path.utf8("${dir}/main.roc"), main)?
		Proc.run!({ program: o.compiler, args: ["build", "--target=wasm32", "--opt=size", "main.roc", "--output=app.wasm"], cwd: dir })?
		Ok("${dir}/app.wasm")
	}

	## Emit the parsed steps with the native runner, then replay them in
	## Chrome; returns the replay's result lines.
	run_browser! : Options, Str, Str, Str, List(Str) => Try(List(Str), _)
	run_browser! = |o, example, runner, wasm, specs| {
		steps = Proc.capture!({ program: runner, args: ["spec", "--emit-steps", "--filter", o.filter].concat(specs), cwd: "." })?
		steps_file = "${o.build_dir}/wasm/${example}/steps.jsonl"
		Path.write_bytes!(Path.utf8(steps_file), steps)?
		flags = if (o.pending_phase3) ["--pending-phase3"] else []
		{ stdout, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", SpecSuite.runtime, "--steps", steps_file, "--chrome", o.chrome, "--json-lines"].concat(flags), cwd: "." })?
		Ok(Str.from_utf8_lossy(stdout).split_on("\n"))
	}

	# --------------------------------------------------------------- report

	summary : Str, Runner, Tally -> Str
	summary = |example, runner, t| "${example} (${Str.inspect(runner)}): ${t.passed.to_str()} passed, ${t.failed.to_str()} failed, ${t.xfail.to_str()} expected failures, ${t.pending.to_str()} pending-phase3 (${t.pending_steps.to_str()} work steps pending)"
}

## Relative paths count the steps up from the build directory.
expect SpecSuite.relative("platform-test/main.roc", ".build/native/kanban-board") == "../../../platform-test/main.roc"

## Absolute paths share their common prefix.
expect SpecSuite.relative("/r/platform-test/main.roc", "/tmp/b/native/x") == "../../../../r/platform-test/main.roc"

## Result lines are tallied, and expected failures must still fail.
expect {
	lines = [
		"{\"protocol\":\"roc-signals/spec-result/v2\",\"id\":\"a\",\"name\":\"A\",\"status\":\"passed\"}",
		"{\"id\":\"b\",\"status\":\"pending-phase3\",\"pending_steps\":[{\"op\":\"mark-metrics\",\"line\":1},{\"op\":\"expect-metric-delta\",\"line\":2}]}",
		"{\"id\":\"adding-a-number-field\",\"status\":\"failed\",\"failure\":{\"message\":\"x\"}}",
		"specs: summary on stderr is ignored",
	]
	t = SpecSuite.tally(SpecSuite.empty_tally, "form-builder", Browser, lines)
	actual = [t.passed, t.pending, t.pending_steps, t.xfail, t.failed]
	actual == [1, 1, 2, 1, 0]
}

## An expected failure that passes is itself a failure.
expect {
	t = SpecSuite.tally(SpecSuite.empty_tally, "form-builder", Browser, ["{\"id\":\"adding-a-number-field\",\"status\":\"passed\"}"])
	t.failed == 1 and t.problems.len() == 1
}
