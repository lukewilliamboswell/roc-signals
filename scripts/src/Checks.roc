import cli.Env
import cli.Path
import Proc
import SpecSuite
import PlatformTest

## The steps `check_all.roc` and `spec.roc` share.
Checks := [].{

	## The pinned tools are the ones Blueprint.roc puts on PATH.
	options! : { pending_phase3 : Bool, filter : Str } => Try(SpecSuite.Options, _)
	options! = |{ pending_phase3, filter }| {
		root = Path.display(Env.cwd!()?)
		build_dir = match Env.var_str!("ROC_SIGNALS_BUILD_DIR") {
			Ok(dir) if dir.starts_with("/") => dir
			Ok(dir) => "${root}/${dir}"
			Err(_) => "${root}/.build"
		}
		Ok({ root, build_dir, compiler: "roc-stable", zig: "zig", node: "node", chrome: "google-chrome", pending_phase3, filter })
	}

	prepare_platform! : SpecSuite.Options => Try({}, _)
	prepare_platform! = |o| PlatformTest.prepare!({ root: o.root, build_dir: o.build_dir, zig: o.zig })

	## Build and run one app's specs natively, and in Chrome when `browser`.
	## Returns the tallies and the native runner's path.
	run_app! : SpecSuite.Options, Str, Bool => Try({ native : SpecSuite.Tally, browser : SpecSuite.Tally, runner : Str }, _)
	run_app! = |o, example, browser| {
		specs = SpecSuite.spec_files!(example)?
		runner = SpecSuite.build_native!(o, example)?
		native = SpecSuite.tally(SpecSuite.empty_tally, example, Native, SpecSuite.run_native!(o, runner, specs)?)
		Proc.note!(SpecSuite.summary(example, Native, native))
		in_browser =
			if browser {
				wasm = SpecSuite.build_wasm!(o, example)?
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
		pending: a.pending + b.pending,
		pending_steps: a.pending_steps + b.pending_steps,
		xfail: a.xfail + b.xfail,
		problems: a.problems.concat(b.problems),
	}

	## Each runner must reject a deliberately broken spec: a copy of
	## kanban-board's initial-render with one expected text changed. A runner
	## that passes it is not evidence of anything.
	mutation! : SpecSuite.Options, Str, Str => Try(List(Str), _)
	mutation! = |o, runner, wasm| {
		original = Path.read_utf8!(Path.utf8("examples-web/kanban-board/specs/initial-render.scm"))?
		good = "(expect-text (test-id \"board-total\") \"5\")"
		if !original.contains(good) {
			return Ok(["mutation: initial-render.scm no longer holds ${good}; choose a new assertion to break"])
		}
		dir = "${o.build_dir}/mutation"
		SpecSuite.fresh_dir!(dir)?
		broken = "${dir}/initial-render-broken.scm"
		Path.write_utf8!(Path.utf8(broken), original.replace_each(good, "(expect-text (test-id \"board-total\") \"6\")"))?
		native = SpecSuite.run_native!({ ..o, filter: "*" }, runner, [broken])?
		steps = Proc.capture!({ program: runner, args: ["spec", "--emit-steps", broken], cwd: "." })?
		Path.write_bytes!(Path.utf8("${dir}/steps.jsonl"), steps)?
		{ stdout, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", SpecSuite.runtime, "--steps", "${dir}/steps.jsonl", "--chrome", o.chrome, "--json-lines"], cwd: "." })?
		in_browser = Str.from_utf8_lossy(stdout).split_on("\n")
		rejected = |lines| lines.any(|l| SpecSuite.json_field(l, "status") == "failed" and SpecSuite.json_message(l).contains("expected \\\"6\\\""))
		Ok(
			[]
				.concat(if (rejected(native)) [] else ["mutation: the native runner did not reject the broken spec"])
				.concat(if (rejected(in_browser)) [] else ["mutation: the browser runner did not reject the broken spec"]),
		)
	}
}
