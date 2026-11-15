import cli.Path
import CompilerSkips
import Proc

## Builds the apps for the native and the browser spec runners and runs
## their `.scm` specs. Each app's one entry, `main.roc`, is built twice from
## the one platform: `--target=x64musl` (or the system's own target, see
## `native_targets`) gives its native spec runner and
## `--target=wasm32` its browser module.
SpecSuite := [].{
	runtime = "platform/runtime.mjs"

	## The runtime's files in `platform/`: the runtime, its fact readers and the worker script
	## it loads from beside itself. Every place that serves or ships the
	## runtime copies all of them side by side (`copy_runtime!`); the browser
	## tests serve the same list (`tests/browser/args.mjs`).
	runtime_files : List(Str)
	runtime_files = ["runtime.mjs", "worker.mjs", "environment.mjs"]

	## Copy every runtime file from `root`'s `platform/` into `dir`.
	copy_runtime! : Str, Str => Try({}, _)
	copy_runtime! = |root, dir| {
		for f in SpecSuite.runtime_files {
			Path.copy!(Path.utf8("${root}/platform/${f}"), Path.utf8("${dir}/${f}"))?
		}
		Ok({})
	}

	## The examples under `examples/`, each with its specs.
	apps : List(Str)
	apps = ["form-builder", "kanban-board", "data-grid", "markdown-editor", "conduit", "field-notes", "status-page", "spreadsheet-lite", "worker-lab", "csv-converter", "reading-list", "log-explorer", "million-row-explorer"]

	## Test apps under `tests/apps/` whose `specs/` run like an app's: the
	## browser services, work counters, worker jobs (byte-level and typed) and
	## superseding effect sites the examples do not exercise.
	test_apps : List(Str)
	test_apps = ["services", "workers", "worker-typed", "supersede", "worker-search", "files", "file-effects", "prepared", "ports", "tasks", "gather", "outbox", "deep", "deep-payload", "handlers", "remount", "store", "writes", "table", "controls", "write-scaling", "keep-current", "signal-text", "markup", "namespaces", "construction", "prerender", "dbg", "dbg-job-only"]

	## Every spec-bearing app, examples first.
	spec_apps : List(Str)
	spec_apps = SpecSuite.apps.concat(SpecSuite.test_apps)

	## Every example and test app: each directory under `examples/` and
	## `tests/apps/` that holds a `main.roc`, with or without specs.
	app_dirs! : () => Try(List(Str), _)
	app_dirs! = || {
		var $out = []
		for parent in ["examples", "tests/apps"] {
			var $names = []
			for entry in Path.list!(Path.utf8(parent))? {
				if Path.is_dir!(entry)? and Path.exists!(Path.utf8("${Path.display(entry)}/main.roc"))? {
					$names = $names.append(Path.display(entry))
				}
			}
			$out = $out.concat($names.sort_with(SpecSuite.compare_str))
		}
		Ok($out)
	}

	## How many specs each spec-bearing directory holds: every app under
	## `examples/` and `tests/apps/` with a `specs/` directory, as
	## `listing_problems` compares them with the lists.
	spec_dirs! : () => Try(List({ dir : Str, specs : U64 }), _)
	spec_dirs! = || {
		var $out = []
		for parent in ["examples", "tests/apps"] {
			for entry in Path.list!(Path.utf8(parent))? {
				dir = Path.display(entry)
				if Path.is_dir!(entry)? and Path.is_dir!(Path.utf8("${dir}/specs")) ?? Bool.False {
					$out = $out.append({ dir, specs: SpecSuite.files_with!("${dir}/specs", ".scm")?.len() })
				}
			}
		}
		Ok($out)
	}

	## The `check` stage over the tree: every directory with specs is an app
	## the lists name, and every app they name has specs.
	listing! : () => Try(List(Str), _)
	listing! = || Ok(SpecSuite.listing_problems({ examples: SpecSuite.apps, tests: SpecSuite.test_apps, found: SpecSuite.spec_dirs!()? }))

	## What is wrong between the spec-bearing directories `found` and the
	## lists: a directory whose specs no list names never runs, and a listed
	## app with no specs passes having checked nothing.
	listing_problems : { examples : List(Str), tests : List(Str), found : List({ dir : Str, specs : U64 }) } -> List(Str)
	listing_problems = |{ examples, tests, found }| {
		listed = examples.map(|a| { dir: "examples/${a}", name: a, list: "SpecSuite.apps" }).concat(tests.map(|a| { dir: "tests/apps/${a}", name: a, list: "SpecSuite.test_apps" }))
		unlisted = found.keep_if(|f| f.specs > 0 and !listed.any(|l| l.dir == f.dir)).map(|f| "${f.dir}/specs holds specs, but neither SpecSuite.apps nor SpecSuite.test_apps names the app, so no run checks them")
		empty = listed.keep_if(|l| !found.any(|f| f.dir == l.dir and f.specs > 0)).map(|l| "${l.list} names ${l.name}, but ${l.dir}/specs holds no spec, so its runs would pass having checked nothing")
		names = examples.concat(tests)
		twice = names.keep_if(|n| names.count_if(|m| m == n) > 1).fold([], |acc, n| if (acc.contains(n)) acc else acc.append(n)).map(|n| "the spec lists name ${n} more than once")
		unlisted.concat(empty).concat(twice)
	}

	## A run that selected no spec at all is a mistake, never a pass: a
	## filter that matches nothing, or apps with no specs.
	selection_problems : Str, U64 -> List(Str)
	selection_problems = |filter, selected| if (selected == 0) ["the filter ${Str.inspect(filter)} selects no spec in the apps run, so nothing was checked: a filter that matches nothing is a mistake"] else []

	Runner : [Native, Browser]

	## Every spec must pass in both runners: there is no list of expected
	## failures, because the runners agree on every step (design.md, "The
	## `.scm` spec language"). `unreported` counts the selected specs a
	## runner gave no result for, each of which is also a problem: a run that
	## stops early must never read as a shorter run that passed.
	## `skipped` counts the selected specs a compiler-keyed skip kept from a
	## runner (`CompilerSkips`): selected = passed + failed + skipped, and a
	## skip is never a pass.
	Tally : { passed : U64, failed : U64, skipped : U64, unreported : U64, problems : List(Str) }

	empty_tally : Tally
	empty_tally = { passed: 0, failed: 0, skipped: 0, unreported: 0, problems: [] }

	## Two tallies as one, problems in order.
	add : Tally, Tally -> Tally
	add = |a, b| {
		passed: a.passed + b.passed,
		failed: a.failed + b.failed,
		skipped: a.skipped + b.skipped,
		unreported: a.unreported + b.unreported,
		problems: a.problems.concat(b.problems),
	}

	## One invocation of a runner as the suite sees it: the exit code the
	## process returned and the lines of its standard output. A runner ended
	## by a signal never becomes a `Run`: `Proc.output!` fails the stage.
	Run : { code : I32, lines : List(Str) }

	## Which invocation a run was. `Native` is the native runner's results;
	## `Emit` is the native runner's `--emit-steps`, one steps line per
	## parsed spec and one `error` result line per refused one; `Replay` is
	## `tests/browser/replay.mjs --json-lines`, one result line per spec it
	## was given, a refused spec's passed through as failed.
	Stage : [Native, Emit, Replay]

	## `root` and `build_dir` are absolute. `target` is the system the
	## native spec runners are built for, one of `native_targets`.
	Options : { root : Str, build_dir : Str, compiler : Str, nightly : Str, tooling : Str, zig : Str, node : Str, chrome : Str, filter : Str, target : Str }

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

	## The systems the platform's native spec runner builds for: Linux
	## x86-64, macOS on Apple silicon and on Intel, and Windows x86-64. The
	## pull-request gate builds for `x64musl`, as CI runs on Linux; `spec.roc`
	## builds for the system it runs on (`host_target`) unless told otherwise.
	native_targets : List(Str)
	native_targets = ["x64musl", "arm64mac", "x64mac", "x64win"]

	## The native target of the system `uname -sm` describes (its output,
	## surrounding white space ignored), or `Unknown` for a system the
	## runner does not build for. Only the kernel's name and the machine
	## decide: `Darwin arm64` is `arm64mac`, `Linux x86_64` is `x64musl`.
	host_target : Str -> Try(Str, [Unknown(Str)])
	host_target = |uname|
		match uname.trim().split_on(" ").drop_if(|w| w.is_empty()) {
			["Darwin", "arm64"] => Ok("arm64mac")
			["Darwin", "x86_64"] => Ok("x64mac")
			["Linux", "x86_64"] => Ok("x64musl")
			_ => Err(Unknown(uname.trim()))
		}

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
			$jobs = $jobs.append(SpecSuite.build_job(o, "dev", "${SpecSuite.dir_of(example)}/main.roc", o.target, SpecSuite.runner_of(o, example)))
		}
		for w in webs {
			name = w.split_on("/").last() ?? w
			dir = if (w.starts_with("tests/apps/")) w else SpecSuite.dir_of(w)
			Path.create_all!(Path.utf8("${o.build_dir}/wasm/${name}"))?
			$jobs = $jobs.append(SpecSuite.build_job(o, web_opt, "${dir}/main.roc", "wasm32", SpecSuite.wasm_of(o, name)))
		}
		results = Proc.parallel!($jobs, Proc.compiler_jobs!(App)?)?
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

	## A spec's id, as every runner reports it: its file name without the
	## directory or `.scm` (`SpecRunner.id_of`).
	id_of : Str -> Str
	id_of = |path| (path.split_on("/").last() ?? path).drop_suffix(".scm")

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

	## The verdict on one run of `expected` (the ids of the specs the run
	## was given, in order): its result lines tallied, and a problem for
	## anything the run does not account for. The run must give exactly one
	## line for each expected id and none for any other id, and its exit
	## code must be one the runner returns for the lines it printed: 0 when
	## every line passed, 1 when at least one reported a failure. A runner
	## that stops early (the native runner exits with 70 on a crash and 71
	## on a failed `expect`, before it prints the spec's result) or a replay
	## that never started therefore fails the suite, naming the exit code
	## and every spec it left without a result. A failure the runner
	## reported is a problem of its own, as before. An `Emit` run's lines
	## are not tallied: a spec the parser refused is counted when the replay
	## reports it as failed.
	judge : { example : Str, stage : Stage, expected : List(Str), run : Run } -> Tally
	judge = |{ example, stage, expected, run }| {
		label = match stage {
			Native => "${example} Native"
			Emit => "${example} Browser (emit)"
			Replay => "${example} Browser"
		}
		var $t = SpecSuite.empty_tally
		var $ids = []
		var $failures = 0.U64
		for line in run.lines.keep_if(|l| l.starts_with("{")) {
			t = $t
			id = SpecSuite.json_field(line, "id")
			if line.starts_with("{\"protocol\":\"roc-signals/spec-result/v2\",") {
				$ids = $ids.append(id)
				passed = SpecSuite.json_field(line, "status") == "passed"
				if !passed {
					$failures = $failures + 1
				}
				$t = match (stage, passed) {
					(Emit, _) => t
					(_, Bool.True) => { ..t, passed: t.passed + 1 }
					(_, Bool.False) => { ..t, failed: t.failed + 1, problems: t.problems.append("${label} ${id}: ${SpecSuite.json_message(line)}") }
				}
			} else if stage == Emit and line.starts_with("{\"id\":\"") {
				$ids = $ids.append(id)
			} else {
				$t = { ..t, problems: t.problems.append("${label}: output line is not a result: ${line}") }
			}
		}
		ids = $ids
		missing = expected.drop_if(|id| ids.contains(id))
		unknown = ids.drop_if(|id| expected.contains(id))
		repeated = expected.keep_if(|id| ids.count_if(|seen| seen == id) > 1)
		legitimate = (run.code == 0 and $failures == 0) or (run.code == 1 and $failures > 0)
		reported = ids.len() - unknown.len()
		problems = []
			.concat(if (legitimate) [] else ["${label}: exited with ${run.code.to_str()}${exit_meaning(stage, run.code, $failures)} after giving results for ${reported.to_str()} of ${expected.len().to_str()} specs"])
			.concat(if (missing.is_empty()) [] else ["${label}: no result for ${Str.join_with(missing, ", ")}"])
			.concat(if (unknown.is_empty()) [] else ["${label}: a result for ${Str.join_with(unknown, ", ")}, which the run was not given"])
			.concat(if (repeated.is_empty()) [] else ["${label}: more than one result for ${Str.join_with(repeated, ", ")}"])
		t = $t
		{ ..t, unreported: missing.len(), problems: t.problems.concat(problems) }
	}

	## Run `specs` (paths) with the native runner `runner`, keeping its exit
	## code and its standard output for `judge`. Its standard error (the
	## runner's summary, a crash's message, `dbg` output) passes through to
	## the log, where the message of a crash `judge` reports can be read.
	run_native! : Str, List(Str) => Try(Run, _)
	run_native! = |runner, specs| {
		{ code, stdout } = Proc.output!({ program: runner, args: specs, cwd: "." })?
		Ok({ code, lines: Str.from_utf8_lossy(stdout).split_on("\n") })
	}

	## Run `specs` (paths of `example`'s specs) with its native runner and
	## judge the run.
	native_specs! : { example : Str, runner : Str, specs : List(Str) } => Try(Tally, _)
	native_specs! = |{ example, runner, specs }|
		if specs.is_empty() {
			Ok(SpecSuite.empty_tally)
		} else {
			run = SpecSuite.run_native!(runner, specs)?
			Ok(SpecSuite.judge({ example, stage: Native, expected: specs.map(SpecSuite.id_of), run }))
		}

	## The specs of `example` the filter `pattern` selects: those whose id it
	## matches, `*` standing for any run of bytes and `?` for any one (the
	## native runner's `--filter`). The suite selects here and hands the
	## runner exactly the files it expects results for.
	select : Str, List(Str) -> List(Str)
	select = |pattern, specs| specs.keep_if(|path| glob(pattern.to_utf8(), SpecSuite.id_of(path).to_utf8()))

	# ------------------------------------------------------------ browser

	## Build the web platform's host into `platform/targets` (ignored).
	build_web_platform! : Options => Try({}, _)
	build_web_platform! = |o| {
		Path.create_all!(Path.utf8("${o.root}/platform/targets/wasm32"))?
		Proc.run!({ program: o.zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: "${o.root}/platform" })
	}

	## Emit the parsed steps of `specs` with the native runner into
	## `steps_file`, then replay them in Chrome, and judge both runs. A spec
	## the parser refuses is emitted as an error line (and the emit exits
	## 1); the replay reports it as failed. The replay is given only the
	## specs the emit gave a line for, so a spec the emit lost is reported
	## once, by the emit's verdict; when it gave none, nothing is replayed.
	## The specs whose ids are in `skip` are emitted but not replayed; the
	## caller accounts for them (`active_skips`).
	browser_specs! : Options, { example : Str, runner : Str, wasm : Str, specs : List(Str), skip : List(Str) } => Try(Tally, _)
	browser_specs! = |o, { example, runner, wasm, specs, skip }| {
		if specs.is_empty() {
			return Ok(SpecSuite.empty_tally)
		}
		expected = specs.map(SpecSuite.id_of)
		steps_file = "${wasm}.steps.jsonl"
		emit = Proc.output!({ program: runner, args: ["--emit-steps"].concat(specs), cwd: "." })?
		emit_run = { code: emit.code, lines: Str.from_utf8_lossy(emit.stdout).split_on("\n") }
		kept = emit_run.lines.keep_if(|l| l.starts_with("{") and !skip.contains(SpecSuite.json_field(l, "id")))
		Path.write_utf8!(Path.utf8(steps_file), Str.join_with(kept.map(|l| "${l}\n"), ""))?
		emitted = SpecSuite.judge({ example, stage: Emit, expected, run: emit_run })
		given = kept.map(|l| SpecSuite.json_field(l, "id"))
		replayed = expected.keep_if(|id| given.contains(id))
		if replayed.is_empty() {
			return Ok(emitted)
		}
		{ code, stdout } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", SpecSuite.runtime, "--steps", steps_file, "--chrome", o.chrome, "--json-lines"], cwd: "." })?
		replay = SpecSuite.judge({ example, stage: Replay, expected: replayed, run: { code, lines: Str.from_utf8_lossy(stdout).split_on("\n") } })
		Ok(SpecSuite.add(emitted, replay))
	}

	# --------------------------------------------------------------- report

	summary : Str, Runner, Tally -> Str
	summary = |example, runner, t| {
		unreported = if (t.unreported == 0) "" else ", ${t.unreported.to_str()} without a result"
		skipped = if (t.skipped == 0) "" else ", ${t.skipped.to_str()} skipped"
		"${example} (${Str.inspect(runner)}): ${t.passed.to_str()} passed, ${t.failed.to_str()} failed${skipped}${unreported}"
	}

	# ---------------------------------------------------------------- skips

	## The skips of `skips` that keep specs of `example` among `selected`
	## (ids) from its Chrome run on a development Wasm built by `nightly`:
	## those whose compilers list `nightly` exactly. A skip naming a spec
	## `example` does not have (`known`, every spec id of the app) is an
	## error on every compiler, so a renamed spec cannot leave a skip that
	## silently means nothing.
	active_skips : { skips : List(CompilerSkips.Skip), nightly : Str, example : Str, known : List(Str), selected : List(Str) } -> Try(List(CompilerSkips.Skip), Str)
	active_skips = |{ skips, nightly, example, known, selected }| {
		mine = skips.keep_if(|skip| skip.example == example)
		match mine.find_first(|skip| !known.contains(skip.spec)) {
			Ok(stale) => Err("CompilerSkips names ${example}/${stale.spec}, which is not a spec of ${example}; remove or correct the entry")
			Err(_) => Ok(mine.keep_if(|skip| skip.compilers.contains(nightly) and selected.contains(skip.spec)))
		}
	}

	## The line the suite prints for a skip it applies.
	skip_line : Str, CompilerSkips.Skip -> Str
	skip_line = |nightly, skip| "SKIP ${skip.example}/${skip.spec} (Chrome, development Wasm): ${skip.issue} (${skip.link}), ${skip.reason} on ${nightly}; it still runs natively and on an --opt=size build. Remove the entry in scripts/src/CompilerSkips.roc when a nightly fixes it"
}

## What an exit code the verdict refuses means, for its problem. The native
## runner and its emit return 70 when Roc crashes (an engine contract error,
## an app's `crash`) and 71 when an `expect` fails outside a worker job
## (`platform/host/spec.zig`), and 2 for a usage error or a host failure;
## the replay returns 1 when it throws (Chrome did not start, a step had no
## handler).
exit_meaning : Stage, I32, U64 -> Str
exit_meaning = |stage, code, failures|
	match (stage, code) {
		(_, 0) => ", which says every spec passed, though ${failures.to_str()} reported a failure,"
		(Replay, 1) => ", which it returns when a spec failed or when the replay itself threw, but it reported no failure,"
		(_, 1) => ", which it returns when a spec failed, but it reported no failure,"
		(Replay, _) => ""
		(_, 70) => " (Roc crashed: an engine contract error or an app's crash)"
		(_, 71) => " (an expect failed outside a worker job)"
		(_, 2) => " (a usage error or a host failure)"
		_ => ""
	}

## Shell-style matching over bytes, as the native runner's `--filter`
## matches (`SpecRunner.glob_bytes`).
glob : List(U8), List(U8) -> Bool
glob = |pattern, text|
	match pattern {
		[] => text.is_empty()
		['*', .. as rest] => glob(rest, text) or (!text.is_empty() and glob(pattern, text.drop_first(1)))
		['?', .. as rest] => !text.is_empty() and glob(rest, text.drop_first(1))
		[c, .. as rest] => text.first() == Ok(c) and glob(rest, text.drop_first(1))
	}

## A result line, as a runner prints it, for the tests below.
result_line : Str, Str -> Str
result_line = |id, status| "{\"protocol\":\"roc-signals/spec-result/v2\",\"id\":\"${id}\",\"name\":\"N\",\"status\":\"${status}\",\"duration_ns\":0,\"failure\":${if (status == "passed") "null" else "{\"phase\":\"step\",\"kind\":\"assertion\",\"message\":\"wrong ${id}\",\"step\":0}"}}"

## A verdict as one comparable record: counts, then every problem.
verdict : SpecSuite.Stage, List(Str), I32, List(Str) -> SpecSuite.Tally
verdict = |stage, expected, code, lines| SpecSuite.judge({ example: "app", stage, expected, run: { code, lines } })

## Every selected spec passed and the runner exited 0: nothing to report, and
## a summary line on stderr or a blank line is not a result.
expect verdict(Native, ["a", "b"], 0, [result_line("a", "passed"), result_line("b", "passed"), "", "specs: 2 passed"]) == { passed: 2, failed: 0, skipped: 0, unreported: 0, problems: [] }

## A failure the runner reported, with the exit code it returns for one, is
## that failure and nothing more.
expect verdict(Native, ["a", "b"], 1, [result_line("a", "passed"), result_line("b", "failed")]) == { passed: 1, failed: 1, skipped: 0, unreported: 0, problems: ["app Native b: wrong b"] }

## A crash (exit 70) after two of five specs gave results fails the suite,
## naming the exit code and the three specs left without a result.
expect {
	actual = verdict(Native, ["a", "b", "c", "d", "e"], 70, [result_line("a", "passed"), result_line("b", "passed")])
	expected = {
		passed: 2,
		failed: 0,
		skipped: 0,
		unreported: 3,
		problems: [
			"app Native: exited with 70 (Roc crashed: an engine contract error or an app's crash) after giving results for 2 of 5 specs",
			"app Native: no result for c, d, e",
		],
	}
	actual == expected
}

## A failed `expect` (exit 71) is named too.
expect verdict(Native, ["a"], 71, []).problems == ["app Native: exited with 71 (an expect failed outside a worker job) after giving results for 0 of 1 specs", "app Native: no result for a"]

## Exit 0 with a spec missing is not a pass: the missing spec is named.
expect verdict(Native, ["a", "b"], 0, [result_line("a", "passed")]).problems == ["app Native: no result for b"]

## A result for a spec the run was not given, or two for one, is a problem.
expect {
	actual = verdict(Native, ["a"], 0, [result_line("a", "passed"), result_line("z", "passed"), result_line("a", "passed")]).problems
	actual == ["app Native: a result for z, which the run was not given", "app Native: more than one result for a"]
}

## A run that printed nothing accounts for none of its specs; a run given no
## specs that printed nothing accounts for all of them.
expect {
	actual = [verdict(Native, ["a", "b"], 0, []).problems, verdict(Native, [], 0, []).problems]
	actual == [["app Native: no result for a, b"], []]
}

## Exit codes that contradict the lines: 1 with every spec passed, 0 with a
## failure reported.
expect {
	actual = [verdict(Native, ["a"], 1, [result_line("a", "passed")]).problems, verdict(Native, ["a"], 0, [result_line("a", "failed")]).problems]
	expected = [
		["app Native: exited with 1, which it returns when a spec failed, but it reported no failure, after giving results for 1 of 1 specs"],
		["app Native a: wrong a", "app Native: exited with 0, which says every spec passed, though 1 reported a failure, after giving results for 1 of 1 specs"],
	]
	actual == expected
}

## The emit step exits 1 with an error line for a spec the parser refused and
## a steps line for each other: that is a reported failure, which the replay
## counts, not a fault of the suite; the emit itself tallies nothing.
expect {
	steps = "{\"id\":\"a\",\"name\":\"A\",\"setup\":[],\"steps\":[{\"op\":\"click\",\"id\":\"x\"}]}"
	actual = verdict(Emit, ["a", "b"], 1, [steps, result_line("b", "error")])
	actual == { passed: 0, failed: 0, skipped: 0, unreported: 0, problems: [] }
}

## An emit that crashed after one spec loses the rest, named as missing.
expect verdict(Emit, ["a", "b"], 70, ["{\"id\":\"a\",\"name\":\"A\"}"]).problems == ["app Browser (emit): exited with 70 (Roc crashed: an engine contract error or an app's crash) after giving results for 1 of 2 specs", "app Browser (emit): no result for b"]

## A replay that threw before any spec (Chrome did not start) exits 1 with no
## lines: every spec it was given is named.
expect verdict(Replay, ["a", "b"], 1, []).problems == ["app Browser: exited with 1, which it returns when a spec failed or when the replay itself threw, but it reported no failure, after giving results for 0 of 2 specs", "app Browser: no result for a, b"]

## The replay passes a refused spec's error line through as failed: one
## failure, with the exit code for one.
expect verdict(Replay, ["a"], 1, [result_line("a", "failed")]) == { passed: 0, failed: 1, skipped: 0, unreported: 0, problems: ["app Browser a: wrong a"] }

## A line that opens like JSON but is neither a result nor emitted steps is
## a problem, not silently ignored.
expect verdict(Native, [], 0, ["{\"id\":\"a\"}"]).problems == ["app Native: output line is not a result: {\"id\":\"a\"}"]

## Selection matches the spec id, not the path, with the runner's glob.
expect SpecSuite.select("add*", ["x/specs/adding-a-field.scm", "x/specs/remove.scm", "add/specs/zzz.scm"]) == ["x/specs/adding-a-field.scm"]

## `?` matches one byte and a plain pattern only itself.
expect SpecSuite.select("a?c", ["s/abc.scm", "s/ac.scm", "s/abcd.scm"]) == ["s/abc.scm"]

## The host's own target is read from `uname -sm`, on each system that has it.
expect [SpecSuite.host_target("Darwin arm64\n"), SpecSuite.host_target("Darwin x86_64"), SpecSuite.host_target("Linux x86_64\n")] == [Ok("arm64mac"), Ok("x64mac"), Ok("x64musl")]

## A system the runner does not build for is unknown, never guessed: Linux on
## Arm has no runner, and output that is not two words is not a system.
expect [SpecSuite.host_target("Linux aarch64"), SpecSuite.host_target(""), SpecSuite.host_target("Darwin arm64 extra")] == [Err(Unknown("Linux aarch64")), Err(Unknown("")), Err(Unknown("Darwin arm64 extra"))]

## A skip applies on a listed compiler only, and only to a selected spec; a
## skip naming a spec the app does not have is an error on any compiler.
expect {
	skip = { example: "files", spec: "a", runner: Browser, build: Development, compilers: ["nightly-x"], issue: "roc-lang/roc#1", link: "https://x", reason: "r" }
	other = { ..skip, example: "kanban-board", spec: "zzz" }
	active = |nightly, selected, known| SpecSuite.active_skips({ skips: [skip, other], nightly, example: "files", known, selected }).map_ok(|list| list.map(|s| s.spec))
	actual = [
		active("nightly-x", ["a", "b"], ["a", "b"]),
		active("nightly-y", ["a", "b"], ["a", "b"]),
		active("nightly-x", ["b"], ["a", "b"]),
		active("nightly-y", ["b"], ["b"]),
	]
	actual == [Ok(["a"]), Ok([]), Ok([]), Err("CompilerSkips names files/a, which is not a spec of files; remove or correct the entry")]
}

## The shipped skips name specs of their app, on the verified nightlies only.
expect CompilerSkips.skips.all(|s| s.example == "files" and s.issue == "roc-lang/roc#13020" and s.compilers == ["nightly-2026-11-13-03dce41", "nightly-2026-11-14-a87808d"])

## The summary shows a skip, which is never a pass.
expect SpecSuite.summary("files", Browser, { ..SpecSuite.empty_tally, passed: 12, skipped: 2 }) == "files (Browser): 12 passed, 0 failed, 2 skipped"

## A directory with specs that no list names, a listed app with none, an
## empty specs directory and a name listed twice are each a problem.
expect {
	found = [{ dir: "examples/a", specs: 2 }, { dir: "tests/apps/b", specs: 0 }, { dir: "tests/apps/c", specs: 1 }, { dir: "examples/z", specs: 0 }]
	problems = SpecSuite.listing_problems({ examples: ["a", "d"], tests: ["b", "a"], found })
	problems
		== [
			"tests/apps/c/specs holds specs, but neither SpecSuite.apps nor SpecSuite.test_apps names the app, so no run checks them",
			"SpecSuite.apps names d, but examples/d/specs holds no spec, so its runs would pass having checked nothing",
			"SpecSuite.test_apps names b, but tests/apps/b/specs holds no spec, so its runs would pass having checked nothing",
			"SpecSuite.test_apps names a, but tests/apps/a/specs holds no spec, so its runs would pass having checked nothing",
			"the spec lists name a more than once",
		]
}

## Lists that agree with the tree have no problem.
expect SpecSuite.listing_problems({ examples: ["a"], tests: ["c"], found: [{ dir: "examples/a", specs: 1 }, { dir: "tests/apps/c", specs: 3 }] }) == []

## A selection of no spec is a problem; any spec at all is not.
expect SpecSuite.selection_problems("nothing*", 0).len() == 1 and SpecSuite.selection_problems("*", 1) == []
