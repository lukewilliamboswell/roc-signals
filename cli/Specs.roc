import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import cli.System
import Bundle
import Compiler
import Project

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
		Stdout.line!("Running ${count.to_str()} spec${if (count == 1) "" else "s"}:")?
		program = "${Project.with_slashes(Path.display(Env.cwd!()?))}/${runner}"
		output = Cmd.new(OsStr.from_str(program)).args(specs.map(OsStr.from_str)).stdout(Capture).stderr(Capture).run!() ? |_| RunnerFailed("")
		results = Specs.outcomes(Str.from_utf8_lossy(output.stdout_bytes))
		if results.len() != count {
			return Err(RunnerFailed(Str.from_utf8_lossy(output.stderr_bytes)))
		}
		for outcome in results {
			Stdout.line!(Specs.show(outcome))?
		}
		failed = results.count_if(|o| o.status != Passed)
		Stdout.line!("\n${Specs.tally(results)}")?
		if (failed == 0) Ok({}) else Err(SpecsFailed)
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
		report
			.split_on("\n")
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
