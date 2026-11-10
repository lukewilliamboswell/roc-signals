import cli.Path
import Proc

## Builds the ported apps for the native and the browser spec runners and runs
## their `.scm` specs. Each app's one entry, `main.roc`, is built twice from
## the one platform: `--target=x64musl` gives its native spec runner and
## `--target=wasm32` its browser module.
SpecSuite := [].{
	runtime = "platform/runtime.mjs"

	## The runtime's files in `platform/`: the runtime and the worker script
	## it loads from beside itself. Every place that serves or ships the
	## runtime copies all of them side by side (`copy_runtime!`); the browser
	## tests serve the same list (`tests/browser/args.mjs`).
	runtime_files : List(Str)
	runtime_files = ["runtime.mjs", "worker.mjs"]

	## Copy every runtime file from `root`'s `platform/` into `dir`.
	copy_runtime! : Str, Str => Try({}, _)
	copy_runtime! = |root, dir| {
		for f in SpecSuite.runtime_files {
			Path.copy!(Path.utf8("${root}/platform/${f}"), Path.utf8("${dir}/${f}"))?
		}
		Ok({})
	}

	## The apps ported to the engine, with their original specs.
	apps : List(Str)
	apps = ["form-builder", "kanban-board", "data-grid", "markdown-editor", "conduit", "field-notes", "status-page", "spreadsheet-lite", "worker-lab", "csv-converter"]

	## Test apps under `tests/apps/` whose `specs/` run like an app's: the
	## browser services, work counters, worker jobs (byte-level and typed) and
	## superseding effect sites the examples do not exercise.
	test_apps : List(Str)
	test_apps = ["services", "workers", "worker-typed", "supersede", "worker-search", "files", "file-effects", "prepared", "ports", "tasks"]

	## Every spec-bearing app, examples first.
	spec_apps : List(Str)
	spec_apps = SpecSuite.apps.concat(SpecSuite.test_apps)

	Runner : [Native, Browser]

	## Every spec must pass in both runners: there is no list of expected
	## failures, because the runners agree on every step (design.md, "The
	## `.scm` spec language").
	Tally : { passed : U64, failed : U64, problems : List(Str) }

	empty_tally : Tally
	empty_tally = { passed: 0, failed: 0, problems: [] }

	## `root` and `build_dir` are absolute.
	Options : { root : Str, build_dir : Str, compiler : Str, tooling : Str, zig : Str, node : Str, chrome : Str, filter : Str }

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

	## Every file ending in `suffix` under `dir`, at any depth.
	files_under! : Str, Str => Try(List(Str), _)
	files_under! = |dir, suffix| {
		var $out = []
		for entry in Path.list!(Path.utf8(dir))? {
			name = Path.display(entry)
			if Path.is_dir!(entry)? {
				$out = $out.concat(SpecSuite.files_under!(name, suffix)?)
			} else if name.ends_with(suffix) {
				$out = $out.append(name)
			}
		}
		Ok($out)
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

	## The target the platform's native spec runner builds for.
	native_target = "x64musl"

	## The native spec runner of `example` (built by `build!`).
	runner_of : Options, Str -> Str
	runner_of = |o, example| "${o.build_dir}/native/${example}/runner"

	## The browser build of an app or test app (built by `build!`).
	wasm_of : Options, Str -> Str
	wasm_of = |o, name| "${o.build_dir}/wasm/${name}/app.wasm"

	## A build of an app's `main.roc` for `target` at optimisation level `opt`.
	build_job : Options, Str, Str, Str, Str -> Proc.Job
	build_job = |o, opt, main, target, output| {
		program: o.compiler,
		args: ["build", "--opt=${opt}", "--target=${target}", main, "--output=${output}"],
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
			$jobs = $jobs.append(SpecSuite.build_job(o, "dev", "${SpecSuite.dir_of(example)}/main.roc", SpecSuite.native_target, SpecSuite.runner_of(o, example)))
		}
		for w in webs {
			name = w.split_on("/").last() ?? w
			dir = if (w.starts_with("tests/apps/")) w else SpecSuite.dir_of(w)
			Path.create_all!(Path.utf8("${o.build_dir}/wasm/${name}"))?
			$jobs = $jobs.append(SpecSuite.build_job(o, web_opt, "${dir}/main.roc", "wasm32", SpecSuite.wasm_of(o, name)))
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
	dir_of = |example| if (SpecSuite.test_apps.contains(example)) "tests/apps/${example}" else "examples/${example}"

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

	## Fold one runner's result lines into the tally.
	tally : Tally, Str, Runner, List(Str) -> Tally
	tally = |t0, example, runner, lines| {
		var $t = t0
		for line in lines.keep_if(|l| l.starts_with("{")) {
			id = SpecSuite.json_field(line, "id")
			status = SpecSuite.json_field(line, "status")
			t = $t
			$t = match status {
				"passed" => { ..t, passed: t.passed + 1 }
				_ => { ..t, failed: t.failed + 1, problems: t.problems.append("${example} ${Str.inspect(runner)} ${id}: ${SpecSuite.json_message(line)}") }
			}
		}
		$t
	}

	## Run the native specs; returns the result lines.
	run_native! : Options, Str, List(Str) => Try(List(Str), _)
	run_native! = |o, runner, specs| {
		{ stdout, .. } = Proc.output!({ program: runner, args: ["--filter", o.filter].concat(specs), cwd: "." })?
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
		# A spec the parser refuses is emitted as an error line (and the
		# command exits 1); the replay reports it as failed.
		{ stdout: steps, .. } = Proc.output!({ program: runner, args: ["--emit-steps", "--filter", o.filter].concat(specs), cwd: "." })?
		steps_file = "${o.build_dir}/wasm/${example}/steps.jsonl"
		Path.write_bytes!(Path.utf8(steps_file), steps)?
		{ stdout, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", SpecSuite.runtime, "--steps", steps_file, "--chrome", o.chrome, "--json-lines"], cwd: "." })?
		Ok(Str.from_utf8_lossy(stdout).split_on("\n"))
	}

	# --------------------------------------------------------------- report

	summary : Str, Runner, Tally -> Str
	summary = |example, runner, t| "${example} (${Str.inspect(runner)}): ${t.passed.to_str()} passed, ${t.failed.to_str()} failed"
}

## Result lines are tallied; anything but a pass is a failure with its message.
expect {
	lines = [
		"{\"protocol\":\"roc-signals/spec-result/v2\",\"id\":\"a\",\"name\":\"A\",\"status\":\"passed\"}",
		"{\"id\":\"b\",\"status\":\"failed\",\"failure\":{\"message\":\"y\"}}",
		"specs: summary on stderr is ignored",
	]
	t = SpecSuite.tally(SpecSuite.empty_tally, "form-builder", Browser, lines)
	actual = [t.passed, t.failed, t.problems.len()]
	actual == [1, 1, 1]
}
