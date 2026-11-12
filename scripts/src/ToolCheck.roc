import cli.Env
import cli.OsStr
import cli.Path
import Proc
import Release
import SpecSuite
import ToolRelease

## The `signals.roc` tool's end-to-end check, run by `check` after the
## release dry run has built the tool. It runs the released `signals.roc`
## the way an app's author does, from empty directories, with the staged
## package in place of its release URL (`roc --replace-dep`) and the
## working tree's platform in place of the release's
## (`ROC_SIGNALS_PLATFORM`): `init`, `test` and `build` on the counter and
## on the Worker Lab; every failure the tool explains (a misused command
## line, a missing `main.roc`, `index.html` or spec, a failing spec, a build
## error, no `roc` on the PATH, a compiler other than the release's); the
## built `dist/` mounting from a plain static server in Chrome with a worker
## running jobs (`tests/browser/tool-dist.mjs`); and `serve` in Chrome
## (`tests/browser/tool-serve.mjs`).
ToolCheck := [].{

	## The checked-in `cli/Bundle.roc` is what the release generates for a
	## checkout, so the development copy lists the same runtime files and
	## scaffold as every release. When it is not, the expected file is
	## written beside the build for the contributor to copy.
	bundle_current! : SpecSuite.Options => Try(List(Str), _)
	bundle_current! = |o| {
		expected = ToolRelease.development_module({ scaffold: ToolRelease.scaffold_files!()?, bundle_files: Release.bundle_files })
		actual = Path.read_utf8!(Path.utf8("cli/Bundle.roc"))?
		if actual == expected {
			Ok([])
		} else {
			Path.create_all!(Path.utf8(o.build_dir))?
			Path.write_utf8!(Path.utf8("${o.build_dir}/Bundle.roc"), expected)?
			Ok(["cli/Bundle.roc is not what the release generates for a checkout: copy ${o.build_dir}/Bundle.roc over it"])
		}
	}

	## Run the whole check. Returns the problems found.
	run! : SpecSuite.Options => Try(List(Str), _)
	run! = |o| {
		shim = "${o.build_dir}/release/signals.roc"
		package_url = ToolCheck.package_of(Path.read_utf8!(Path.utf8(shim))?) ? |_| NoPackageInToolApp(shim)
		roc = Str.from_utf8_lossy(Proc.capture!({ program: "sh", args: ["-c", "command -v ${o.compiler}"], cwd: o.root })?).trim()
		scratch = "${o.build_dir}/tool-check"
		SpecSuite.fresh_dir!(scratch)?
		Path.copy!(Path.utf8(shim), Path.utf8("${scratch}/signals.roc"))?
		tool = { roc, shim: "${scratch}/signals.roc", package_url, package_main: "${ToolRelease.stage_of(o)}/main.roc", platform_main: "${o.root}/platform/main.roc", path: Inherit }
		counter = "${scratch}/counter"
		lab = "${scratch}/lab"
		var $problems = []

		# Creating an app, and what init refuses.
		$problems = $problems.concat(judge(run_tool!(tool, scratch, ["init", "counter"])?, { code: 0, says: ["Created the app counter, a counter on roc-signals", "  cd counter\n  roc signals.roc serve"] }))
		for file in ["signals.roc", "main.roc", "Counter.roc", "index.html", "specs/counter.scm", ".gitignore"] {
			if !(Path.exists!(Path.utf8("${counter}/${file}"))?) {
				$problems = $problems.append("signals.roc init did not write ${file}")
			}
		}
		main = Path.read_utf8!(Path.utf8("${counter}/main.roc"))?
		if !main.contains("platform \"https://") or Path.read_utf8!(Path.utf8("${counter}/Counter.roc"))?.contains("# region") {
			$problems = $problems.append("signals.roc init: main.roc must name the release's platform, and Counter.roc must have no region markers")
		}
		$problems = $problems.concat(judge(run_tool!(tool, scratch, ["init", "counter"])?, { code: 1, says: ["counter/signals.roc already exists, so init changed nothing"] }))
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["init"])?, { code: 1, says: ["Counter.roc already exists, so init changed nothing"] }))
		Path.create_all!(Path.utf8("${scratch}/empty"))?
		$problems = $problems.concat(judge(run_tool!(tool, "${scratch}/empty", ["init", "app"])?, { code: 1, says: ["init copies signals.roc into the new app, but there is no signals.roc in this directory, so app was not created."] }))

		# A misused command line, and a directory with no app.
		$problems = $problems.concat(judge(run_tool!(tool, scratch, ["srve"])?, { code: 2, says: ["There is no command \"srve\". The commands are init, serve, build and test"] }))
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["serve", "--port", "http"])?, { code: 2, says: ["--port takes a port number from 1 to 65535, and \"http\" is not one."] }))
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["build", "--watch"])?, { code: 2, says: ["build does not take \"--watch\"."] }))
		$problems = $problems.concat(judge(run_tool!(tool, scratch, ["build"])?, { code: 1, says: ["There is no main.roc here, so there is no app to work on."] }))

		# The counter's specs and its deployable build.
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["test"])?, { code: 0, says: ["Running 1 spec:", "  passed  the counter counts both ways", "The spec passed."] }))
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["build"])?, { code: 0, says: ["Built the app into dist/:", "  dist/index.html", "/app.wasm", "/runtime.mjs", "/worker.mjs"] }))
		$problems = $problems.concat(dist_problems!(o, counter)?)

		# What the tool says when something is missing or wrong.
		Path.rename!(Path.utf8("${counter}/index.html"), Path.utf8("${counter}/away.html"))?
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["build"])?, { code: 1, says: ["There is no index.html here, and the app needs a page to mount it."] }))
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["serve"])?, { code: 1, says: ["There is no index.html here"] }))
		Path.rename!(Path.utf8("${counter}/away.html"), Path.utf8("${counter}/index.html"))?
		spec = Path.read_utf8!(Path.utf8("${counter}/specs/counter.scm"))?
		Path.write_utf8!(Path.utf8("${counter}/specs/wrong.scm"), spec.replace_each("\"2\"", "\"3\""))?
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["test"])?, { code: 1, says: ["  FAILED  the counter counts both ways", "specs/wrong.scm:", "expected \"3\"", "Of 2 specs, 1 failed, 1 passed."] }))
		Path.delete!(Path.utf8("${counter}/specs/wrong.scm"))?
		Path.rename!(Path.utf8("${counter}/specs"), Path.utf8("${counter}/specs-away"))?
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["test"])?, { code: 1, says: ["There are no specs to run: specs/ holds no .scm files."] }))
		Path.rename!(Path.utf8("${counter}/specs-away"), Path.utf8("${counter}/specs"))?
		source = Path.read_utf8!(Path.utf8("${counter}/Counter.roc"))?
		Path.write_utf8!(Path.utf8("${counter}/Counter.roc"), source.replace_each("Engine.state(0,", "Engine.state(\"zero\","))?
		$problems = $problems.concat(judge(run_tool!(tool, counter, ["build"])?, { code: 1, says: ["Counter.roc", "The build failed: the compiler's report is above."] }))
		# A compiler other than the release's: a `roc` that reports another
		# version and otherwise runs the real one.
		other = "${scratch}/other-roc"
		Path.create_all!(Path.utf8(other))?
		Path.write_utf8!(Path.utf8("${other}/roc"), "#!/bin/sh\nif [ \"$1\" = version ]; then echo 'Roc compiler version nightly-2000-01-01-0000000'; exit 0; fi\nexec '${roc}' \"$@\"\n")?
		Proc.run!({ program: "chmod", args: ["+x", "${other}/roc"], cwd: o.root })?
		$problems = $problems.concat(judge(run_tool!({ ..tool, path: Prepend(other) }, counter, ["build"])?, { code: 1, says: ["The build failed", "and `roc version` says nightly-2000-01-01-0000000. If the errors are not in your code, install"] }))
		Path.write_utf8!(Path.utf8("${counter}/Counter.roc"), source)?
		$problems = $problems.concat(judge(run_tool!({ ..tool, path: Only("/usr/bin:/bin") }, counter, ["build"])?, { code: 1, says: ["The Roc compiler is not on your PATH as `roc`, so the app cannot be built."] }))

		# A worker-using app: the Worker Lab's modules and specs in a new app.
		$problems = $problems.concat(judge(run_tool!(tool, scratch, ["init", "lab"])?, { code: 0, says: ["Created the app lab"] }))
		Path.delete!(Path.utf8("${lab}/Counter.roc"))?
		Path.delete!(Path.utf8("${lab}/specs/counter.scm"))?
		for file in SpecSuite.roc_files!("examples/worker-lab")?.keep_if(|f| !f.ends_with("/main.roc") and Release.is_archived(f)) {
			Path.copy!(Path.utf8(file), Path.utf8("${lab}/${file.split_on("/").last() ?? file}"))?
		}
		lab_specs = SpecSuite.files_with!("examples/worker-lab/specs", ".scm")?
		for file in lab_specs {
			Path.copy!(Path.utf8(file), Path.utf8("${lab}/specs/${file.split_on("/").last() ?? file}"))?
		}
		Path.write_utf8!(Path.utf8("${lab}/main.roc"), main.replace_each("import Counter", "import LabApp").replace_each("Counter.program", "LabApp.program"))?
		$problems = $problems.concat(judge(run_tool!(tool, lab, ["test"])?, { code: 0, says: ["All ${lab_specs.len().to_str()} specs passed."] }))
		# A style the page links goes into the hashed directory; a file
		# under public/ keeps its name at the top of dist/.
		Path.write_utf8!(Path.utf8("${lab}/style.css"), "body { margin: 0; }\n")?
		Path.create_all!(Path.utf8("${lab}/public"))?
		Path.write_utf8!(Path.utf8("${lab}/public/robots.txt"), "User-agent: *\n")?
		page = Path.read_utf8!(Path.utf8("${lab}/index.html"))?
		Path.write_utf8!(Path.utf8("${lab}/index.html"), page.replace_first("</head>", "<link rel=\"stylesheet\" href=\"style.css\"></head>"))?
		$problems = $problems.concat(judge(run_tool!(tool, lab, ["build"])?, { code: 0, says: ["Built the app into dist/:", "/style.css", "  dist/robots.txt"] }))
		$problems = $problems.concat(dist_problems!(o, lab)?)
		built = Path.read_utf8!(Path.utf8("${lab}/dist/index.html"))?
		if !built.contains("href=\"assets/") or !(Path.exists!(Path.utf8("${lab}/dist/robots.txt"))?) {
			$problems = $problems.append("signals.roc build: the page's style must be hashed and public/robots.txt copied to dist/robots.txt")
		}
		dist_code = Proc.status!({ program: o.node, args: ["tests/browser/tool-dist.mjs", "--dist", "${lab}/dist", "--chrome", o.chrome], cwd: o.root })?
		if dist_code != 0 {
			$problems = $problems.append("tests/browser/tool-dist.mjs failed (exit ${dist_code.to_str()})")
		}

		# `serve` in Chrome, on the counter.
		serve_code = Proc.status!({ program: o.node, args: ["tests/browser/tool-serve.mjs", "--app", counter, "--roc", roc, "--package", package_url, "--package-main", tool.package_main, "--platform", tool.platform_main, "--chrome", o.chrome], cwd: o.root })?
		if serve_code != 0 {
			$problems = $problems.append("tests/browser/tool-serve.mjs failed (exit ${serve_code.to_str()})")
		}
		Ok($problems)
	}

	## The package URL `signals.roc` names.
	package_of : Str -> Try(Str, [NoPackage])
	package_of = |text|
		match text.split_on("signals: \"") {
			[_, rest, ..] => rest.split_on("\"").first().map_err(|_| NoPackage)
			_ => Err(NoPackage)
		}

	## The problems with one run of the tool: an exit code other than the
	## one wanted, or a sentence it should have said and did not.
	judge : { code : I32, output : Str, args : List(Str) }, { code : I32, says : List(Str) } -> List(Str)
	judge = |actual, wanted| {
		label = "signals.roc ${Str.join_with(actual.args, " ")}"
		code = if (actual.code == wanted.code) [] else ["${label} exited with ${actual.code.to_str()}, not ${wanted.code.to_str()}"]
		missing = wanted.says.drop_if(|text| actual.output.contains(text)).map(|text| "${label} did not say: ${text}")
		code.concat(missing)
	}
}

## How the check runs the tool: the `roc` that runs `signals.roc`, the
## staged package that replaces the release URL, the working tree's
## platform, and the PATH the tool sees.
Tool : { roc : Str, shim : Str, package_url : Str, package_main : Str, platform_main : Str, path : [Inherit, Prepend(Str), Only(Str)] }

## Run `roc signals.roc ARGS` in `dir`, print what it said, and return it.
run_tool! : Tool, Str, List(Str) => Try({ code : I32, output : Str, args : List(Str) }, _)
run_tool! = |tool, dir, args| {
	full = ["--replace-dep", tool.package_url, tool.package_main, tool.shim].concat(args)
	inherited = Env.var_str!("PATH") ?? ""
	path = match tool.path {
		Inherit => inherited
		Prepend(dir_first) => "${dir_first}:${inherited}"
		Only(value) => value
	}
	Proc.note!("RUN (cd ${dir} && roc signals.roc ${Str.join_with(args, " ")})")
	output = Proc.cmd({ program: tool.roc, args: full, cwd: dir })
		.env(OsStr.from_str("ROC_SIGNALS_PLATFORM"), OsStr.from_str(tool.platform_main))
		.env(OsStr.from_str("PATH"), OsStr.from_str(path))
		.stderr(MergeWithStdout)
		.run!() ? |e| ToolDidNotRun(Str.inspect(e))
	text = Str.from_utf8_lossy(output.stdout_bytes)
	Proc.note!(text)
	code = match output.status {
		Exited(c) => c
		Signaled(_) => -1
	}
	Ok({ code, output: text, args })
}

## The built `dist/` of the app in `dir`: its page names the hashed
## module and runtime, and the module mounts with the release check
## helper.
dist_problems! : SpecSuite.Options, Str => Try(List(Str), _)
dist_problems! = |o, dir| {
	page = Path.read_utf8!(Path.utf8("${dir}/dist/index.html"))?
	hashed = match SpecSuite.files_with!("${dir}/dist/assets", "")? {
		[one] => one
		found => return Ok(["signals.roc build: dist/assets/ should hold one hashed directory, not ${Str.inspect(found)}"])
	}
	name = hashed.split_on("/").last() ?? hashed
	var $problems = []
	for url in ["\"./assets/${name}/runtime.mjs\"", "\"assets/${name}/app.wasm\""] {
		if !page.contains(url) {
			$problems = $problems.append("signals.roc build: dist/index.html does not name ${url}")
		}
	}
	for file in ["app.wasm", "runtime.mjs", "worker.mjs"] {
		if !(Path.exists!(Path.utf8("${hashed}/${file}"))?) {
			$problems = $problems.append("signals.roc build: dist/assets/${name}/ has no ${file}")
		}
	}
	{ code, stdout } = Proc.output!({ program: o.node, args: ["tests/release/check.mjs", "${hashed}/app.wasm"], cwd: o.root })?
	Ok(if (code == 0) $problems else $problems.append("signals.roc build: the module in ${dir}/dist does not mount: ${Str.from_utf8_lossy(stdout)}"))
}

## A run passes when its code and every sentence match.
expect ToolCheck.judge({ code: 0, output: "Built. All done.", args: ["build"] }, { code: 0, says: ["Built."] }) == []

## A wrong code and a missing sentence are both reported.
expect ToolCheck.judge({ code: 1, output: "x", args: ["test"] }, { code: 0, says: ["y"] }) == ["signals.roc test exited with 1, not 0", "signals.roc test did not say: y"]

## The release tells the tool every system its platform builds a spec runner for.
expect ToolRelease.spec_targets(Release.bundle_files) == ["x64musl", "arm64mac", "x64mac", "x64win"]
