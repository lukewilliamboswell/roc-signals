#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3/FTL1xt1rA9nXzoYkhFAW9yF75Kn52bS3cpBr7wZNfPq2.tar.zst",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.OsStr
import cli.Path
import src/Checks
import src/CompilerSkips
import src/CheckPlan
import src/FuzzPlan
import src/PlatformTest
import src/DocSamples
import src/ApiDocs
import src/ApiSurface
import src/ExampleFiles
import src/Release
import src/Proc
import src/SpecSuite
import src/Slow
import src/Targets
import src/ProtocolEvidence
import src/ToolCheck
import src/Sizes

## The `check` task, the per-pull-request gate: the script pins,
## formatting, every file `www/data/examples.toml` names present, every
## fuzz target in the tree listed in `Targets.fuzz_targets`, every
## public `Engine` and `Html` symbol documented, `roc test` (the platform,
## the engine package, the tool, the scripts, and every example's and test
## app's `expect`s),
## the platform inputs, the host's resource-heap tests, the spec runner's
## links for macOS and Windows, every registered fuzz target's fixed
## examples on a plain optimized build (`fuzz-smoke`), the docs samples, every
## app's `.scm` specs natively and in Chrome, a short walk of every app in
## the native runner, the broken-spec self-checks (both
## runners reject each spec with one wrong expectation, a lost worker job's
## fault class among them, and a broken contract's native crash is reported
## as a run without results), the runtime's
## unit tests in Node and contract tests in Chrome (effects, controls,
## workers, Conduit journey), the
## recorded Brotli sizes of shipped JavaScript and a report of each example's
## shipping module and development-only scripts, the
## js-framework-benchmark check, the release dry run, and the `signals.roc`
## tool run end to end from the dry run's copy. The long walks, the soaks
## and the fuzz targets' instrumented replays are `check-slow`.
## `check -- --without-fuzz` prints a `SKIP` line for each fuzz target
## instead of running it; CI's Check job passes it because CI's Fuzz smoke
## job runs every target, in shards; `check -- --without-sizes` prints a
## `SKIP` line for the size report, which CI's Site job makes from the
## modules it publishes. `check -- --part K/N` runs part K of
## the `CheckPlan.parts` parts CI's Check matrix runs in parallel, printing
## a `SKIP` line for each stage another part runs, and `check -- --plan`
## prints which stages and apps each part runs and how many builds it
## makes (`--plan --builds`: every build), without running anything.
## Every problem is printed as a `FAIL` line at the end or, when a stage
## cannot run and aborts the task, before that stage's error
## (`Checks.gather!`).
main! = |raw_args| {
	args = match options(raw_args.map(OsStr.display).drop_if(|arg| arg == "--")) {
		Ok(chosen) => chosen
		Err(Unknown(arg)) => {
			Proc.warn!("unknown check option ${arg}; the options are --without-fuzz, --without-sizes, --part K/N, --plan and --plan --builds")
			return Err(Exit(2))
		}
	}
	if args.describe != Run {
		inputs = plan_inputs!()?
		for line in CheckPlan.describe(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, inputs) {
			Proc.note!(line)
		}
		if args.describe == Builds {
			for index in 1.U64..=CheckPlan.parts {
				match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, OnePart({ index, total: CheckPlan.parts })) {
					Ok(p) => {
						Proc.note!("builds of part ${index.to_str()}/${CheckPlan.parts.to_str()}:")
						for line in CheckPlan.build_lines(p, inputs) {
							Proc.note!(line)
						}
					}
					Err(error) => Proc.note!(CheckPlan.refusal(error))
				}
			}
		}
		return Ok({})
	}
	plan = match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, args.part) {
		Ok(planned) => planned
		Err(error) => {
			Proc.warn!(CheckPlan.refusal(error))
			return Err(Exit(2))
		}
	}
	for skip in plan.skip {
		Proc.note!(CheckPlan.skip_line(skip))
	}
	if plan.skip != [] {
		Proc.note!("${plan.label}: ${plan.stages.len().to_str()} stages, the per-app ones for ${plan.apps.len().to_str()} apps: ${Str.join_with(plan.apps, ", ")}")
	}
	o = Checks.options!({ filter: "*" })?
	var $run = { problems: [], called: [] }

	$run = stage!(plan, $run, "script pins", || script_pins!())?
	$run = stage!(plan, $run, "file names", || file_names!())?
	$run = stage!(plan, $run, "script modes", || script_modes!())?
	$run = stage!(
		plan,
		$run,
		"formatting",
		|| {
			sources = check!({ program: o.compiler, args: ["fmt", "--check", "platform", "examples", "tests/apps", "tests/fixtures", "fuzz", "www/samples", "cli", "benchmarks/js-framework-benchmark/roc-signals-keyed/app"], cwd: "." }, "roc fmt --check")?
			scripts = check!({ program: o.tooling, args: ["fmt", "--check", "scripts"], cwd: "." }, "roc-stable fmt --check scripts")?
			Ok(sources.concat(scripts))
		},
	)?
	$run = stage!(plan, $run, "example files", || ExampleFiles.check!(o.root))?
	$run = stage!(plan, $run, "fuzz target registry", || Targets.registry!())?
	$run = stage!(plan, $run, "spec lists", || SpecSuite.listing!())?
	$run = stage!(plan, $run, "platform JavaScript sizes", || Sizes.check_runtime!({ root: o.root, node: o.node }))?
	$run = stage!(plan, $run, "platform packages", || platform_packages!(o.root))?
	$run = stage!(
		plan,
		$run,
		"API docs",
		|| {
			documented = ApiDocs.check!({})?
			internal = ApiDocs.internal_roots!(o)?
			bumped = ApiDocs.bump!(o, Candidate)?
			Ok(documented.concat(internal).concat(bumped))
		},
	)?
	$run = stage!(
		plan,
		$run,
		"platform expects",
		|| {
			shipped = check!({ program: o.compiler, args: ["test", "platform/main.roc"], cwd: "." }, "roc test platform/main.roc")?
			engine = check!({ program: o.compiler, args: ["test", "platform/main-fuzz.roc"], cwd: "." }, "roc test platform/main-fuzz.roc")?
			tool = check!({ program: o.compiler, args: ["test", "cli/main.roc"], cwd: "." }, "roc test cli/main.roc")?
			Ok(shipped.concat(engine).concat(tool))
		},
	)?
	$run = stage!(plan, $run, "app expects", || Checks.app_expects!(o))?
	$run = stage!(plan, $run, "declaration type fixtures", || Checks.key_type_errors!(o))?
	$run = stage!(plan, $run, "fuzz expects", || Targets.fuzz_expects!(o))?
	$run = stage!(plan, $run, "tool bundle", || ToolCheck.bundle_current!(o))?
	$run = stage!(plan, $run, "script expects", || script_tests!(o))?

	# The platform's link inputs, which every native build and the host
	# tests need, are prepared by every run that builds anything.
	Checks.hold!($run.problems, Checks.prepare_platform!(o))?
	$run = stage!(plan, $run, "key contracts", || Checks.key_contracts!(o))?
	$run = stage!(
		plan,
		$run,
		"host tests",
		|| {
			resources = check!({ program: o.zig, args: ["test", "platform/host/resources.zig"], cwd: "." }, "zig test platform/host/resources.zig")?
			debug = check!({ program: o.zig, args: ["test", "platform/host/dbg.zig"], cwd: "." }, "zig test platform/host/dbg.zig")?
			crypto = check!({ program: o.zig, args: ["test", "platform/host/crypto.zig"], cwd: "." }, "zig test platform/host/crypto.zig")?
			Ok(resources.concat(debug).concat(crypto))
		},
	)?
	$run = stage!(plan, $run, "cross links", || cross_links!(o))?
	$run = stage!(plan, $run, "fuzz targets", || FuzzPlan.run!(Targets.fuzz_targets, args.fuzzing, |fuzzes| Targets.fuzz_smoke_all!(o, fuzzes)))?
	$run = stage!(plan, $run, "docs samples", || DocSamples.check!(o))?

	# Every build the run's stages use, from the one list in SpecSuite and
	# each stage's `CheckPlan.needs`, in one bounded batch. Each build is
	# named once: two jobs writing one app.wasm would race.
	Checks.hold!($run.problems, SpecSuite.build_web_platform!(o))?
	$run = stage!(
		plan,
		$run,
		"debug file sizes",
		|| {
			Sizes.report_debug!(o)?
			Ok([])
		},
	)?
	$run = match args.sizes {
		Here => stage!(plan, $run, "example sizes", || Sizes.report_examples!(o, |_| Bool.True))?
		Elsewhere(reason) => {
			if CheckPlan.runs(plan, "example sizes") {
				Proc.note!("SKIP example sizes: ${reason}")
			}
			{ ..$run, called: $run.called.append("example sizes") }
		}
	}
	# The apps whose compiler-keyed skips move specs to a shipping build on
	# this compiler: their `--opt=size` builds join the batch.
	size_specs = CompilerSkips.skips.keep_if(|skip| skip.compilers.contains(o.nightly)).map(|skip| skip.example)
	builds = CheckPlan.builds(plan, size_specs)
	if builds.natives != [] or builds.webs != [] or builds.sized != [] {
		Proc.note!("== builds: ${builds.natives.len().to_str()} native runners, ${builds.webs.len().to_str()} browser builds and ${builds.sized.len().to_str()} shipping builds, ${Proc.compiler_jobs!(App)?.to_str()} at a time")
		Checks.hold!($run.problems, SpecSuite.build_all!(o, builds))?
	}
	var $native = SpecSuite.empty_tally
	var $browser = SpecSuite.empty_tally
	if CheckPlan.runs(plan, "specs") {
		Proc.note!("== specs")
		for example in plan.apps {
			r = Checks.hold!($run.problems.concat($native.problems).concat($browser.problems), Checks.run_app!(o, example, Bool.True, Built))?
			$native = SpecSuite.add($native, r.native)
			$browser = SpecSuite.add($browser, r.browser)
		}
	}
	$run = { problems: $run.problems.concat($native.problems).concat($browser.problems), called: $run.called.append("specs") }

	$run = stage!(plan, $run, "native lifetime contracts", || Targets.native_contracts!(o))?
	$run = stage!(plan, $run, "short walks", || Slow.short_walks!(o, Slow.walk_apps.keep_if(|name| plan.apps.contains(name))))?
	$run = stage!(
		plan,
		$run,
		"grammar coverage",
		|| {
			grammar = Checks.grammar!(o, SpecSuite.runner_of(o, "kanban-board"))?
			chosen = Checks.choose_files!(o)?
			Ok(grammar.concat(chosen))
		},
	)?
	$run = stage!(
		plan,
		$run,
		"broken-spec self-check",
		|| {
			var $found = []
			for broken in Checks.broken_specs.keep_if(|b| plan.apps.contains(b.example)) {
				$found = $found.concat(Checks.broken_spec!(o, broken, Rejects)?)
			}
			for crashing in Checks.crashing_specs.keep_if(|b| plan.apps.contains(b.example)) {
				$found = $found.concat(Checks.broken_spec!(o, crashing, Crashes)?)
			}
			Ok($found)
		},
	)?
	$run = stage!(plan, $run, "declaration refusals", || Checks.declaration_refusals!(o, {}))?
	$run = stage!(plan, $run, "runtime unit tests", || Targets.runtime_unit!(o))?
	$run = stage!(plan, $run, "runtime contracts in Chrome", || Targets.browser_contracts!(o))?
	$run = stage!(plan, $run, "example journeys in Chrome", || Targets.example_journeys!(o))?
	$run = stage!(plan, $run, "js-framework-benchmark", || Targets.jfb!(o, Checked))?
	$run = stage!(plan, $run, "release dry run", || Release.build!(o, "0.0.1-dryrun", "${o.build_dir}/release"))?
	$run = stage!(plan, $run, "signals.roc", || ToolCheck.run!(o))?

	problems = $run.problems.concat(CheckPlan.called_problems(CheckPlan.stages, $run.called))
	Proc.note!("")
	if CheckPlan.runs(plan, "specs") {
		Proc.note!(SpecSuite.summary("${plan.apps.len().to_str()} apps", Native, $native))
		Proc.note!(SpecSuite.summary("${plan.apps.len().to_str()} apps", Browser, $browser))
	}
	Checks.finish!(plan.label, problems)
}

## Run the stage `name` with `run!` when the plan runs it, adding its
## problems to the run's, and record that `check` reached it, so that a
## stage `CheckPlan.stages` places but `main!` never reaches is a problem
## (`CheckPlan.called_problems`).
stage! : CheckPlan.Plan, { problems : List(Str), called : List(Str) }, Str, (() => Try(List(Str), e)) => Try({ problems : List(Str), called : List(Str) }, e)
stage! = |plan, run, name, run!| {
	called = run.called.append(name)
	if CheckPlan.runs(plan, name) {
		Proc.note!("== ${name}")
		problems = Checks.gather!(run.problems, run!())?
		Ok({ problems, called })
	} else {
		Ok({ problems: run.problems, called })
	}
}

## Why `check -- --without-sizes` skips the size report: CI's Site job
## builds every example's `--opt=size` module to publish it, and reports
## its size there, so the module is built once in a CI run.
sizes_elsewhere : Str
sizes_elsewhere = "check --without-sizes: CI's Site job builds every example's --opt=size module and reports its size"

## What the arguments ask for: whether the fuzz targets run, whether the
## size report runs, which part of
## the gate, and whether only to print the plan (`--plan`), with every
## build of every part (`--plan --builds`).
options : List(Str) -> Try({ fuzzing : FuzzPlan.Selection, sizes : [Here, Elsewhere(Str)], part : CheckPlan.Selection, describe : [Run, Summary, Builds] }, [Unknown(Str)])
options = |args| {
	var $out = { fuzzing: Every, sizes: Here, part: Whole, describe: Run }
	var $rest = args
	while $rest != [] {
		match $rest {
			["--without-fuzz", .. as more] if $out.fuzzing == Every => {
				$out = { ..$out, fuzzing: Elsewhere("check --without-fuzz: CI's Fuzz smoke job replays every target") }
				$rest = more
			}
			["--without-sizes", .. as more] if $out.sizes == Here => {
				$out = { ..$out, sizes: Elsewhere(sizes_elsewhere) }
				$rest = more
			}
			["--part", text, .. as more] if $out.part == Whole => {
				part = CheckPlan.parse_part(text) ? |_| Unknown("--part ${text}")
				$out = { ..$out, part: OnePart(part) }
				$rest = more
			}
			["--plan", "--builds", .. as more] if $out.describe == Run => {
				$out = { ..$out, describe: Builds }
				$rest = more
			}
			["--plan", .. as more] if $out.describe == Run => {
				$out = { ..$out, describe: Summary }
				$rest = more
			}
			[arg, ..] => return Err(Unknown(arg))
			[] => {}
		}
	}
	Ok($out)
}

## The tree's inputs to the plan's builds: the docs sample directories
## with specs, the catalogue's examples, and the apps a compiler-keyed skip
## gives a size build.
plan_inputs! : () => Try(CheckPlan.Inputs, _)
plan_inputs! = || {
	var $samples = []
	for dir in DocSamples.dirs!()? {
		if Path.exists!(Path.utf8("${dir}/specs"))? {
			$samples = $samples.append(dir)
		}
	}
	catalog = Sizes.examples(Path.read_utf8!(Path.utf8(ExampleFiles.catalog))?)?
	size_specs = CompilerSkips.skips.map(|skip| skip.example).fold([], |seen, name| if (seen.contains(name)) seen else seen.append(name))
	Ok({ samples: $samples, catalog, size_specs })
}

## Run a check; a failure is a reported problem, not an abort.
check! : Proc.Job, Str => Try(List(Str), _)
check! = |job, label| {
	{ code, .. } = Proc.output!(job)?
	Ok(if (code == 0) [] else ["${label} failed (exit ${code.to_str()})"])
}

## The source directories whose file names must stay distinct on a file
## system that ignores letter case.
source_dirs : List(Str)
source_dirs = ["platform", "cli", "examples", "tests", "fuzz", "scripts", "www/samples", "www/content", "www/data", "www/static", "www/templates", "benchmarks"]

## No two source files have paths that differ only in letter case. macOS and
## Windows keep one file for such a pair, so a checkout there silently loses
## the other, and a build that needs both fails.
## Every script a Blueprint task starts is executable in git: a task's
## script that is not (mode 100755) cannot be started on a fresh checkout,
## and most tasks never run in CI to show it.
script_modes! : () => Try(List(Str), _)
script_modes! = || {
	blueprint = Path.read_utf8!(Path.utf8("Blueprint.roc"))?
	scripts = task_scripts(blueprint)
	listed = Proc.capture!({ program: "git", args: ["ls-files", "-s", "--"].concat(scripts), cwd: "." })?
	Ok(mode_problems(scripts, Str.from_utf8_lossy(listed)))
}

## The script each `Run([...])` of a Blueprint task starts: its first
## element, when it is a path (a bare program such as `node` is not).
task_scripts : Str -> List(Str)
task_scripts = |text| text.split_on("Run([\"").drop_first(1).keep_oks(|rest| rest.split_on("\"").first()).keep_if(|first| first.contains("/"))

## One problem for each script that `git ls-files -s` does not list as an
## executable file (mode 100755), or does not list at all.
mode_problems : List(Str), Str -> List(Str)
mode_problems = |scripts, listed| {
	modes = listed.split_on("\n").keep_oks(
		|line| match line.split_on("\t") {
			[stage, path] => Ok({ path, mode: stage.split_on(" ").first() ?? "" })
			_ => Err(NotAnEntry)
		},
	)
	scripts.keep_oks(
		|script| match modes.find_first(|m| m.path == script) {
			Ok({ mode: "100755", .. }) => Err(Executable)
			Ok({ mode, .. }) => Ok("${script} is started by a Blueprint task but its git mode is ${mode}, not 100755: run git update-index --chmod=+x ${script}")
			Err(_) => Ok("${script} is started by a Blueprint task but git does not track it")
		},
	)
}

file_names! : () => Try(List(Str), _)
file_names! = || {
	var $files = []
	for dir in source_dirs {
		$files = $files.concat(SpecSuite.files_under!(dir, "")?)
	}
	Ok(case_collisions($files))
}

## One problem for each pair of paths that are equal once letter case is
## ignored.
case_collisions : List(Str) -> List(Str)
case_collisions = |paths| {
	keyed = paths.map(|path| { key: Str.from_utf8_lossy(path.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b)), path })
	sorted = keyed.sort_with(
		|a, b| match SpecSuite.compare_str(a.key, b.key) {
			Same => SpecSuite.compare_str(a.path, b.path)
			other => other
		},
	)
	var $out = []
	var $prev = { key: "", path: "" }
	for item in sorted {
		if item.key == $prev.key and item.path != $prev.path {
			$out = $out.append("${$prev.path} and ${item.path} differ only in letter case, so a checkout on macOS or Windows keeps only one of them")
		}
		$prev = item
	}
	$out
}

## Two paths that differ only in case are reported once, in a fixed order.
expect case_collisions(["platform/engine.roc", "a/b.roc", "platform/Engine.roc"]) == ["platform/Engine.roc and platform/engine.roc differ only in letter case, so a checkout on macOS or Windows keeps only one of them"]

## Paths that differ in more than case, and a path listed twice, are fine.
expect case_collisions(["a/B.roc", "a/c.roc", "A2/b.roc", "a/c.roc"]) == []

## Every script under `scripts/` names the tooling compiler Blueprint.roc pins,
## except the one root the package compiler builds, and nothing else pins a
## compiler: no `.roc-version`, and no `roc` header field in any Roc file
## outside `scripts/` (roc-automation's model; the package compiler floats).
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
	var $scripts = []
	for path in SpecSuite.files_with!("scripts", ".roc")? {
		$scripts = $scripts.append({ path, text: Path.read_utf8!(Path.utf8(path))? })
	}
	var $out = script_pin_problems(tag, $scripts)
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

## The scripts `roc-stable` runs pin its tag. The root `roc` builds
## (`Targets.unicode_symbols_root`) names no compiler, as an app does: `roc`
## floats, and a header pin that differs from it is a warning that fails
## the build.
script_pin_problems : Str, List({ path : Str, text : Str }) -> List(Str)
script_pin_problems = |tag, scripts|
	scripts.keep_oks(
		|{ path, text }| {
			header = text.split_on("\n").take_first(8)
			if path == Targets.unicode_symbols_root {
				if (header.any(|l| l.trim().starts_with("roc: \""))) Ok("${path} is built by the package compiler, so it must not pin a compiler") else Err(Fine)
			} else if text.contains("roc: \"${tag}\"") {
				Err(Fine)
			} else {
				Ok("${path} does not pin roc: \"${tag}\"")
			}
		},
	)

## A tooling script must pin the tag; the root the package compiler builds
## must not pin any compiler.
expect {
	tag = "nightly-1"
	pinned = { path: "scripts/a.roc", text: "app [main!] {\n\troc: \"nightly-1\",\n}\n" }
	unpinned = { path: "scripts/b.roc", text: "app [main!] {\n}\n" }
	oracle = { path: Targets.unicode_symbols_root, text: "app [main!] {\n\tpf: \"../platform/main-fuzz.roc\",\n}\n" }
	pinned_oracle = { path: Targets.unicode_symbols_root, text: "app [main!] {\n\troc: \"nightly-1\",\n}\n" }
	script_pin_problems(tag, [pinned, unpinned, oracle, pinned_oracle]) == ["scripts/b.roc does not pin roc: \"nightly-1\"", "scripts/unicode_symbols.roc is built by the package compiler, so it must not pin a compiler"]
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
	results = Proc.parallel!($jobs, Proc.compiler_jobs!(App)?)?
	Ok(List.map2(PlatformTest.spec_hosts, results, |host, r| (host.target, r)).keep_if(|(_, r)| r.code != 0).map(|(target, r)| "spec runner for ${target} does not link: ${r.output.trim()}"))
}

## `check` runs every fuzz target and the whole gate unless told the
## targets are replayed elsewhere or given one part; each option is given
## at most once.
expect options([]) == Ok({ fuzzing: Every, sizes: Here, part: Whole, describe: Run })
expect options(["--part", "2/5", "--without-fuzz"]) == Ok({ fuzzing: Elsewhere("check --without-fuzz: CI's Fuzz smoke job replays every target"), sizes: Here, part: OnePart({ index: 2, total: 5 }), describe: Run })
expect options(["--plan"]) == Ok({ fuzzing: Every, sizes: Here, part: Whole, describe: Summary })
expect options(["--plan", "--builds"]) == Ok({ fuzzing: Every, sizes: Here, part: Whole, describe: Builds })
expect options(["--builds"]) == Err(Unknown("--builds"))
expect options(["--without-sizes", "--without-fuzz"]) == Ok({ fuzzing: Elsewhere("check --without-fuzz: CI's Fuzz smoke job replays every target"), sizes: Elsewhere(sizes_elsewhere), part: Whole, describe: Run })
expect options(["--without-sizes", "--without-sizes"]) == Err(Unknown("--without-sizes"))
expect options(["--filter"]) == Err(Unknown("--filter"))
expect options(["--part", "two"]) == Err(Unknown("--part two"))
expect options(["--part"]) == Err(Unknown("--part"))
expect options(["--without-fuzz", "--without-fuzz"]) == Err(Unknown("--without-fuzz"))

## Both platform roots must fetch the same internal dependencies. A drift
## would give the oracle/fuzz package a different codec from shipped apps.
platform_packages! : Str => Try(List(Str), _)
platform_packages! = |root| {
	platform_source = Path.read_utf8!(Path.utf8("${root}/platform/main.roc"))?
	package_source = Path.read_utf8!(Path.utf8("${root}/platform/main-fuzz.roc"))?
	platform_dependencies = ApiSurface.dependencies(platform_source)?
	package_dependencies = ApiSurface.dependencies(package_source)?
	Ok(
		["parser", "unicode", "cbor"].fold(
			[],
			|problems, name| {
				platform_urls = platform_dependencies.keep_if(|dependency| dependency.name == name).map(|dependency| dependency.url)
				package_urls = package_dependencies.keep_if(|dependency| dependency.name == name).map(|dependency| dependency.url)
				if platform_urls.len() == 1 and platform_urls == package_urls {
					problems
				} else {
					problems.append("platform roots must declare the same single ${name} dependency")
				}
			},
		),
	)
}

## Every script root's `expect`s, and those of the modules it imports, run:
## each root under `scripts/` is tested with the tooling compiler, so a
## root added later is tested with no other edit. A root that imports the
## platform package is a driver of the platform's own tests, which
## `roc test platform/main-fuzz.roc` runs; testing it would run them again
## under the tooling compiler, so it is not tested, and an `expect` of its
## own is a problem instead of a test that never runs.
script_tests! : SpecSuite.Options => Try(List(Str), _)
script_tests! = |o| {
	var $roots = []
	for path in SpecSuite.files_with!("scripts", ".roc")? {
		$roots = $roots.append({ path, text: Path.read_utf8!(Path.utf8(path))? })
	}
	plan = script_test_plan($roots)
	results = Proc.parallel!(plan.test.map(|path| { program: o.tooling, args: ["test", path], cwd: "." }), Proc.compiler_jobs!(App)?)?
	Ok(plan.problems.concat(List.map2(plan.test, results, |path, r| (path, r)).keep_if(|(_, r)| r.code != 0).map(|(path, r)| "roc-stable test ${path} failed (exit ${r.code.to_str()}): ${r.output.trim()}")))
}

## Which script roots to test, and the roots that import the platform
## package yet declare `expect`s of their own.
script_test_plan : List({ path : Str, text : Str }) -> { test : List(Str), problems : List(Str) }
script_test_plan = |roots| {
	drives_platform = |text| text.split_on("\n").take_first(10).any(|line| line.contains("\"../platform/main"))
	own_expects = |text| text.split_on("\n").any(|line| line.starts_with("expect"))
	{
		test: roots.keep_if(|r| !drives_platform(r.text)).map(|r| r.path),
		problems: roots.keep_if(|r| drives_platform(r.text) and own_expects(r.text)).map(|r| "${r.path} imports the platform package, so no gate runs its own expects; move them to a module under scripts/src that a tested root imports"),
	}
}

## Roots are tested unless they import the platform package; such a root
## with an `expect` of its own is reported.
expect {
	plain = { path: "scripts/a.roc", text: "app [main!] {\n\tcli: platform \"u\",\n}\n\nexpect 1 == 1\n" }
	driver = { path: "scripts/b.roc", text: "app [main!] {\n\tpf: \"../platform/main-fuzz.roc\",\n}\n" }
	tested_driver = { path: "scripts/c.roc", text: "app [main!] {\n\tpf: \"../platform/main-fuzz.roc\",\n}\nexpect 1 == 1\n" }
	script_test_plan([plain, driver, tested_driver]) == { test: ["scripts/a.roc"], problems: ["scripts/c.roc imports the platform package, so no gate runs its own expects; move them to a module under scripts/src that a tested root imports"] }
}

## A task's script is the first element of its `Run`, when it is a path.
expect task_scripts("Task(\"a\", [Use(\"e\"), Run([\"scripts/a.roc\", \"--\"])]),\nTask(\"s\", [Run([\"node\", \"www/serve.mjs\"])]),\nTask(\"b\", [Run([\"scripts/b.roc\"])])") == ["scripts/a.roc", "scripts/b.roc"]

## A script that is not executable, or not tracked, is a problem; an
## executable one is not.
expect {
	listed = "100755 0123abcd 0\tscripts/a.roc\n100644 4567ef01 0\tscripts/b.roc\n"
	mode_problems(["scripts/a.roc", "scripts/b.roc", "scripts/c.roc"], listed)
		== [
			"scripts/b.roc is started by a Blueprint task but its git mode is 100644, not 100755: run git update-index --chmod=+x scripts/b.roc",
			"scripts/c.roc is started by a Blueprint task but git does not track it",
		]
}
