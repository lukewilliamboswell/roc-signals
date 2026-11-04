import cli.Path
import Proc

## Builds the ported apps for the native and the browser spec runners and runs
## their `.scm` specs. Each app's `main-test.roc` (test platform) and
## `main-web.roc` (web platform) are built in place; both platforms are roots
## of `platform/` and share its `Engine.roc`.
SpecSuite := [].{
	runtime = "platform/runtime.mjs"

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

	# ------------------------------------------------------------- native

	## The native spec runner of `example` (built by `build!`).
	runner_of : Options, Str -> Str
	runner_of = |o, example| "${o.build_dir}/native/${example}/runner"

	## The browser build of an app or test app (built by `build!`).
	wasm_of : Options, Str -> Str
	wasm_of = |o, name| "${o.build_dir}/wasm/${name}/app.wasm"

	## A build of the app or test app `main` (`main-test.roc` or
	## `main-web.roc`) at optimisation level `opt`.
	build_job : Options, Str, Str, Str, Str -> Proc.Job
	build_job = |o, opt, main, target, output| {
		program: o.compiler,
		args: ["build", "--opt=${opt}"].concat(if (target == "") [] else ["--target=${target}"]).concat([main, "--output=${output}"]),
		cwd: o.root,
	}

	## Build, in parallel (bounded by the CPU count), the native runners of
	## `natives` and the browser builds of `webs` (app names, or
	## `tests/apps/NAME` for a test app). A failed build is an error.
	build! : Options, List(Str), List(Str) => Try({}, _)
	build! = |o, natives, webs| SpecSuite.build_with!(o, natives, webs, "dev")

	## `build!` with the browser builds at optimisation level `web_opt`. The
	## soak measures the memory of the shipping artifact, so it builds with
	## `size`; everything else tests behaviour and builds with `dev`.
	build_with! : Options, List(Str), List(Str), Str => Try({}, _)
	build_with! = |o, natives, webs, web_opt| {
		var $jobs = []
		for example in natives {
			Path.create_all!(Path.utf8("${o.build_dir}/native/${example}"))?
			$jobs = $jobs.append(SpecSuite.build_job(o, "dev", "${SpecSuite.dir_of(example)}/main-test.roc", "", SpecSuite.runner_of(o, example)))
		}
		for w in webs {
			name = w.split_on("/").last() ?? w
			dir = if (w.starts_with("tests/apps/")) w else SpecSuite.dir_of(w)
			Path.create_all!(Path.utf8("${o.build_dir}/wasm/${name}"))?
			$jobs = $jobs.append(SpecSuite.build_job(o, web_opt, "${dir}/main-web.roc", "wasm32", SpecSuite.wasm_of(o, name)))
		}
		results = Proc.parallel!($jobs, Proc.cpus!())?
		failed = List.map2($jobs, results, |job, r| (job, r.code)).keep_if(|(_, code)| code != 0)
		match failed.first() {
			Ok((job, code)) => Err(BuildFailed("${Proc.show(job)} exited with ${code.to_str()}"))
			Err(_) => Ok({})
		}
	}

	## Where an app lives.
	dir_of : Str -> Str
	dir_of = |example| "examples/${example}"

	spec_files! : Str => Try(List(Str), _)
	spec_files! = |example| SpecSuite.files_with!("${SpecSuite.dir_of(example)}/specs", ".scm")

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

	## Build the web platform's host into `platform/targets` (ignored).
	build_web_platform! : Options => Try({}, _)
	build_web_platform! = |o| {
		Path.create_all!(Path.utf8("${o.root}/platform/targets/wasm32"))?
		Proc.run!({ program: o.zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: "${o.root}/platform" })
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
