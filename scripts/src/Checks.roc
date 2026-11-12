import cli.Env
import cli.Path
import Proc
import SpecSuite
import PlatformTest

## The steps `check_all.roc` and `spec.roc` share.
Checks := [].{

	## The tools Blueprint.roc puts on PATH, and the package compiler: `roc`, the
	## latest Roc nightly, which the environment expects on PATH and never pins
	## (roc-automation's model). `roc-stable`, pinned in Blueprint.roc, runs and
	## checks the scripts only.
	options! : { filter : Str } => Try(SpecSuite.Options, _)
	options! = |{ filter }| {
		root = Path.display(Env.cwd!()?)
		build_dir = match Env.var_str!("ROC_SIGNALS_BUILD_DIR") {
			Ok(dir) if dir.starts_with("/") => dir
			Ok(dir) => "${root}/${dir}"
			Err(_) => "${root}/.build"
		}
		Ok({ root, build_dir, compiler: "roc", tooling: "roc-stable", zig: "zig", node: "node", chrome: "google-chrome", filter })
	}

	prepare_platform! : SpecSuite.Options => Try({}, _)
	prepare_platform! = |o| PlatformTest.prepare!({ root: o.root, build_dir: o.build_dir, zig: o.zig })

	## Run the top-level `expect`s of every example and test app, in
	## parallel: `roc test` of an app's `main.roc` runs those of every module
	## the app imports. A decision is tested as a function (design.md,
	## "Decisions as functions"), and those tests are `expect`s beside the
	## transitions, in the modules of the apps.
	app_expects! : SpecSuite.Options => Try(List(Str), _)
	app_expects! = |o| {
		dirs = SpecSuite.app_dirs!()?
		results = Proc.parallel!(dirs.map(|dir| { program: o.compiler, args: ["test", "${dir}/main.roc"], cwd: o.root }), Proc.cpus!())?
		Ok(List.map2(dirs, results, |dir, r| if (r.code == 0) [] else ["roc test ${dir}/main.roc failed: ${r.output.trim()}"]).join())
	}

	## Run one app's specs natively, and in Chrome when `browser`, with the
	## builds `SpecSuite.build!` made.
	## Returns the tallies and the native runner's path.
	run_app! : SpecSuite.Options, Str, Bool => Try({ native : SpecSuite.Tally, browser : SpecSuite.Tally, runner : Str }, _)
	run_app! = |o, example, browser| {
		specs = SpecSuite.spec_files!(example)?
		runner = SpecSuite.runner_of(o, example)
		native = SpecSuite.tally(SpecSuite.empty_tally, example, Native, SpecSuite.run_native!(o, runner, specs)?)
		Proc.note!(SpecSuite.summary(example, Native, native))
		in_browser =
			if browser {
				wasm = SpecSuite.wasm_of(o, example)
				t = SpecSuite.tally(SpecSuite.empty_tally, example, Browser, SpecSuite.run_browser!(o, example, runner, wasm, specs)?)
				Proc.note!(SpecSuite.summary(example, Browser, t))
				t
			} else {
				SpecSuite.empty_tally
			}
		Ok({ native, browser: in_browser, runner })
	}

	add : SpecSuite.Tally, SpecSuite.Tally -> SpecSuite.Tally
	add = |a, b| {
		passed: a.passed + b.passed,
		failed: a.failed + b.failed,
		problems: a.problems.concat(b.problems),
	}

	## A deliberately broken spec: a copy of `spec` (a spec of `example`) with the
	## assertion `good` replaced by `bad`, which each runner must reject with
	## a message holding `rejection`.
	Broken : { example : Str, spec : Str, good : Str, bad : Str, rejection : Str }

	## The broken specs `check` runs: one expected text changed in
	## kanban-board's initial render, and a crashing worker job expected to
	## be lost to the wrong fault class (the native runner's child process and
	## the browser's worker must both report the class the task's crash
	## has).
	broken_specs : List(Broken)
	broken_specs = [
		{ example: "kanban-board", spec: "examples/kanban-board/specs/initial-render.scm", good: "(expect-text (test-id \"board-total\") \"5\")", bad: "(expect-text (test-id \"board-total\") \"6\")", rejection: "expected \\\"6\\\"" },
		{ example: "workers", spec: "tests/apps/workers/specs/crash.scm", good: "(expect-text (test-id \"log\") \"crash:lost AppCrash\")", bad: "(expect-text (test-id \"log\") \"crash:lost Contract\")", rejection: "expected \\\"crash:lost Contract\\\"" },
	]

	## Each runner must reject each deliberately broken spec
	## (`broken_specs`). A runner that passes one is not evidence of anything.
	broken_spec! : SpecSuite.Options, Broken => Try(List(Str), _)
	broken_spec! = |o, { example, spec, good, bad, rejection }| {
		original = Path.read_utf8!(Path.utf8(spec))?
		if !original.contains(good) {
			return Ok(["broken-spec self-check: ${spec} no longer holds ${good}; choose a new assertion to break"])
		}
		runner = SpecSuite.runner_of(o, example)
		dir = "${o.build_dir}/broken-spec/${example}"
		SpecSuite.fresh_dir!(dir)?
		broken = "${dir}/broken.scm"
		Path.write_utf8!(Path.utf8(broken), original.replace_each(good, bad))?
		native = SpecSuite.run_native!({ ..o, filter: "*" }, runner, [broken])?
		steps = Proc.capture!({ program: runner, args: ["--emit-steps", broken], cwd: "." })?
		Path.write_bytes!(Path.utf8("${dir}/steps.jsonl"), steps)?
		{ stdout, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", SpecSuite.wasm_of(o, example), "--runtime", SpecSuite.runtime, "--steps", "${dir}/steps.jsonl", "--chrome", o.chrome, "--json-lines"], cwd: "." })?
		in_browser = Str.from_utf8_lossy(stdout).split_on("\n")
		rejected = |lines| lines.any(|l| SpecSuite.json_field(l, "status") == "failed" and SpecSuite.json_message(l).contains(rejection))
		Ok(
			[]
				.concat(if (rejected(native)) [] else ["broken-spec self-check: the native runner did not reject the broken ${spec}"])
				.concat(if (rejected(in_browser)) [] else ["broken-spec self-check: the browser runner did not reject the broken ${spec}"]),
		)
	}

	## The browser runner has a handler for every step and setup form of the
	## grammar, and for nothing else: the native runner prints the grammar
	## (`--grammar`, from the parser's form tables) and
	## `replay.mjs --check-grammar` compares it with its handler tables. The
	## native runner's own coverage is its exhaustive `match`.
	grammar! : SpecSuite.Options, Str => Try(List(Str), _)
	grammar! = |o, runner| {
		dir = "${o.build_dir}/grammar"
		SpecSuite.fresh_dir!(dir)?
		grammar = Proc.capture!({ program: runner, args: ["--grammar"], cwd: "." })?
		Path.write_bytes!(Path.utf8("${dir}/grammar.json"), grammar)?
		# replay.mjs names each mismatch on stderr, which reaches the log.
		{ code, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--check-grammar", "${dir}/grammar.json"], cwd: "." })?
		if (code == 0) Ok([]) else Ok(["grammar coverage: replay.mjs and the grammar disagree (see above)"])
	}
}
