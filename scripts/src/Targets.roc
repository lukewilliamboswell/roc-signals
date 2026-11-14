import cli.Path
import cli.Monotonic
import Proc
import SpecSuite

## The roc-fuzz targets, the browser contract tests, the soak runs and the
## js-framework-benchmark check.
##
## Each target is an ordinary roc-fuzz app, whose platform is a roc-fuzz
## release the compiler fetches. Roc resolves an app's sibling modules from
## the directory of its main file, so a target lives beside the modules it
## imports:
##
## - the platform's own targets under `fuzz/` and beside the test apps under
##   `tests/apps/` (`fuzz-<subject>.roc`), which import the engine package,
##   `platform/main-fuzz.roc`, as `pf`;
## - an example's targets of its own pure logic, `fuzz-<subject>.roc`
##   beside the modules they import, which import nothing of the platform.
Targets := [].{
	Fuzz : { name : Str, main : Str }

	fuzz_targets : List(Fuzz)
	fuzz_targets = [
		{ name: "boot", main: "fuzz/boot/main.roc" },
		{ name: "scm-parse", main: "fuzz/scm-parse/main.roc" },
		{ name: "protocol-facts", main: "fuzz/protocol-facts/main.roc" },
		{ name: "wire", main: "fuzz/wire/main.roc" },
		{ name: "structure", main: "fuzz/structure/main.roc" },
		{ name: "dom", main: "fuzz/dom/main.roc" },
		{ name: "markup", main: "fuzz/markup/main.roc" },
		{ name: "table-view", main: "fuzz/table-view/main.roc" },
		{ name: "result-readers", main: "fuzz/result-readers/main.roc" },
		{ name: "port-json", main: "fuzz/port-json/main.roc" },
		{ name: "url", main: "fuzz/url/main.roc" },
		{ name: "names", main: "fuzz/names/main.roc" },
		{ name: "form-builder", main: "examples/form-builder/fuzz-rules.roc" },
		{ name: "kanban-board", main: "examples/kanban-board/fuzz-board.roc" },
		{ name: "data-grid", main: "examples/data-grid/fuzz-rows.roc" },
		{ name: "markdown-editor", main: "examples/markdown-editor/fuzz-sections.roc" },
		{ name: "markdown-html", main: "examples/markdown-editor/fuzz-html.roc" },
		{ name: "conduit", main: "examples/conduit/fuzz-routes.roc" },
		{ name: "field-notes", main: "examples/field-notes/fuzz-outbox.roc" },
		{ name: "spreadsheet-lite", main: "examples/spreadsheet-lite/fuzz-formulas.roc" },
		{ name: "fx-channel", main: "tests/apps/effects/fuzz-channel.roc" },
		{ name: "controls", main: "tests/apps/controls/fuzz-controls.roc" },
		{ name: "csv-converter", main: "examples/csv-converter/fuzz-csv.roc" },
		{ name: "log-explorer", main: "examples/log-explorer/fuzz-index.roc" },
		{ name: "log-scroll-map", main: "examples/log-explorer/fuzz-scroll-map.roc" },
		{ name: "million-row-explorer-aggregates", main: "examples/million-row-explorer/fuzz-aggregates.roc" },
	]

	## The directories a fuzz target may live in.
	target_dirs : List(Str)
	target_dirs = ["fuzz", "examples", "tests"]

	## Whether a Roc file is a fuzz target, from its path and its text: a
	## `main.roc` one directory below `fuzz/`, a file named `fuzz-<subject>.roc`,
	## or any app whose header names a roc-fuzz release as its platform.
	is_target : Str, Str -> Bool
	is_target = |path, text| {
		parts = path.split_on("/")
		name = parts.last() ?? path
		under_fuzz = parts.len() == 3 and parts.first() == Ok("fuzz") and name == "main.roc"
		header = text.split_on("\n").take_first(4)
		under_fuzz or (name.starts_with("fuzz-") and name.ends_with(".roc")) or header.any(|line| line.contains("/roc-fuzz/releases/download/"))
	}

	## A fuzz target in the tree that no task builds or replays, with the
	## reason, which `check` prints as a `SKIP` line every time it runs. This
	## is the only way to leave a target out: a target file that is neither
	## here nor in `fuzz_targets` fails `check`.
	Skipped : { main : Str, reason : Str }

	fuzz_skipped : List(Skipped)
	fuzz_skipped = []

	## The `SKIP` line printed for a target left out.
	skip_line : Skipped -> Str
	skip_line = |{ main, reason }| "SKIP fuzz target ${main}: ${reason}"

	## Every way the registry and the tree disagree: a target file neither
	## listed nor skipped, a listed or skipped file that is not a target in
	## the tree, a file both listed and skipped, a skip without a reason, and
	## any name or file listed twice. Any other task that accounts for fuzz
	## targets uses this same comparison.
	registry_problems : List(Fuzz), List(Skipped), List(Str) -> List(Str)
	registry_problems = |listed, skipped, found| {
		mains = listed.map(|t| t.main)
		names = listed.map(|t| t.name)
		skips = skipped.map(|t| t.main)
		known = mains.concat(skips)
		unlisted = found.keep_if(|f| !known.contains(f)).map(|f| "${f} is a fuzz target that neither Targets.fuzz_targets lists nor Targets.fuzz_skipped skips with a reason, so no task builds or replays it")
		gone = known.keep_if(|m| !found.contains(m)).map(|m| "the Targets registry names ${m}, which is not a fuzz target in the tree")
		both = skips.keep_if(|m| mains.contains(m)).map(|m| "${m} is both listed in Targets.fuzz_targets and skipped in Targets.fuzz_skipped")
		reasonless = skipped.keep_if(|t| t.reason.trim() == "").map(|t| "Targets.fuzz_skipped skips ${t.main} without a reason")
		twice = |list, what| list.keep_if(|x| list.keep_if(|y| y == x).len() > 1).fold([], |acc, x| if (acc.contains(x)) acc else acc.append(x)).map(|x| "the Targets registry names the ${what} ${x} more than once")
		unlisted.concat(gone).concat(both).concat(reasonless).concat(twice(names, "name")).concat(twice(known, "file"))
	}

	## The `check` stage over the tree: every fuzz target is listed or skipped
	## with a printed reason, and everything the registry names exists.
	registry! : () => Try(List(Str), _)
	registry! = || {
		var $found = []
		for dir in Targets.target_dirs {
			for file in SpecSuite.files_under!(dir, ".roc")? {
				if Targets.is_target(file, Path.read_utf8!(Path.utf8(file))?) {
					$found = $found.append(file)
				}
			}
		}
		for skip in Targets.fuzz_skipped {
			Proc.note!(Targets.skip_line(skip))
		}
		Ok(Targets.registry_problems(Targets.fuzz_targets, Targets.fuzz_skipped, $found))
	}

	## Where a target's executable is built.
	exe_of : SpecSuite.Options, Fuzz -> Str
	exe_of = |o, { name, .. }| "${o.build_dir}/fuzz/${name}/target"

	## Build fuzz targets in parallel, with coverage instrumentation, as a
	## campaign explores them. `--fuzz` needs the LLVM backend, so these
	## builds use `--opt=speed` (the compiler refuses `--opt=dev`). Phase
	## timings distinguish compiler cost from fixed-example replay cost. One
	## outcome per target, in order: a build that fails is that target's
	## problem, and the other targets are still built.
	build_fuzz_all! : SpecSuite.Options, List(Fuzz) => Try(List({ name : Str, problems : List(Str) }), _)
	build_fuzz_all! = |o, fuzzes| {
		var $jobs = []
		for t in fuzzes {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz/${t.name}")?
			$jobs = $jobs.append({ program: o.compiler, args: ["build", "--fuzz", "--opt=speed", "--timings", t.main, "--output=${Targets.exe_of(o, t)}"], cwd: o.root })
		}
		results = Proc.parallel!($jobs, Proc.compiler_jobs!()?)?
		Ok(List.map2(fuzzes, results, |t, r| { name: t.name, problems: if (r.code == 0) [] else ["fuzz ${t.name}: build exited with ${r.code.to_str()}: ${r.output.trim()}"] }))
	}

	check_job : SpecSuite.Options, Fuzz -> Proc.Job
	check_job = |o, t| { program: Targets.exe_of(o, t), args: ["check", "--timeout=1800"], cwd: "${o.build_dir}/fuzz/${t.name}" }

	## A target's check, judged: a finding (a failed property, a leak, a soak
	## cycle that does not return to flat live bytes) is a problem. Exact
	## allocation counts are not compared: there are no committed baselines.
	judge : Str, I32, Str -> List(Str)
	judge = |name, code, out|
		if code != 0 or !out.contains("${name}: passed") {
			["fuzz ${name}: ${out.trim()}"]
		} else {
			[]
		}

	## Build every target instrumented, then check the declared examples and
	## saved regressions of each one that built, in parallel (the checks are
	## independent processes). One outcome per target: the failed builds',
	## then the checks'; `FuzzPlan.account` holds a run to exactly one each.
	fuzz_check_all! : SpecSuite.Options, List(Fuzz) => Try(List({ name : Str, problems : List(Str) }), _)
	fuzz_check_all! = |o, fuzzes| {
		built = Targets.build_fuzz_all!(o, fuzzes)?
		ready = List.map2(fuzzes, built, |t, b| (t, b)).keep_if(|(_, b)| b.problems.is_empty()).map(|(t, _)| t)
		results = Proc.parallel!(ready.map(|t| Targets.check_job(o, t)), Proc.cpus!())?
		checked = List.map2(ready, results, |t, r| { name: t.name, problems: Targets.judge(t.name, r.code, r.output) })
		Ok(built.keep_if(|b| !b.problems.is_empty()).concat(checked))
	}

	## The explicit fixed-example lane has its own executables. Campaigns and
	## covered checks continue to use exe_of and never consult this directory.
	smoke_exe_of : SpecSuite.Options, Fuzz -> Str
	smoke_exe_of = |o, { name, .. }| "${o.build_dir}/fuzz-smoke/${name}/target"

	## A plain optimized build of the same actual roc-fuzz app. This job is
	## separate from covered build_fuzz_all!; it never supplies a campaign.
	smoke_build_job : SpecSuite.Options, Fuzz -> Proc.Job
	smoke_build_job = |o, t| { program: o.compiler, args: ["build", "--opt=speed", "--timings", t.main, "--output=${Targets.smoke_exe_of(o, t)}"], cwd: o.root }

	## Check every declared example of each selected target. A failed build
	## result blocks only its own replay; other built targets are checked.
	## One outcome per target: the failed builds', then the replays'.
	## Process spawn/poll and filesystem errors remain fatal batch errors,
	## as in Proc.parallel!. Durable reports, saved input
	## hashes, traces and outer allocation balance are judged by one helper.
	## Compiler and replay batch wall times are reported separately; neither
	## is a per-target timing when the scheduler admits several processes.
	fuzz_smoke_all! : SpecSuite.Options, List(Fuzz) => Try(List({ name : Str, problems : List(Str) }), _)
	fuzz_smoke_all! = |o, fuzzes| {
		if fuzzes.is_empty() {
			return Err(NoFuzzTargets)
		}
		for target in fuzzes {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz-smoke/${target.name}")?
		}
		build_start = Monotonic.now!()
		built = Proc.parallel!(fuzzes.map(|target| Targets.smoke_build_job(o, target)), Proc.compiler_jobs!()?)?
		build_elapsed = build_start.elapsed!()
		Proc.note!("== fuzz-smoke compiler batch: ${build_elapsed.to_str()}")
		var $outcomes = []
		var $ready = []
		for outcome in List.map2(fuzzes, built, |target, result| { target, code: result.code, output: result.output }) {
			dir = "${o.build_dir}/fuzz-smoke/${outcome.target.name}"
			Path.write_utf8!(Path.utf8("${dir}/build.log"), outcome.output)?
			if outcome.code != 0 {
				$outcomes = $outcomes.append({ name: outcome.target.name, problems: ["fuzz smoke ${outcome.target.name}: compiler/linker exited ${outcome.code.to_str()}; see ${dir}/build.log"] })
			} else if !(Path.exists!(Path.utf8(Targets.smoke_exe_of(o, outcome.target)))?) {
				$outcomes = $outcomes.append({ name: outcome.target.name, problems: ["fuzz smoke ${outcome.target.name}: compiler produced no executable"] })
			} else {
				$ready = $ready.append(outcome.target)
			}
		}
		check_start = Monotonic.now!()
		checked = Proc.parallel!(
			$ready.map(|target| { program: Targets.smoke_exe_of(o, target), args: ["check", "--timeout=1800", "--profile=fixed-examples-plain", "--report-dir=${o.build_dir}/fuzz-smoke/${target.name}/report"], cwd: "${o.build_dir}/fuzz-smoke/${target.name}" }),
			Proc.cpus!(),
		)?
		check_elapsed = check_start.elapsed!()
		Proc.note!("== fuzz-smoke fixed replay batch: ${check_elapsed.to_str()}")
		var $judges = []
		for outcome in List.map2($ready, checked, |target, result| { target, code: result.code, output: result.output }) {
			dir = "${o.build_dir}/fuzz-smoke/${outcome.target.name}"
			Path.write_utf8!(Path.utf8("${dir}/check.log"), outcome.output)?
			build = Targets.smoke_build_job(o, outcome.target)
			$judges = $judges.append({
				program: o.node,
				args: [
					"tests/fuzz/check-report.mjs",
					"--report-dir",
					"${dir}/report",
					"--target",
					outcome.target.name,
					"--profile",
					"fixed-examples-plain",
					"--binary",
					Targets.smoke_exe_of(o, outcome.target),
					"--build-exit",
					"0",
					"--check-exit",
					outcome.code.to_str(),
					"--build-log",
					"${dir}/build.log",
					"--check-log",
					"${dir}/check.log",
					"--compiler-version",
					o.nightly,
					"--build-cwd",
					o.root,
					"--build-batch-ns",
					build_elapsed.to_nanos().to_str(),
					"--check-batch-ns",
					check_elapsed.to_nanos().to_str(),
					"--build-command",
					build.program,
				].concat(build.args),
				cwd: o.root,
			})
		}
		judged = Proc.parallel!($judges, Proc.cpus!())?
		for outcome in List.map2($ready, judged, |target, result| { target, code: result.code, output: result.output }) {
			$outcomes = $outcomes.append({ name: outcome.target.name, problems: if (outcome.code == 0) [] else ["fuzz smoke ${outcome.target.name}: ${outcome.output.trim()}; see ${o.build_dir}/fuzz-smoke/${outcome.target.name}"] })
		}
		Ok($outcomes)
	}

	browser! : SpecSuite.Options, Str, List(Str) => Try(List(Str), _)
	browser! = |o, script, args| {
		code = Proc.status!({ program: o.node, args: ["tests/browser/${script}", "--runtime", SpecSuite.runtime, "--chrome", o.chrome].concat(args), cwd: o.root })?
		Ok(if (code == 0) [] else ["${script} ${Str.join_with(args, " ")} failed (exit ${code.to_str()})"])
	}

	## Exercise the monitor's bounded aggregation and environment facts, including
	## time-zone probes in UTC and Sydney, and the documented port handlers
	## with bounded queues and browser-resource cleanup, without a browser.
	## A development Wasm fixture also guards sparse-write allocation scaling.
	runtime_unit! : SpecSuite.Options => Try(List(Str), _)
	runtime_unit! = |o| {
		var $failures = []
		Proc.run!({ program: o.tooling, args: ["scripts/test_parallel.roc"], cwd: o.root })?
		Proc.run!({ program: o.tooling, args: ["scripts/test_protocol.roc"], cwd: o.root })?
		Proc.run!({ program: o.tooling, args: ["scripts/test_worker_entries.roc"], cwd: o.root })?
		for script in ["monitor-unit.mjs", "environment-unit.mjs", "port-recipes-unit.mjs", "protocol-facts.mjs", "boot-fault-unit.mjs", "forget-fault-unit.mjs", "work-request-unit.mjs", "storage-text-unit.mjs", "conduit-urls.mjs", "dbg.test.mjs", "replay-errors.test.mjs"] {
			code = Proc.status!({ program: o.node, args: ["tests/runtime/${script}"], cwd: o.root })?
			if code != 0 {
				$failures = $failures.append("${script} failed (exit ${code.to_str()})")
			}
		}
		report_units = Proc.status!({ program: o.node, args: ["tests/fuzz/check-report-unit.mjs"], cwd: o.root })?
		if report_units != 0 {
			$failures = $failures.append("fixed-report transport contracts failed (exit ${report_units.to_str()})")
		}
		wasm = "${o.build_dir}/write-scaling.wasm"
		Path.create_all!(Path.utf8(o.build_dir))?
		Proc.run!({ program: o.compiler, args: ["build", "--target=wasm32", "--opt=dev", "tests/apps/write-scaling/main.roc", "--output=${wasm}"], cwd: o.root })?
		code = Proc.status!({ program: o.node, args: ["tests/runtime/write-scaling.mjs", wasm], cwd: o.root })?
		if code != 0 {
			$failures = $failures.append("write-scaling.mjs failed (exit ${code.to_str()})")
		}
		Ok($failures)
	}

	## Run file specs in deliberate process-local orders so a page's teardown
	## and worker answers cannot consume the next page's handle capacity.
	native_contracts! : SpecSuite.Options => Try(List(Str), _)
	native_contracts! = |o| {
		code = Proc.status!({ program: o.node, args: ["tests/native/file-lifetimes.mjs", "--runner", SpecSuite.runner_of(o, "files")], cwd: o.root })?
		debug_code = Proc.status!({ program: o.node, args: ["tests/native/dbg-output.mjs", "--runner", SpecSuite.runner_of(o, "dbg")], cwd: o.root })?
		Ok((if (code == 0) [] else ["native file lifetime contracts failed (exit ${code.to_str()})"]).concat(if (debug_code == 0) [] else ["native dbg output contracts failed (exit ${debug_code.to_str()})"]))
	}

	## Build the deliberately crashing app only for its native query contract.
	## The query must avoid init; the same runner's prerender path proves that
	## init is not silently disabled. The real app supplies native and Wasm frames.
	prerender_contract! : SpecSuite.Options => Try(List(Str), _)
	prerender_contract! = |o| {
		dir = "${o.build_dir}/prerender-query"
		Path.create_all!(Path.utf8(dir))?
		fixture = Path.read_utf8!(Path.utf8("${o.root}/tests/key-contracts/picture-path-no-init.roc.txt"))?
		up = Str.join_with(List.repeat("..", dir.split_on("/").keep_if(|part| !part.is_empty()).len()), "/")
		main = "${dir}/main.roc"
		runner = "${dir}/runner"
		Path.write_utf8!(Path.utf8(main), fixture.replace_each("<PLATFORM>", "${up}/${o.root.drop_prefix("/")}/platform/main.roc"))?
		build = SpecSuite.build_job(o, "dev", main, SpecSuite.native_target, runner)
		Proc.run!({ ..build, args: build.args.append("--timings") })?
		Targets.browser!(o, "prerender-stage1-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "prerender"), "--runner", SpecSuite.runner_of(o, "prerender"), "--no-init-runner", runner, "--template", "tests/apps/prerender/index.html"])
	}

	## The runtime contract tests in Chrome (test apps built by `SpecSuite.build!`): the effect channel (tests/apps/effects),
	## controlled inputs, focus and containment (tests/apps/controls), an
	## outbox posted twice in one turn (tests/apps/outbox), worker
	## jobs in real Web Workers and the work monitor (tests/apps/workers), the
	## worker scaling smoke (the Worker Lab), file handles (tests/apps/files),
	## operations on files (tests/apps/file-effects), preparations and
	## the pool's placement (tests/apps/prepared), ports with real handlers
	## (tests/apps/ports), worker tasks, their handles and the page's
	## stubs (tests/apps/tasks), the Reading List's own port handlers against
	## real IndexedDB in two tabs, the Log Explorer over a 64 MiB log, the
	## Million-Row Explorer at two million orders with its own feed, and
	## Conduit's user journey against the RealWorld mock backend.
	browser_contracts! : SpecSuite.Options, Str => Try(List(Str), _)
	browser_contracts! = |o, conduit_wasm| {
		fx = SpecSuite.wasm_of(o, "effects")
		controls = SpecSuite.wasm_of(o, "controls")
		services = SpecSuite.wasm_of(o, "services")
		workers = SpecSuite.wasm_of(o, "workers")
		files = SpecSuite.wasm_of(o, "files")
		file_effects = SpecSuite.wasm_of(o, "file-effects")
		ports = SpecSuite.wasm_of(o, "ports")
		# The native oracle classifies every scalar; Chrome compares independently.
		unicode_runner = "${o.build_dir}/unicode-symbols"
		unicode_bits = "${o.build_dir}/unicode-symbols.bin"
		Path.create_all!(Path.utf8(o.build_dir))?
		Proc.run!({ program: o.compiler, args: ["build", "--opt=dev", "scripts/unicode_symbols.roc", "--output=${unicode_runner}"], cwd: o.root })?
		bits = Proc.capture!({ program: unicode_runner, args: [], cwd: o.root })?
		Path.write_bytes!(Path.utf8(unicode_bits), bits)?
		Ok(
			Targets.browser!(o, "protocol-facts-browser.mjs", [])?
				.concat(Targets.browser!(o, "picture-browser.mjs", [])?)
				.concat(Targets.browser!(o, "picture-parent-browser.mjs", [])?)
				.concat(Targets.prerender_contract!(o)?)
				.concat(Targets.browser!(o, "names-browser.mjs", [])?)
				.concat(Targets.browser!(o, "namespaces-browser.mjs", [])?)
				.concat(Targets.browser!(o, "unicode-symbols-browser.mjs", ["--oracle", unicode_bits])?)
				.concat(Targets.browser!(o, "fx-browser.mjs", ["--wasm", fx])?)
				.concat(Targets.browser!(o, "controls-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "effective-types-refusals.mjs", ["--wasm", controls, "--native", SpecSuite.runner_of(o, "controls")])?)
				.concat(Targets.browser!(o, "markup-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "markup")])?)
				.concat(Targets.browser!(o, "construction-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "construction")])?)
				.concat(Targets.browser!(o, "pointer-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "keys-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "dialogs-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "layout-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "table"), "--runner", SpecSuite.runner_of(o, "table")])?)
				.concat(Targets.browser!(o, "outbox-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "outbox")])?)
				.concat(Targets.browser!(o, "services-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "environment-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "persistence-browser.mjs", ["--wasm", services, "--runner", SpecSuite.runner_of(o, "services")])?)
				.concat(Targets.browser!(o, "transitions-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "workers-browser.mjs", ["--wasm", workers])?)
				.concat(Targets.browser!(o, "dbg-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "dbg"), "--job-only-wasm", SpecSuite.wasm_of(o, "dbg-job-only")])?)
				.concat(Targets.browser!(o, "monitor-browser.mjs", ["--wasm", workers])?)
				.concat(Targets.browser!(o, "workers-scaling.mjs", ["--wasm", SpecSuite.wasm_of(o, "worker-lab"), "--mode", "smoke"])?)
				.concat(Targets.browser!(o, "files-browser.mjs", ["--wasm", files])?)
				.concat(Targets.browser!(o, "table-file-lifetime-browser.mjs", ["--wasm", files])?)
				.concat(Targets.browser!(o, "file-effects-browser.mjs", ["--wasm", file_effects])?)
				.concat(Targets.browser!(o, "http-progress-browser.mjs", ["--wasm", file_effects])?)
				.concat(Targets.browser!(o, "file-transfer-memory-browser.mjs", [])?)
				.concat(Targets.browser!(o, "prepared-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "prepared")])?)
				.concat(Targets.browser!(o, "ports-browser.mjs", ["--wasm", ports])?)
				.concat(Targets.browser!(o, "reports-browser.mjs", ["--wasm", ports])?)
				.concat(Targets.browser!(o, "tasks-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "tasks")])?)
				.concat(Targets.browser!(o, "reading-list-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "reading-list")])?)
				.concat(Targets.browser!(o, "status-page-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "status-page")])?)
				.concat(Targets.browser!(o, "log-explorer-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "log-explorer")])?)
				.concat(Targets.browser!(o, "million-row-explorer-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "million-row-explorer")])?)
				.concat(Targets.browser!(o, "conduit-journey.mjs", ["--wasm", conduit_wasm])?),
		)
	}

	## The worker scaling measurement (tests/browser/workers-scaling.mjs) on
	## the Worker Lab, in full, for each of the two candidate shipping builds:
	## `--opt=size`, and `--opt=size --specialize=no`. Each run checks
	## correctness against an independent implementation, speedup by pool
	## size (where the machine has the cores), responsiveness, payloads,
	## robustness sequences and memory, and prints tables to paste into a pull
	## request. `check` runs its smoke on the development build instead.
	workers_scaling! : SpecSuite.Options => Try(List(Str), _)
	workers_scaling! = |o| {
		var $problems = []
		# Compiler workaround (https://github.com/roc-lang/roc/issues/12945): a
		# derived record decode leaks on every worker job under
		# `--specialize=no`, so that run is told to expect its worker
		# instances to grow, and fails once they no longer do.
		leak = "https://github.com/roc-lang/roc/issues/12945"
		for build in [{ label: "size", flags: [], known: [] }, { label: "size-specialize-no", flags: ["--specialize=no"], known: ["--known-leak", leak] }] {
			dir = "${o.build_dir}/workers-scaling/${build.label}"
			Path.create_all!(Path.utf8(dir))?
			Proc.run!({ program: o.compiler, args: ["build", "--opt=size"].concat(build.flags).concat(["--target=wasm32", "examples/worker-lab/main.roc", "--output=${dir}/app.wasm"]), cwd: o.root })?
			Proc.note!("== workers scaling, ${build.label}")
			$problems = $problems.concat(Targets.browser!(o, "workers-scaling.mjs", ["--wasm", "${dir}/app.wasm", "--mode", "full", "--label", build.label].concat(build.known))?)
		}
		Ok($problems)
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
		SpecSuite.copy_runtime!(o.root, dist)?
		Path.copy!(Path.utf8("${o.root}/${Targets.jfb_dir}/src/main.mjs"), Path.utf8("${dist}/main.mjs"))?
		code = Proc.status!({ program: o.node, args: ["tests/browser/jfb-check.mjs", "--dist", dist, "--chrome", o.chrome], cwd: o.root })?
		Ok(if (code == 0) [] else ["jfb-check failed (exit ${code.to_str()})"])
	}
}

## A target in the tree that is not listed is named, and so is a listed one
## that is gone.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc" }, { name: "b", main: "examples/b/fuzz-b.roc" }], [], ["examples/b/fuzz-b.roc", "tests/apps/c/fuzz-c.roc"]) == ["tests/apps/c/fuzz-c.roc is a fuzz target that neither Targets.fuzz_targets lists nor Targets.fuzz_skipped skips with a reason, so no task builds or replays it", "the Targets registry names fuzz/a/main.roc, which is not a fuzz target in the tree"]

## Equal lists in any order agree, and a skip with a reason accounts for its
## target.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc" }], [{ main: "examples/b/fuzz-b.roc", reason: "needs a browser" }], ["examples/b/fuzz-b.roc", "fuzz/a/main.roc"]) == []

## A skip without a reason, a file both listed and skipped, and a name or file
## named twice are each reported once.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc" }, { name: "a", main: "fuzz/a/main.roc" }], [{ main: "fuzz/a/main.roc", reason: " " }], ["fuzz/a/main.roc"]) == ["fuzz/a/main.roc is both listed in Targets.fuzz_targets and skipped in Targets.fuzz_skipped", "Targets.fuzz_skipped skips fuzz/a/main.roc without a reason", "the Targets registry names the name a more than once", "the Targets registry names the file fuzz/a/main.roc more than once"]

## A skipped target is printed with its reason.
expect Targets.skip_line({ main: "fuzz/a/main.roc", reason: "needs a browser" }) == "SKIP fuzz target fuzz/a/main.roc: needs a browser"

## A target is known by its place, its name or its platform; a module beside
## it, and a main deeper under `fuzz/`, are not targets by place alone.
expect [
	Targets.is_target("fuzz/z/main.roc", ""),
	Targets.is_target("examples/x/fuzz-y.roc", ""),
	Targets.is_target("tests/apps/x/fuzz-y.roc", ""),
	Targets.is_target("examples/x/Rules.roc", "app [target] {\n\tfz: platform \"https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/h.tar.zst\",\n}\n"),
	Targets.is_target("fuzz/wire/Saved.roc", "module [saved]\n"),
	Targets.is_target("fuzz/z/lib/main.roc", ""),
	Targets.is_target("examples/x/main.roc", "app [main] { pf: platform \"../../platform/main.roc\" }\n"),
] == [True, True, True, True, False, False, False]
