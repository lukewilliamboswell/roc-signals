import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import cli.Stderr
import cli.System
import Bundle
import Compiler
import Project
import Text

## `test`: build the app's native spec runner and run every spec in
## `specs/`. The runner drives the app's real engine without a browser, so
## a spec takes milliseconds.
Specs :: [].{

	## The outcome of one spec, from one line of the runner's report.
	Outcome : { id : Str, name : Str, status : [Passed, Failed, Unreadable], message : Str }

	## Run the specs. Fails with `SpecsFailed` when any spec did not pass,
	## after printing each outcome.
	run! : () => Try({}, _)
	run! = || {
		if !(Path.exists!(Path.utf8("main.roc"))?) {
			return Err(NoMainRoc)
		}
		specs = spec_files!()?
		if specs.is_empty() {
			return Err(NoSpecs)
		}
		target = Specs.target_of(System.target!())
		if !Bundle.spec_targets.contains(target) {
			return Err(SpecsUnsupported(target))
		}
		version = Compiler.version!()?
		Path.create_all!(Path.utf8(".signals/test"))?
		Stdout.line!("Building the app's spec runner...")?
		# The runner is a program of this system: `.exe` on Windows. A
		# program is started by its absolute path.
		runner = ".signals/test/runner${if (target.ends_with("win")) ".exe" else ""}"
		match Compiler.build!({ target, opt: "dev", output: runner })? {
			Built(report) => {
				shown = Compiler.report_on_success(report)
				if !shown.is_empty() {
					Stdout.line!(shown)?
				}
			}
			Failed(report) => return Err(BuildFailed({ report, version }))
		}
		count = specs.len()
		program = "${Project.with_slashes(Path.display(Env.cwd!()?))}/${runner}"
		evidence = Cmd.new(OsStr.from_str(program)).args(["--check-suite"].concat(specs).map(OsStr.from_str)).stdout(Capture).stderr(Capture).run!() ? |_| RunnerFailed({ cause: NotStarted, detail: program })
		checked = Specs.outcomes(Str.from_utf8_lossy(evidence.stdout_bytes))
		match Specs.unaccounted({ ids: specs.map(Specs.id_of), status: evidence.status, results: checked }) {
			Ok({}) => {}
			Err({ cause, detail }) => return Err(RunnerFailed({ cause, detail: "suite evidence: ${detail}\n${Str.from_utf8_lossy(evidence.stderr_bytes)}" }))
		}
		if checked.any(|outcome| outcome.status != Passed) {
			for outcome in checked.keep_if(|outcome| outcome.status != Passed) {
				Stdout.line!(Specs.show(outcome))?
			}
			return Err(SpecsFailed)
		}
		Stdout.line!("Running ${count.to_str()} spec${if (count == 1) "" else "s"}:")?
		output = Cmd.new(OsStr.from_str(program)).args(specs.map(OsStr.from_str)).stdout(Capture).stderr(Capture).run!() ? |_| RunnerFailed({ cause: NotStarted, detail: program })
		results = Specs.outcomes(Str.from_utf8_lossy(output.stdout_bytes))
		match Specs.unaccounted({ ids: specs.map(Specs.id_of), status: output.status, results }) {
			Ok({}) => {}
			Err({ cause, detail }) => return Err(RunnerFailed({ cause, detail: "${detail}\n${Str.from_utf8_lossy(output.stderr_bytes)}" }))
		}
		# Valid outcome records leave stderr available for native diagnostics,
		# including dbg. A malformed runner report is rendered by RunnerFailed
		# above instead, so its stderr is never printed twice.
		if !output.stderr_bytes.is_empty() {
			Stderr.write_bytes!(output.stderr_bytes)?
		}
		for outcome in results {
			Stdout.line!(Specs.show(outcome))?
		}
		failed = results.count_if(|o| o.status != Passed)
		Stdout.line!("\n${Specs.tally(results)}")?
		if (failed == 0) Ok({}) else Err(SpecsFailed)
	}

	## A spec's id as the runner reports it: its file name without the
	## directory or `.scm`.
	## TODO https://github.com/roc-lang/roc/issues/13221: split_on().last()
	## corrupts long interior strings in x64mac dev; split_last preserves them.
	id_of : Str -> Str
	id_of = |path| {
		base = match path.split_last("/") {
			Ok(parts) => parts.after
			Err(_) => path
		}
		base.drop_suffix(".scm")
	}

	## Why a run of the runner does not account for exactly the specs it was
	## given, by the rule the repository's own suite applies
	## (`scripts/src/SpecSuite.roc`, `judge`, which this tool cannot import):
	## one result for each spec and none for another, and an exit code the
	## runner returns for those results, 0 when every spec passed and 1 when
	## one did not. A runner that crashed (exit 70), failed an `expect` (71)
	## or was killed stops before it reports the rest, and that is never read
	## as a shorter run that passed. The cause says which rule the run broke,
	## so the failure is put into the right words: it `Stopped` before every
	## spec had a result, its exit code `Disagrees` with the results it gave,
	## or it gave `ExtraResults` (one for a spec it was not given, or two for
	## one). The detail names everything that is wrong.
	unaccounted : { ids : List(Str), status : [Exited(I32), Signaled(I32)], results : List(Outcome) } -> Try({}, { cause : [Stopped, Disagrees, ExtraResults], detail : Str })
	unaccounted = |{ ids, status, results }| {
		reported = results.map(|o| o.id)
		missing = ids.drop_if(|id| reported.contains(id))
		unknown = reported.drop_if(|id| ids.contains(id))
		repeated = ids.keep_if(|id| reported.count_if(|seen| seen == id) > 1)
		failures = results.count_if(|o| o.status != Passed)
		exit : Try({}, ([Stopped, Disagrees], Str))
		exit = match status {
			Exited(0) if failures == 0 => Ok({})
			Exited(1) if failures > 0 => Ok({})
			Exited(70) => Err((Stopped, "the runner crashed (exit 70: an engine contract error or an app's crash)"))
			Exited(71) => Err((Stopped, "an expect failed outside a worker job (exit 71)"))
			Exited(code) => Err((Disagrees, "the runner exited with ${code.to_str()} after ${failures.to_str()} failing spec${if (failures == 1) "" else "s"}"))
			Signaled(signal) => Err((Stopped, "the runner was stopped by signal ${signal.to_str()}"))
		}
		stopped = match exit {
			Err((Stopped, _)) => Bool.True
			_ => Bool.False
		}
		cause =
			if stopped or !missing.is_empty() {
				Stopped
			} else if exit.is_err() {
				Disagrees
			} else {
				ExtraResults
			}
		problems = []
			.concat(
				match exit {
					Ok({}) => []
					Err((_, reason)) => [reason]
				},
			)
			.concat(if (missing.is_empty()) [] else ["no result for ${Str.join_with(missing, ", ")}"])
			.concat(if (unknown.is_empty()) [] else ["a result for ${Str.join_with(unknown, ", ")}, which it was not given"])
			.concat(if (repeated.is_empty()) [] else ["more than one result for ${Str.join_with(repeated, ", ")}"])
		if (problems.is_empty()) Ok({}) else Err({ cause, detail: Str.join_with(problems, "; ") })
	}

	## The compiler's name for the machine's target.
	target_of : System.Target -> Str
	target_of = |target|
		match (target.os(), target.arch()) {
			(Linux(_), X64) => "x64musl"
			(Linux(_), Arm64) => "arm64musl"
			(MacOS(_), X64) => "x64mac"
			(MacOS(_), Arm64) => "arm64mac"
			(Windows(_), X64) => "x64win"
			(Windows(_), Arm64) => "arm64win"
		}

	## A target's name for people.
	system_name : Str -> Str
	system_name = |target|
		match target {
			"x64musl" => "Linux on x86-64"
			"arm64musl" => "Linux on ARM64"
			"x64mac" => "macOS on Intel"
			"arm64mac" => "macOS on Apple silicon"
			"x64win" => "Windows on x86-64"
			"arm64win" => "Windows on ARM64"
			other => other
		}

	## The outcomes in the runner's report: one JSON line per spec, in the
	## order the specs were given.
	outcomes : Str -> List(Outcome)
	outcomes = |report|
		Text.lines(report)
			.keep_if(|line| line.starts_with("{"))
			.map(
				|line| {
					id: json_field(line, "id") ?? "",
					name: json_field(line, "name") ?? "",
					status: match json_field(line, "status") {
						Ok("passed") => Passed
						Ok("failed") => Failed
						_ => Unreadable
					},
					message: json_field(line, "message") ?? "",
				},
			)

	## One spec's line, and for a failure the step that did not hold.
	show : Outcome -> Str
	show = |{ id, name, status, message }|
		match status {
			Passed => "  passed  ${name}"
			Failed => "  FAILED  ${name}\n          ${message}"
			Unreadable => "  ERROR   specs/${id}.scm could not be run\n          ${message}"
		}

	## The closing count.
	tally : List(Outcome) -> Str
	tally = |results| {
		passed = results.count_if(|o| o.status == Passed)
		failed = results.count_if(|o| o.status == Failed)
		unreadable = results.count_if(|o| o.status == Unreadable)
		total = results.len()
		if passed == total {
			if (total == 1) "The spec passed." else "All ${total.to_str()} specs passed."
		} else {
			parts = []
				.concat(if (failed > 0) ["${failed.to_str()} failed"] else [])
				.concat(if (unreadable > 0) ["${unreadable.to_str()} could not be run"] else [])
				.concat(if (passed > 0) ["${passed.to_str()} passed"] else [])
			"Of ${total.to_str()} specs, ${Str.join_with(parts, ", ")}. Each failure names its file, line and step. The spec language is described at https://lukewilliamboswell.github.io/roc-signals/docs/testing/"
		}
	}
}

## The `.scm` files in `specs/`, sorted.
spec_files! : () => Try(List(Str), _)
spec_files! = || {
	if !(Path.is_dir!(Path.utf8("specs")) ?? False) {
		return Ok([])
	}
	var $out = []
	for entry in Path.list!(Path.utf8("specs"))? {
		name = Project.with_slashes(Path.display(entry))
		if name.ends_with(".scm") {
			$out = $out.append(name)
		}
	}
	Ok($out.sort_with(Project.compare))
}

## The string value of `"key":"..."` in one line of JSON, unescaped. The
## runner's report is flat enough that the first occurrence of a key is the
## one wanted.
json_field : Str, Str -> Try(Str, [Missing])
json_field = |line, key| {
	rest = match line.split_on("\"${key}\":\"") {
		[_, after, ..] => after.to_utf8()
		_ => return Err(Missing)
	}
	var $out = []
	var $index = 0
	var $done = False
	while !$done and $index < rest.len() {
		byte = rest.get($index) ?? 0
		if byte == '"' {
			$done = True
		} else if byte == '\\' {
			escaped = rest.get($index + 1) ?? 0
			$out = $out.append(
				match escaped {
					'n' => '\n'
					't' => '\t'
					other => other
				},
			)
			$index = $index + 2
		} else {
			$out = $out.append(byte)
			$index = $index + 1
		}
	}
	Ok(Str.from_utf8_lossy($out))
}

## A passing, a failing and an unreadable spec are read from the runner's
## report, with the failure's message unescaped.
expect {
	failing = "{\"protocol\":\"roc-signals/spec-result/v2\",\"id\":\"bad\",\"name\":\"the counter counts\",\"status\":\"failed\",\"duration_ns\":1,\"failure\":{\"phase\":\"step\",\"kind\":\"assertion\",\"message\":\"specs/bad.scm:5:5: expect-text: (test-id \\\"count\\\") text \\\"1\\\", expected \\\"3\\\"\",\"step\":2}}"
	others =
		\\{"protocol":"roc-signals/spec-result/v2","id":"odd","name":"","status":"error","duration_ns":0,"failure":{"phase":"parse","kind":"parse","message":"specs/odd.scm:3:5: unknown step frobnicate","step":0}}
		\\{"protocol":"roc-signals/spec-result/v2","id":"counter","name":"the counter counts both ways","status":"passed","duration_ns":614142,"failure":null}
		\\specs: 1 passed, 1 failed, 1 error
	actual = Specs.outcomes("${failing}\n${others}").map(Specs.show)
	expected = [
		"  FAILED  the counter counts\n          specs/bad.scm:5:5: expect-text: (test-id \"count\") text \"1\", expected \"3\"",
		"  ERROR   specs/odd.scm could not be run\n          specs/odd.scm:3:5: unknown step frobnicate",
		"  passed  the counter counts both ways",
	]
	actual == expected
}

## The count says what passed, and points at the spec language when not all
## did.
expect {
	passed = { id: "a", name: "a", status: Passed, message: "" }
	failed = { ..passed, status: Failed }
	actual = [Specs.tally([passed]), Specs.tally([passed, passed]), Specs.tally([failed, passed]).split_on(".").first() ?? ""]
	actual == ["The spec passed.", "All 2 specs passed.", "Of 2 specs, 1 failed, 1 passed"]
}

## Every system the compiler builds for has a name for people.
expect ["x64musl", "arm64mac", "x64win"].map(Specs.system_name) == ["Linux on x86-64", "macOS on Apple silicon", "Windows on x86-64"]

## A run is accounted for when every spec has one result and the exit code
## agrees with them; a crash after some results, a missing or extra result,
## and an exit code the results contradict are each named.
expect {
	ok = |id| { id, name: id, status: Passed, message: "" }
	bad = |id| { ..ok(id), status: Failed }
	actual = [
		Specs.unaccounted({ ids: ["a", "b"], status: Exited(0), results: [ok("a"), ok("b")] }),
		Specs.unaccounted({ ids: ["a", "b"], status: Exited(1), results: [ok("a"), bad("b")] }),
		Specs.unaccounted({ ids: ["a", "b", "c"], status: Exited(70), results: [ok("a")] }),
		Specs.unaccounted({ ids: ["a", "b"], status: Exited(0), results: [ok("a"), ok("b"), ok("a"), ok("z")] }),
		Specs.unaccounted({ ids: ["a"], status: Exited(0), results: [bad("a")] }),
		Specs.unaccounted({ ids: ["a"], status: Exited(1), results: [ok("a")] }),
		Specs.unaccounted({ ids: ["a"], status: Signaled(9), results: [] }),
	]
	expected = [
		Ok({}),
		Ok({}),
		Err({ cause: Stopped, detail: "the runner crashed (exit 70: an engine contract error or an app's crash); no result for b, c" }),
		Err({ cause: ExtraResults, detail: "a result for z, which it was not given; more than one result for a" }),
		Err({ cause: Disagrees, detail: "the runner exited with 0 after 1 failing spec" }),
		Err({ cause: Disagrees, detail: "the runner exited with 1 after 0 failing specs" }),
		Err({ cause: Stopped, detail: "the runner was stopped by signal 9; no result for a" }),
	]
	actual == expected
}

## A spec's id is its file name without the directory or `.scm`.
expect ["specs/counter.scm", "counter.scm", "a/b/c.d.scm", "specs/round-trip-search-on-the-timeline.scm", "rép/λ-long-identifier-with-unicode.scm", "a/", "a/.scm", "a/x.scm.scm", "a/no-suffix"].map(Specs.id_of) == ["counter", "counter", "c.d", "round-trip-search-on-the-timeline", "λ-long-identifier-with-unicode", "", "", "x.scm", "no-suffix"]
