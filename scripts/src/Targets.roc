import cli.Path
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
		{ name: "wire", main: "fuzz/wire/main.roc" },
		{ name: "structure", main: "fuzz/structure/main.roc" },
		{ name: "table-view", main: "fuzz/table-view/main.roc" },
		{ name: "port-json", main: "fuzz/port-json/main.roc" },
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

	## Where a target's executable is built.
	exe_of : SpecSuite.Options, Fuzz -> Str
	exe_of = |o, { name, .. }| "${o.build_dir}/fuzz/${name}/target"

	## Build fuzz targets in parallel. `--fuzz` needs the LLVM backend, so
	## these builds use `--opt=speed` (the compiler refuses `--opt=dev`).
	build_fuzz_all! : SpecSuite.Options, List(Fuzz) => Try({}, _)
	build_fuzz_all! = |o, fuzzes| {
		var $jobs = []
		for t in fuzzes {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz/${t.name}")?
			$jobs = $jobs.append({ program: o.compiler, args: ["build", "--fuzz", "--opt=speed", t.main, "--output=${Targets.exe_of(o, t)}"], cwd: o.root })
		}
		results = Proc.parallel!($jobs, Proc.cpus!())?
		match List.map2(fuzzes, results, |t, r| (t, r.code)).keep_if(|(_, c)| c != 0).first() {
			Ok((t, c)) => Err(BuildFailed("fuzz ${t.name}: build exited with ${c.to_str()}"))
			Err(_) => Ok({})
		}
	}

	build_fuzz! : SpecSuite.Options, Fuzz => Try(Str, _)
	build_fuzz! = |o, t| {
		Targets.build_fuzz_all!(o, [t])?
		Ok(Targets.exe_of(o, t))
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

	## Build every target, then check each one's declared examples, in
	## parallel (the checks are independent processes).
	fuzz_check_all! : SpecSuite.Options, List(Fuzz) => Try(List(Str), _)
	fuzz_check_all! = |o, fuzzes| {
		Targets.build_fuzz_all!(o, fuzzes)?
		results = Proc.parallel!(fuzzes.map(|t| Targets.check_job(o, t)), Proc.cpus!())?
		Ok(List.map2(fuzzes, results, |t, r| Targets.judge(t.name, r.code, r.output)).join())
	}

	fuzz_check! : SpecSuite.Options, Fuzz, Str => Try(List(Str), _)
	fuzz_check! = |o, t, _exe| Targets.fuzz_check_all!(o, [t])

	browser! : SpecSuite.Options, Str, List(Str) => Try(List(Str), _)
	browser! = |o, script, args| {
		code = Proc.status!({ program: o.node, args: ["tests/browser/${script}", "--runtime", SpecSuite.runtime, "--chrome", o.chrome].concat(args), cwd: o.root })?
		Ok(if (code == 0) [] else ["${script} ${Str.join_with(args, " ")} failed (exit ${code.to_str()})"])
	}

	## Exercise the monitor's bounded aggregation and environment facts, including
	## time-zone probes in UTC and Sydney, and the documented port handlers
	## with bounded queues and browser-resource cleanup, without a browser.
	runtime_unit! : SpecSuite.Options => Try(List(Str), _)
	runtime_unit! = |o| {
		var $failures = []
		for script in ["monitor-unit.mjs", "environment-unit.mjs", "port-recipes-unit.mjs"] {
			code = Proc.status!({ program: o.node, args: ["tests/runtime/${script}"], cwd: o.root })?
			if code != 0 {
				$failures = $failures.append("${script} failed (exit ${code.to_str()})")
			}
		}
		Ok($failures)
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
		Ok(
			Targets.browser!(o, "fx-browser.mjs", ["--wasm", fx])?
				.concat(Targets.browser!(o, "controls-browser.mjs", ["--wasm", controls])?)
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
				.concat(Targets.browser!(o, "monitor-browser.mjs", ["--wasm", workers])?)
				.concat(Targets.browser!(o, "workers-scaling.mjs", ["--wasm", SpecSuite.wasm_of(o, "worker-lab"), "--mode", "smoke"])?)
				.concat(Targets.browser!(o, "files-browser.mjs", ["--wasm", files])?)
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
		if SpecSuite.has_broken_optimizer(o.nightly) {
			Proc.note!("SKIP optimized worker scaling (${SpecSuite.optimizer_issue}): ${o.nightly} crashes building Worker Lab; the dev-build smoke still runs in check. Restore on the next nightly.")
			return Ok([])
		}
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
