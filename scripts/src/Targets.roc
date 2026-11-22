import cli.Path
import cli.Monotonic
import Proc
import SpecSuite
import CompilerProfile

## The roc-fuzz targets, the browser contract tests, the soak runs and the
## js-framework-benchmark check.
##
## Every property remains beside the modules and saved inputs it tests, with a
## thin standalone roc-fuzz app. Seven repository suite roots share the compiler
## work; the member registry names its standalone root, canonical property
## module and suite explicitly. Selection, reports and failures stay per member.
## Platform properties use the private engine package; example properties
## continue to test only their app's pure modules.
Targets := [].{
	Fuzz : { name : Str, main : Str, property : Str, suite : Str }

	fuzz_targets : List(Fuzz)
	fuzz_targets = [
		{ name: "links", main: "fuzz/links/main.roc", property: "fuzz/links/FuzzLinksProperty.roc", suite: "FuzzSyntax.roc" },
		{ name: "base64", main: "fuzz/base64/main.roc", property: "fuzz/base64/FuzzBase64Property.roc", suite: "FuzzSyntax.roc" },
		{ name: "crypto", main: "fuzz/crypto/main.roc", property: "fuzz/crypto/FuzzCryptoProperty.roc", suite: "FuzzCodecs.roc" },
		{ name: "boot", main: "fuzz/boot/main.roc", property: "fuzz/boot/FuzzBootProperty.roc", suite: "FuzzCodecs.roc" },
		{ name: "scm-parse", main: "fuzz/scm-parse/main.roc", property: "fuzz/scm-parse/FuzzScmParseProperty.roc", suite: "FuzzSyntax.roc" },
		{ name: "protocol-facts", main: "fuzz/protocol-facts/main.roc", property: "fuzz/protocol-facts/FuzzProtocolFactsProperty.roc", suite: "FuzzSyntax.roc" },
		{ name: "wire", main: "fuzz/wire/main.roc", property: "fuzz/wire/FuzzWireProperty.roc", suite: "FuzzCodecs.roc" },
		{ name: "structure", main: "fuzz/structure/main.roc", property: "fuzz/structure/FuzzStructureProperty.roc", suite: "FuzzRendering.roc" },
		{ name: "dom", main: "fuzz/dom/main.roc", property: "fuzz/dom/FuzzDomProperty.roc", suite: "FuzzRendering.roc" },
		{ name: "markup", main: "fuzz/markup/main.roc", property: "fuzz/markup/FuzzMarkupProperty.roc", suite: "FuzzRendering.roc" },
		{ name: "startup-placeholders", main: "fuzz/startup-placeholders/main.roc", property: "fuzz/startup-placeholders/FuzzStartupPlaceholdersProperty.roc", suite: "FuzzLifecycle.roc" },
		{ name: "table-view", main: "fuzz/table-view/main.roc", property: "fuzz/table-view/FuzzTableViewProperty.roc", suite: "FuzzLifecycle.roc" },
		{ name: "masks", main: "fuzz/masks/main.roc", property: "fuzz/masks/FuzzMasksProperty.roc", suite: "FuzzCores.roc" },
		{ name: "result-readers", main: "fuzz/result-readers/main.roc", property: "fuzz/result-readers/FuzzResultReadersProperty.roc", suite: "FuzzCodecs.roc" },
		{ name: "port-json", main: "fuzz/port-json/main.roc", property: "fuzz/port-json/FuzzPortJsonProperty.roc", suite: "FuzzCodecs.roc" },
		{ name: "url", main: "fuzz/url/main.roc", property: "fuzz/url/FuzzUrlProperty.roc", suite: "FuzzSyntax.roc" },
		{ name: "names", main: "fuzz/names/main.roc", property: "fuzz/names/FuzzNamesProperty.roc", suite: "FuzzSyntax.roc" },
		{ name: "form-builder", main: "examples/form-builder/fuzz-rules.roc", property: "examples/form-builder/FuzzFormBuilderProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "kanban-board", main: "examples/kanban-board/fuzz-board.roc", property: "examples/kanban-board/FuzzKanbanBoardProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "data-grid", main: "examples/data-grid/fuzz-rows.roc", property: "examples/data-grid/FuzzDataGridProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "markdown-editor", main: "examples/markdown-editor/fuzz-sections.roc", property: "examples/markdown-editor/FuzzMarkdownEditorProperty.roc", suite: "FuzzExampleText.roc" },
		{ name: "markdown-html", main: "examples/markdown-editor/fuzz-html.roc", property: "examples/markdown-editor/FuzzMarkdownHtmlProperty.roc", suite: "FuzzExampleText.roc" },
		{ name: "conduit", main: "examples/conduit/fuzz-routes.roc", property: "examples/conduit/FuzzConduitProperty.roc", suite: "FuzzExampleText.roc" },
		{ name: "field-notes", main: "examples/field-notes/fuzz-outbox.roc", property: "examples/field-notes/FuzzFieldNotesProperty.roc", suite: "FuzzExampleText.roc" },
		{ name: "spreadsheet-lite", main: "examples/spreadsheet-lite/fuzz-formulas.roc", property: "examples/spreadsheet-lite/FuzzSpreadsheetLiteProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "fx-channel", main: "tests/apps/effects/fuzz-channel.roc", property: "tests/apps/effects/FuzzFxChannelProperty.roc", suite: "FuzzLifecycle.roc" },
		{ name: "controls", main: "tests/apps/controls/fuzz-controls.roc", property: "tests/apps/controls/FuzzControlsProperty.roc", suite: "FuzzLifecycle.roc" },
		{ name: "csv-converter", main: "examples/csv-converter/fuzz-csv.roc", property: "examples/csv-converter/FuzzCsvConverterProperty.roc", suite: "FuzzExampleText.roc" },
		{ name: "log-explorer", main: "examples/log-explorer/fuzz-index.roc", property: "examples/log-explorer/FuzzLogExplorerProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "log-scroll-map", main: "examples/log-explorer/fuzz-scroll-map.roc", property: "examples/log-explorer/FuzzLogScrollMapProperty.roc", suite: "FuzzExampleData.roc" },
		{ name: "table-changes", main: "fuzz/table-changes/main.roc", property: "fuzz/table-changes/FuzzTableChangesProperty.roc", suite: "FuzzCores.roc" },
		{ name: "view-follow", main: "fuzz/view-follow/main.roc", property: "fuzz/view-follow/FuzzViewFollowProperty.roc", suite: "FuzzCores.roc" },
		{ name: "fx-core", main: "fuzz/fx-core/main.roc", property: "fuzz/fx-core/FuzzFxCoreProperty.roc", suite: "FuzzCores.roc" },
		{ name: "reconcile", main: "fuzz/reconcile/main.roc", property: "fuzz/reconcile/FuzzReconcileProperty.roc", suite: "FuzzCores.roc" },
		{ name: "million-row-explorer-aggregates", main: "examples/million-row-explorer/fuzz-aggregates.roc", property: "examples/million-row-explorer/FuzzMillionRowExplorerAggregatesProperty.roc", suite: "FuzzExampleData.roc" },
	]

	## One compiler job for each selected suite, in first-member order. Members
	## keep their own inventory, reports and accounting; only the build is shared.
	suite_builds : List(Fuzz) -> List(Fuzz)
	suite_builds = |members| members.fold(
		[],
		|known, member|
			if known.any(|suite| suite.main == member.suite) {
				known
			} else {
				known.append({ name: member.suite.drop_suffix(".roc"), main: member.suite, property: member.suite, suite: member.suite })
			},
	)

	## An executable must expose exactly its registered members, even when a
	## command selects just one. A missing or extra member is a broken suite.
	suite_inventory_problems : List(Str), I32, Str -> List(Str)
	suite_inventory_problems = |expected, code, output| {
		actual = output.trim().split_on("\n").drop_if(Str.is_empty)
		if code != 0 or actual.sort_with(SpecSuite.compare_str) != expected.sort_with(SpecSuite.compare_str) {
			["fuzz suite inventory mismatch: expected ${Str.inspect(expected)}, got exit ${code.to_str()} ${Str.inspect(actual)}"]
		} else {
			[]
		}
	}

	## Check the published host's inventory after each successful new build.
	## Never reuse an old executable or infer membership from a passed message.
	check_suite_builds! : SpecSuite.Options, List(Fuzz), List({ code : I32, output : Str }), Bool => Try(List({ code : I32, output : Str }), _)
	check_suite_builds! = |o, suites, built, plain| {
		var $results = []
		for (suite, result) in List.map2(suites, built, |suite, result| (suite, result)) {
			executable = if plain {
				Targets.smoke_exe_of(o, suite)
			} else {
				Targets.exe_of(o, suite)
			}
			if result.code != 0 {
				$results = $results.append(result)
			} else if !(Path.exists!(Path.utf8(executable))?) {
				$results = $results.append({ code: 1, output: "${result.output}\nfuzz compiler produced no suite executable" })
			} else {
				inventory = Proc.output!({ program: executable, args: ["--list-targets"], cwd: o.root })?
				expected = Targets.fuzz_targets.keep_if(|member| member.suite == suite.main).map(|member| member.name)
				problems = Targets.suite_inventory_problems(expected, inventory.code, Str.from_utf8_lossy(inventory.stdout))
				$results = $results.append({
					code: if problems.is_empty() {
						0
					} else {
						1
					},
					output: Str.join_with([result.output].concat(problems), "\n"),
				})
			}
		}
		Ok($results)
	}

	## A member's private package manifest, kept beside its source and models.
	package_of : Fuzz -> Str
	package_of = |member| "${Str.join_with(member.main.split_on("/").drop_last(1), "/")}/fuzz-package.roc"

	## Exact compiler compatibility is shared with the CLI and Node drivers.
	## TODO https://github.com/roc-lang/roc/issues/13197: remove the native-fuzz
	## row once the affected compiler's speed specialisation is fixed.
	fuzz_opt : SpecSuite.Options -> Str
	fuzz_opt = |o| CompilerProfile.effective({ compiler: o.nightly, target: "native-fuzz", requested: "speed" })

	fuzz_profile : SpecSuite.Options -> Str
	fuzz_profile = |o| if Targets.fuzz_opt(o) == "speed" {
		"fixed-examples-plain"
	} else {
		"fixed-examples-plain-${Targets.fuzz_opt(o)}"
	}

	fuzz_notice! : SpecSuite.Options => {}
	fuzz_notice! = |o| {
		notice = CompilerProfile.notice({ compiler: o.nightly, target: "native-fuzz", requested: "speed" })
		if !notice.is_empty() {
			Proc.note!(notice)
		}
	}

	## The directories a fuzz target may live in.
	target_dirs : List(Str)
	target_dirs = ["fuzz", "examples", "tests"]

	## Whether a Roc file is a fuzz target, from its path and its text: a
	## `main.roc` one directory below `fuzz/`, a file named `fuzz-<subject>.roc`,
	## or any app whose header names a roc-fuzz release as its platform.
	is_target : Str, Str -> Bool
	is_target = |path, text| {
		first = text.split_on("\n").find_first(|line| !line.trim().is_empty() and !line.trim().starts_with("#")) ?? ""
		if path.ends_with("/fuzz-package.roc") and first.starts_with("package ") {
			return False
		}
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

	## Run the top-level `expect`s of every registered fuzz target with
	## `roc test`: a target's own pure tests (its model, its saved seeds
	## against independent bytes) are no replay's business, since a build
	## and replay of the target runs its examples, not its `expect`s. Each
	## suite root imports every selected member's unchanged tests, including
	## model and saved-byte tests. Shared imports are tested once per suite.
	fuzz_expects! : SpecSuite.Options => Try(List(Str), _)
	fuzz_expects! = |o| {
		suites = Targets.suite_builds(Targets.fuzz_targets)
		results = Proc.parallel!(suites.map(|suite| { program: o.compiler, args: ["test", suite.main], cwd: o.root }), Proc.compiler_jobs!(FuzzTarget)?)?
		Ok(
			List.map2(
				suites,
				results,
				|suite, result| if result.code == 0 {
					[]
				} else {
					["roc test ${suite.main} failed: ${result.output.trim()}"]
				},
			).join(),
		)
	}

	## Where a target's executable is built.
	exe_of : SpecSuite.Options, Fuzz -> Str
	exe_of = |o, member| "${o.build_dir}/fuzz-suites/${member.suite.drop_suffix(".roc")}/target"

	## Build each selected suite once with coverage instrumentation. Optimized
	## profiles use LLVM; the exact-version compatibility policy can select size
	## instead of speed. A failed suite build fails every selected member in it,
	## and independent suites are still built.
	build_fuzz_all! : SpecSuite.Options, List(Fuzz) => Try(List({ name : Str, problems : List(Str) }), _)
	build_fuzz_all! = |o, fuzzes| {
		Targets.fuzz_notice!(o)
		suites = Targets.suite_builds(fuzzes)
		for member in fuzzes {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz/${member.name}")?
		}
		var $jobs = []
		for suite in suites {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz-suites/${suite.name}")?
			$jobs = $jobs.append({ program: o.compiler, args: ["build", "--fuzz", "--opt=${Targets.fuzz_opt(o)}", "--timings", suite.main, "--output=${Targets.exe_of(o, suite)}"], cwd: o.root })
		}
		raw_results = Proc.parallel!($jobs, Proc.compiler_jobs!(FuzzTarget)?)?
		results = Targets.check_suite_builds!(o, suites, raw_results, False)?
		Ok(
			fuzzes.map(
				|member| {
					index = suites.find_first_index(|suite| suite.main == member.suite) ?? crash "fuzz suite missing compiler job"
					result = results.get(index) ?? crash "fuzz suite missing compiler result"
					{
						name: member.name,
						problems: if result.code == 0 {
							[]
						} else {
							["fuzz ${member.name}: suite ${member.suite} build exited ${result.code.to_str()}: ${result.output.trim()}"]
						},
					}
				},
			),
		)
	}

	check_job : SpecSuite.Options, Fuzz -> Proc.Job
	check_job = |o, t| { program: Targets.exe_of(o, t), args: ["--target=${t.name}", "check", "--timeout=1800"], cwd: "${o.build_dir}/fuzz/${t.name}" }

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
	smoke_exe_of = |o, member| "${o.build_dir}/fuzz-smoke-suites/${member.suite.drop_suffix(".roc")}/target"

	## A plain optimized build of the actual suite app. This job is separate
	## from covered build_fuzz_all!; it never supplies a campaign.
	smoke_build_job : SpecSuite.Options, Fuzz -> Proc.Job
	smoke_build_job = |o, t| { program: o.compiler, args: ["build", "--opt=${Targets.fuzz_opt(o)}", "--timings", t.suite, "--output=${Targets.smoke_exe_of(o, t)}"], cwd: o.root }

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
		Targets.fuzz_notice!(o)
		suites = Targets.suite_builds(fuzzes)
		for suite in suites {
			SpecSuite.fresh_dir!("${o.build_dir}/fuzz-smoke-suites/${suite.name}")?
		}
		build_start = Monotonic.now!()
		raw_suites = Proc.parallel!(suites.map(|suite| Targets.smoke_build_job(o, suite)), Proc.compiler_jobs!(FuzzTarget)?)?
		built_suites = Targets.check_suite_builds!(o, suites, raw_suites, True)?
		built = fuzzes.map(
			|member| {
				index = suites.find_first_index(|suite| suite.main == member.suite) ?? crash "fuzz smoke suite missing compiler job"
				built_suites.get(index) ?? crash "fuzz smoke suite missing compiler result"
			},
		)
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
			$ready.map(|target| { program: Targets.smoke_exe_of(o, target), args: ["--target=${target.name}", "check", "--timeout=1800", "--profile=${Targets.fuzz_profile(o)}", "--report-dir=${o.build_dir}/fuzz-smoke/${target.name}/report"], cwd: "${o.build_dir}/fuzz-smoke/${target.name}" }),
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
					"--member-entry",
					outcome.target.property,
					"--profile",
					Targets.fuzz_profile(o),
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
	## time-zone probes in UTC and Sydney, the documented port handlers
	## with bounded queues and browser-resource cleanup, and the ingress
	## queue's rules over seeded sessions, without a browser.
	## A Wasm fixture, tests/apps/write-scaling, also guards sparse-write
	## allocation scaling on its development build (the one its specs use)
	## and on a shipping build (`--opt=size`), and its declared protocol
	## facts must be exactly the test-owned fixture.
	runtime_unit! : SpecSuite.Options => Try(List(Str), _)
	runtime_unit! = |o| {
		var $failures = []
		Proc.run!({ program: o.tooling, args: ["scripts/test_parallel.roc"], cwd: o.root })?
		Proc.run!({ program: o.tooling, args: ["scripts/test_protocol.roc"], cwd: o.root })?
		Proc.run!({ program: o.tooling, args: ["scripts/test_worker_entries.roc"], cwd: o.root })?
		for script in ["monitor-unit.mjs", "environment-unit.mjs", "port-recipes-unit.mjs", "protocol-facts.mjs", "boot-fault-unit.mjs", "forget-fault-unit.mjs", "work-request-unit.mjs", "crypto-unit.mjs", "storage-text-unit.mjs", "port-answer-unit.mjs", "ingress-unit.mjs", "conduit-urls.mjs", "dbg.test.mjs", "replay-errors.test.mjs", "compiler-profile.test.mjs"] {
			code = Proc.status!({ program: o.node, args: ["tests/runtime/${script}"], cwd: o.root })?
			if code != 0 {
				$failures = $failures.append("${script} failed (exit ${code.to_str()})")
			}
		}
		report_units = Proc.status!({ program: o.node, args: ["tests/fuzz/check-report-unit.mjs"], cwd: o.root })?
		if report_units != 0 {
			$failures = $failures.append("fixed-report transport contracts failed (exit ${report_units.to_str()})")
		}
		Path.create_all!(Path.utf8(o.build_dir))?
		# Both builds come from the caller's batch (`CheckPlan.needs`): the
		# development build the app's specs use, and its shipping build.
		dev = SpecSuite.wasm_of(o, "write-scaling")
		# A substituted size artifact must satisfy size's allocation contract,
		# never development's stronger keyed-write expectation (#12957).
		for build in SpecSuite.allocation_builds(o, "write-scaling") {
			code = Proc.status!({ program: o.node, args: ["tests/runtime/write-scaling.mjs", build.wasm, build.opt], cwd: o.root })?
			if code != 0 {
				$failures = $failures.append("write-scaling.mjs ${build.opt} failed (exit ${code.to_str()})")
			}
		}
		facts = Proc.status!({ program: o.node, args: ["tests/runtime/protocol-production.mjs", dev], cwd: o.root })?
		if facts != 0 {
			$failures = $failures.append("protocol-production.mjs failed (exit ${facts.to_str()})")
		}
		Ok($failures)
	}

	## Run file specs in deliberate process-local orders so a page's teardown
	## and worker answers cannot consume the next page's handle capacity.
	native_contracts! : SpecSuite.Options => Try(List(Str), _)
	native_contracts! = |o| {
		code = Proc.status!({ program: o.node, args: ["tests/native/file-lifetimes.mjs", "--runner", SpecSuite.runner_of(o, "files")], cwd: o.root })?
		debug_code = Proc.status!({ program: o.node, args: ["tests/native/dbg-output.mjs", "--runner", SpecSuite.runner_of(o, "dbg")], cwd: o.root })?
		suite_code = Proc.status!({ program: o.node, args: ["tests/native/suite-evidence.mjs", "--runner", SpecSuite.runner_of(o, "dbg")], cwd: o.root })?
		Ok((if (code == 0) [] else ["native file lifetime contracts failed (exit ${code.to_str()})"]).concat(if (debug_code == 0) [] else ["native dbg output contracts failed (exit ${debug_code.to_str()})"]).concat(if (suite_code == 0) [] else ["native suite evidence contracts failed (exit ${suite_code.to_str()})"]))
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
		build = SpecSuite.build_job(o, "dev", main, o.target, runner)
		Proc.run!({ ..build, args: build.args.append("--timings") })?
		Targets.browser!(o, "prerender-stage1-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "prerender"), "--runner", SpecSuite.runner_of(o, "prerender"), "--no-init-runner", runner, "--template", "tests/apps/prerender/index.html"])
	}

	## The script root that exports the native keyboard oracle's bits. It
	## imports the platform package, so `roc`, the package compiler, builds it
	## like an app, and like an app it names no compiler: a `roc` header field
	## that differs from the running compiler is a warning, which fails the
	## build that `browser_contracts!` runs.
	unicode_symbols_root : Str
	unicode_symbols_root = "scripts/unicode_symbols.roc"

	## Run allocation/lifetime controls once per effective artifact, identifying
	## its actual profile rather than replaying one size artifact as dev too.
	profile_contract! : SpecSuite.Options, { example : Str, script : Str } => Try(List(Str), _)
	profile_contract! = |o, { example, script }| {
		var $problems = []
		for build in SpecSuite.allocation_builds(o, example) {
			Proc.note!("== ${script}: --opt=${build.opt}")
			$problems = $problems.concat(Targets.browser!(o, script, ["--wasm", build.wasm])?)
		}
		Ok($problems)
	}

	## The runtime contract tests in Chrome, on test apps built by
	## `SpecSuite.build!`: the protocol facts, names, namespaces and Unicode
	## classes against the native oracle; the effect channel
	## (tests/apps/effects), controlled inputs, focus and containment
	## (tests/apps/controls), an outbox posted twice in one turn
	## (tests/apps/outbox), worker jobs in real Web Workers and the work
	## monitor (tests/apps/workers), file handles (tests/apps/files),
	## operations on files (tests/apps/file-effects), preparations and the
	## pool's placement (tests/apps/prepared), ports with real handlers
	## (tests/apps/ports), worker tasks, their handles and the page's stubs
	## (tests/apps/tasks), and worker payloads at their nesting bound. The
	## examples' journeys are `example_journeys!`.
	browser_contracts! : SpecSuite.Options => Try(List(Str), _)
	browser_contracts! = |o| {
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
		Proc.run!({ program: o.compiler, args: ["build", "--opt=dev", Targets.unicode_symbols_root, "--output=${unicode_runner}"], cwd: o.root })?
		bits = Proc.capture!({ program: unicode_runner, args: [], cwd: o.root })?
		Path.write_bytes!(Path.utf8(unicode_bits), bits)?
		Ok(
			Targets.browser!(o, "page-profile.test.mjs", [])?
				.concat(Targets.browser!(o, "public-assets.test.mjs", [])?)
				.concat(Targets.browser!(o, "protocol-facts-browser.mjs", [])?)
				.concat(Targets.browser!(o, "picture-browser.mjs", [])?)
				.concat(Targets.browser!(o, "startup-annotations-browser.mjs", [])?)
				.concat(Targets.browser!(o, "startup-corpus-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "startup-corpus"), "--runner", SpecSuite.runner_of(o, "startup-corpus"), "--template", "tests/apps/startup-corpus/index.html"])?)
				.concat(Targets.browser!(o, "picture-parent-browser.mjs", [])?)
				.concat(Targets.prerender_contract!(o)?)
				.concat(Targets.browser!(o, "names-browser.mjs", [])?)
				.concat(Targets.browser!(o, "namespaces-browser.mjs", [])?)
				.concat(Targets.browser!(o, "unicode-symbols-browser.mjs", ["--oracle", unicode_bits])?)
				.concat(Targets.browser!(o, "fx-browser.mjs", ["--wasm", fx])?)
				.concat(Targets.browser!(o, "controls-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "effective-types-refusals.mjs", ["--wasm", controls, "--native", SpecSuite.runner_of(o, "controls")])?)
				.concat(Targets.browser!(o, "unsafe-html-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "unsafe-html"), "--runner", SpecSuite.runner_of(o, "unsafe-html")])?)
				.concat(Targets.browser!(o, "markup-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "markup")])?)
				.concat(Targets.profile_contract!(o, { example: "startup-queue", script: "placeholder-queue-cost.mjs" })?)
				.concat(Targets.profile_contract!(o, { example: "placeholder-retention", script: "placeholder-retention.mjs" })?)
				.concat(Targets.browser!(o, "description-preparation.mjs", ["--wasm", SpecSuite.wasm_of(o, "description-preparation")])?)
				.concat(Targets.browser!(o, "construction-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "construction")])?)
				.concat(Targets.browser!(o, "pointer-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "keys-browser.mjs", ["--wasm", controls])?)
				.concat(Targets.browser!(o, "dialogs-browser.mjs", ["--wasm", controls, "--runner", SpecSuite.runner_of(o, "controls")])?)
				.concat(Targets.browser!(o, "layout-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "table"), "--runner", SpecSuite.runner_of(o, "table")])?)
				.concat(Targets.browser!(o, "outbox-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "outbox")])?)
				.concat(Targets.browser!(o, "services-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "environment-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "persistence-browser.mjs", ["--wasm", services, "--runner", SpecSuite.runner_of(o, "services")])?)
				.concat(Targets.browser!(o, "transitions-browser.mjs", ["--wasm", services])?)
				.concat(Targets.browser!(o, "workers-browser.mjs", ["--wasm", workers])?)
				.concat(Targets.browser!(o, "dbg-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "dbg"), "--job-only-wasm", SpecSuite.wasm_of(o, "dbg-job-only")])?)
				.concat(Targets.browser!(o, "monitor-browser.mjs", ["--wasm", workers])?)
				.concat(Targets.browser!(o, "files-browser.mjs", ["--wasm", files])?)
				.concat(Targets.browser!(o, "table-file-lifetime-browser.mjs", ["--wasm", files])?)
				.concat(Targets.browser!(o, "file-effects-browser.mjs", ["--wasm", file_effects])?)
				.concat(Targets.browser!(o, "http-progress-browser.mjs", ["--wasm", file_effects])?)
				.concat(Targets.browser!(o, "file-transfer-memory-browser.mjs", [])?)
				.concat(Targets.browser!(o, "crypto-browser.mjs", [])?)
				.concat(Targets.browser!(o, "crypto-empty-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "crypto")])?)
				.concat(Targets.browser!(o, "prepared-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "prepared")])?)
				.concat(Targets.browser!(o, "ports-browser.mjs", ["--wasm", ports])?)
				.concat(Targets.browser!(o, "reports-browser.mjs", ["--wasm", ports])?)
				.concat(Targets.browser!(o, "tasks-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "tasks")])?)
				.concat(Targets.browser!(o, "deep-payload-browser.mjs", ["--wasm", SpecSuite.wasm_of(o, "deep-payload")])?),
		)
	}

	## The examples in Chrome, each against its own JavaScript, on the
	## builds `SpecSuite.build!` made: the worker scaling smoke on the Worker
	## Lab (correctness, robustness sequences and memory; no timing ratios),
	## the Reading List's own port handlers against real IndexedDB in two
	## tabs, the Status Page's stream, the Log Explorer over a 64 MiB log, the
	## Million-Row Explorer at two million orders with its own feed, and
	## Conduit's user journey against the RealWorld mock backend.
	example_journeys! : SpecSuite.Options => Try(List(Str), _)
	example_journeys! = |o|
		Ok(
			Targets.browser!(o, "workers-scaling.mjs", ["--wasm", SpecSuite.wasm_of(o, "worker-lab"), "--mode", "smoke"])?
				.concat(Targets.browser!(o, "reading-list-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "reading-list")])?)
				.concat(Targets.browser!(o, "status-page-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "status-page")])?)
				.concat(Targets.browser!(o, "log-explorer-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "log-explorer")])?)
				.concat(Targets.browser!(o, "million-row-explorer-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "million-row-explorer")])?)
				.concat(Targets.browser!(o, "conduit-journey.mjs", ["--wasm", SpecSuite.wasm_of(o, "conduit")])?),
		)

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

	## Build the js-framework-benchmark app into its `dist/` and run the
	## keyed-operation checks. `Measured` builds it `--opt=speed`, as the
	## benchmark measures it, for the `jfb` task whose `dist/` is what gets
	## timed. `Checked` builds it `--opt=dev` for `check`, which only asks
	## whether the keyed operations are right: that answer is the same in
	## either build, and the optimized build costs minutes.
	jfb! : SpecSuite.Options, [Measured, Checked] => Try(List(Str), _)
	jfb! = |o, build| {
		dist = "${o.root}/${Targets.jfb_dir}/dist"
		Path.create_all!(Path.utf8(dist))?
		opt = match build {
			Measured => "speed"
			Checked => "dev"
		}
		SpecSuite.note_profile!(o, opt)
		Proc.run!(SpecSuite.build_job(o, opt, "${Targets.jfb_dir}/app/main.roc", "wasm32", "${dist}/app.wasm"))?
		SpecSuite.copy_runtime!(o.root, dist)?
		Path.copy!(Path.utf8("${o.root}/${Targets.jfb_dir}/src/main.mjs"), Path.utf8("${dist}/main.mjs"))?
		code = Proc.status!({ program: o.node, args: ["tests/browser/jfb-check.mjs", "--dist", dist, "--chrome", o.chrome], cwd: o.root })?
		Ok(if (code == 0) [] else ["jfb-check failed (exit ${code.to_str()})"])
	}
}

## A target in the tree that is not listed is named, and so is a listed one
## that is gone.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "fuzz/a/main.roc" }, { name: "b", main: "examples/b/fuzz-b.roc", property: "examples/b/fuzz-b.roc", suite: "examples/b/fuzz-b.roc" }], [], ["examples/b/fuzz-b.roc", "tests/apps/c/fuzz-c.roc"]) == ["tests/apps/c/fuzz-c.roc is a fuzz target that neither Targets.fuzz_targets lists nor Targets.fuzz_skipped skips with a reason, so no task builds or replays it", "the Targets registry names fuzz/a/main.roc, which is not a fuzz target in the tree"]

## Equal lists in any order agree, and a skip with a reason accounts for its
## target.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "fuzz/a/main.roc" }], [{ main: "examples/b/fuzz-b.roc", reason: "needs a browser" }], ["examples/b/fuzz-b.roc", "fuzz/a/main.roc"]) == []

## A skip without a reason, a file both listed and skipped, and a name or file
## named twice are each reported once.
expect Targets.registry_problems([{ name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "fuzz/a/main.roc" }, { name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "fuzz/a/main.roc" }], [{ main: "fuzz/a/main.roc", reason: " " }], ["fuzz/a/main.roc"]) == ["fuzz/a/main.roc is both listed in Targets.fuzz_targets and skipped in Targets.fuzz_skipped", "Targets.fuzz_skipped skips fuzz/a/main.roc without a reason", "the Targets registry names the name a more than once", "the Targets registry names the file fuzz/a/main.roc more than once"]

## A skipped target is printed with its reason.
expect Targets.skip_line({ main: "fuzz/a/main.roc", reason: "needs a browser" }) == "SKIP fuzz target fuzz/a/main.roc: needs a browser"

## A target is known by its place, its name or its platform; a module beside
## it, and a main deeper under `fuzz/`, are not targets by place alone.
expect [
	Targets.is_target("fuzz/z/main.roc", ""),
	Targets.is_target("examples/x/fuzz-y.roc", ""),
	Targets.is_target("tests/apps/x/fuzz-y.roc", ""),
	Targets.is_target("examples/x/Rules.roc", "app [target] {\n\tfz: platform \"https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/h.tar.zst\",\n}\n"),
	Targets.is_target("fuzz/wire/Saved.roc", "module [saved]\n"),
	Targets.is_target("fuzz/z/lib/main.roc", ""),
	Targets.is_target("examples/x/main.roc", "app [main] { pf: platform \"../../platform/main.roc\" }\n"),
] == [True, True, True, True, False, False, False]

## A suite's complete inventory is exact, independent of presentation order.
expect Targets.suite_inventory_problems(["a", "b"], 0, "b\na\n") == []
expect !Targets.suite_inventory_problems(["a", "b"], 0, "a\n").is_empty()
expect !Targets.suite_inventory_problems(["a"], 0, "a\na\n").is_empty()
expect !Targets.suite_inventory_problems(["a"], 0, "a\nb\n").is_empty()
expect !Targets.suite_inventory_problems(["a"], 1, "a\n").is_empty()

## Build grouping never coalesces member reports or drops a selected member.
expect {
	members = [
		{ name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "One.roc" },
		{ name: "b", main: "fuzz/b/main.roc", property: "fuzz/b/main.roc", suite: "Two.roc" },
		{ name: "c", main: "fuzz/c/main.roc", property: "fuzz/c/main.roc", suite: "One.roc" },
	]
	Targets.suite_builds(members).map(|suite| suite.main) == ["One.roc", "Two.roc"]
}

## Only real package manifests bypass app discovery, never an app with that name.
expect !Targets.is_target("fuzz/dom/fuzz-package.roc", "## Private members\npackage [Property] { fz: platform \"release\" }\n")
expect Targets.is_target("fuzz/dom/fuzz-package.roc", "app [target] {}\n")
