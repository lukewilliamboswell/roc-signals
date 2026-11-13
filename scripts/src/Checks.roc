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
		version = Str.from_utf8_lossy(Proc.capture!({ program: "roc", args: ["version"], cwd: root })?).trim()
		nightly = version.split_on(" ").last() ?? version
		Ok({ root, build_dir, compiler: "roc", nightly, tooling: "roc-stable", zig: "zig", node: "node", chrome: "google-chrome", filter })
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
		results = Proc.parallel!(dirs.map(|dir| { program: o.compiler, args: ["test", "${dir}/main.roc"], cwd: o.root }), Proc.compiler_jobs!()?)?
		negatives = Checks.key_type_errors!(o)?
		Ok(List.map2(dirs, results, |dir, r| if (r.code == 0) [] else ["roc test ${dir}/main.roc failed: ${r.output.trim()}"]).join().concat(negatives))
	}

	## Declaration and default-mount contracts are checked as complete apps.
	## A constant failure must name its expected app declaration and every
	## rule; a must-compile case guards code the default mount does not reach.
	## Compiler process crashes and warning exits never count as rejections.
	key_type_errors! : SpecSuite.Options => Try(List(Str), _)
	key_type_errors! = |o| {
		cases : List({ name : Str, expectation : [Rejected(List(Str)), ConstantCrash({ at : Str, rules : List(Str) }), ConstantExpect({ at : Str, rules : List(Str) }), Compiles] })
		cases = [
			{ name: "web-tag-empty", expectation: Rejected(["name must not be empty"]) },
			{ name: "web-tag-start", expectation: Rejected(["starts with a letter"]) },
			{ name: "web-tag-space", expectation: Rejected(["ASCII whitespace"]) },
			{ name: "web-attribute-space", expectation: Rejected(["not a valid attribute local name"]) },
			{ name: "web-attribute-empty", expectation: Rejected(["not a valid attribute local name"]) },
			{ name: "web-attribute-class", expectation: Rejected(["Engine.class"]) },
			{ name: "web-attribute-testid", expectation: Rejected(["Engine.test_id"]) },
			{ name: "web-event-prevent", expectation: Rejected(["on_with"]) },
			{ name: "web-event-files", expectation: Rejected(["on_files"]) },
			{ name: "web-event-key", expectation: Rejected(["on_key"]) },
			{ name: "web-event-empty", expectation: Rejected(["nonempty event type"]) },
			{ name: "web-method-patch", expectation: Rejected(["write", "PATCH"]) },
			{ name: "web-method-forbidden", expectation: Rejected(["browser refuses"]) },
			{ name: "web-method-empty", expectation: Rejected(["one or more token characters"]) },
			{ name: "web-method-space", expectation: Rejected(["one or more token characters"]) },
			{ name: "web-text-tag", expectation: Rejected(["Engine.Tag", "Str"]) },
			{ name: "web-interpolation", expectation: Rejected(["Web.AttrName"]) },
			{ name: "web-shared-constant", expectation: Rejected(["Web.AttrName", "Str"]) },
			{ name: "web-method-request", expectation: Rejected(["Engine.Method", "Str"]) },
			{ name: "web-method-upload", expectation: Rejected(["Core.UploadProps", "Str"]) },
			{ name: "web-method-sent", expectation: Rejected(["Web.Method", "Str"]) },
			{ name: "web-public-family", expectation: Compiles },
			{ name: "missing-keymap", expectation: Rejected(["Engine.KeyProps"]) },
			{ name: "key-prevent", expectation: Rejected(["Engine.KeyProps"]) },
			{ name: "document-row", expectation: Rejected(["outside_rows"]) },
			{ name: "document-state-in-row", expectation: Rejected(["outside_rows"]) },
			{ name: "dialog-open-text", expectation: Rejected(["Bool"]) },
			{ name: "dialog-close-text", expectation: Rejected(["Bool"]) },
			{ name: "popover-toggle-text", expectation: Rejected(["Bool"]) },
			{ name: "table-bookkeeping", expectation: Rejected(["with_id"]) },
			{ name: "internal-module", expectation: Rejected(["does not name a public module"]) },
			{ name: "ask-reaction-type", expectation: Rejected(["type mismatch"]) },
			{ name: "ask-mixed-plan", expectation: Rejected(["incompatible types"]) },
			{ name: "ask-await-command", expectation: Rejected(["Engine.Command"]) },
			{ name: "ask-private-constructor", expectation: Rejected(["it is an alias"]) },
			{ name: "ask-private-reader", expectation: Rejected(["associated item named read"]) },
			{ name: "layout-scroll-text", expectation: Rejected(["top: U32"]) },
			{ name: "layout-size-text", expectation: Rejected(["width: U32"]) },
			{ name: "layout-seen-text", expectation: Rejected(["ratio_permille: U16"]) },
			{ name: "timeout-zero", expectation: Rejected(["a timeout of Ms(0)"]) },
			{ name: "checkbox-text-payload", expectation: Rejected(["This string literal is being used where a non-string type is needed", "Bool"]) },
			{ name: "select-text-payload", expectation: Rejected(["The sixth argument", "[Chose(Str), NotOffered]"]) },
			{ name: "sort-tuple", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-tag", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-record", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-key", expectation: Rejected(["order_relative_to"]) },
			{ name: "signal-text-str-part", expectation: Rejected(["to_text_signal"]) },
			{ name: "signal-text-mixed-parts", expectation: Rejected(["type mismatch", "Engine.Signal"]) },
			{ name: "signal-text-record-part", expectation: Rejected(["to_str"]) },
			{ name: "signal-text-shared-literal", expectation: Rejected(["type mismatch", "Engine.Signal"]) },
			{ name: "signal-text-positive", expectation: Compiles },
			{ name: "worker-module-duplicate", expectation: ConstantCrash({ at: "main = Engine.program(|| Engine.text(\"\")).with_workers([job.registration()]).with_workers([job.registration()])", rules: ["worker task \"test/duplicate-worker\" is registered twice"] }) },
			{ name: "port-record-duplicate", expectation: ConstantCrash({ at: "registrations = Port.registrations(ports)", rules: ["port \"test/duplicate\" is declared twice"] }) },
			{ name: "port-module-duplicate", expectation: ConstantCrash({ at: "main = program", rules: ["port \"test/across-modules\" is declared twice"] }) },
			{ name: "port-record-data", expectation: ConstantCrash({ at: "registrations = Port.registrations(ports)", rules: ["Port.registrations: field \"actions.label\" is not a port"] }) },
			{ name: "mount-table-order-same", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two rows of a table view compare Same", "site /0"] }) },
			{ name: "mount-table-key", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two rows have the same key"] }) },
			{ name: "mount-two-handlers", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two handlers", "site /0", "Save"] }) },
			{ name: "mount-empty-row-handlers", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two handlers", "row template", "site /0"] }) },
			{ name: "mount-row-shape", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["row template must be a single element", "site /0"] }) },
			{ name: "mount-table-row-shape", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["a table view row template must be a single element", "site /0"] }) },
			{ name: "mount-app-crash", expectation: ConstantCrash({ at: "main = Engine.program(|| crash \"first page failed\")", rules: ["first page failed"] }) },
			{ name: "mount-inline-expect", expectation: ConstantExpect({ at: "expect boot.url != \"/\"", rules: ["expect failed"] }) },
			{ name: "mount-unreached-nested-row", expectation: Compiles },
		]
		dir = "${o.build_dir}/key-type-errors"
		SpecSuite.fresh_dir!(dir)?
		var $problems = []
		for test in cases {
			fixture = Path.read_utf8!(Path.utf8("${o.root}/tests/type-errors/${test.name}.roc.txt"))?
			case_dir = "${dir}/${test.name}"
			Path.create_all!(Path.utf8(case_dir))?
			up = Str.join_with(List.repeat("..", case_dir.split_on("/").keep_if(|part| !part.is_empty()).len()), "/")
			platform_path = "${up}/${o.root.drop_prefix("/")}/platform/main.roc"
			source = fixture.replace_each("<PLATFORM>", platform_path)
			path = "${case_dir}/main.roc"
			Path.write_utf8!(Path.utf8(path), source)?
			{ code, stdout } = Proc.merged!({ program: o.compiler, args: ["check", "--no-cache", path], cwd: o.root })?
			output = Str.from_utf8_lossy(stdout)
			diagnostic = Str.join_with(output.split_on("\n").map(|line| line.trim()), " ")
			passed = match test.expectation {
				Rejected(rules) => code == 1 and rules.all(|rule| diagnostic.contains(rule))
				ConstantCrash(expected) | ConstantExpect(expected) => {
					anchors = source.split_on("\n").map_with_index(|line, index| { text: line.trim(), number: index + 1 }).keep_if(|line| line.text == expected.at)
					anchor = match anchors {
						[line] => line.number
						_ => crash "internal: a compile-time crash fixture must name one exact declaration line"
					}
					category = match test.expectation {
						ConstantExpect(_) => "compile time expect failed"
						_ => "compile time crash"
					}
					code == 1 and output.contains(category) and output.contains("main.roc:${anchor.to_str()}:") and expected.rules.all(|rule| diagnostic.contains(rule))
				}
				Compiles => code == 0
			}
			if !passed {
				$problems = $problems.append("declaration contract ${test.name}: expected ${Str.inspect(test.expectation)}, exit ${code.to_str()}: ${output}")
			}
		}
		Ok($problems)
	}

	## Isolated apps check declaration and request contracts in both hosts:
	## deliberate mistakes name the rule; ordinary raw attributes still mount.
	key_contracts! : SpecSuite.Options => Try(List(Str), _)
	key_contracts! = |o| {
		cases = [
			{ name: "oracle-flags", rejection: "unknown command batch flags", prefix: "executor:", code: 70 },
			{ name: "oracle-missing-transition", rejection: "marked batch is missing TRANSITION", prefix: "executor:", code: 70 },
			{ name: "oracle-unmarked-transition", rejection: "TRANSITION requires marked batch", prefix: "executor:", code: 70 },
			{ name: "oracle-transition-trailing", rejection: "TRANSITION must be last", prefix: "executor:", code: 70 },
			{ name: "oracle-transition-truncated", rejection: "short command", prefix: "executor:", code: 70 },
			{ name: "oracle-leading-zero", rejection: "leading zero", prefix: "executor:", code: 70 },
			{ name: "oracle-apply-file", rejection: "value property on file input", prefix: "contract:", code: 70 },
			{ name: "text-key", rejection: "on_key", prefix: "contract:", code: 70 },
			{ name: "document-bound", rejection: "32", prefix: "contract:", code: 70 },
			{ name: "apply-noncontrol", rejection: "ApplyValue", prefix: "contract:", code: 70 },
			{ name: "apply-without-value", rejection: "ApplyValue", prefix: "contract:", code: 70 },
			{ name: "dialog-open", rejection: "owned by the controlled dialog", prefix: "contract:", code: 70 },
			{ name: "dialog-dynamic-open", rejection: "owned by the controlled dialog", prefix: "contract:", code: 70 },
			{ name: "dialog-popover", rejection: "popover and closedby", prefix: "contract:", code: 70 },
			{ name: "dialog-dynamic-popover", rejection: "popover and closedby", prefix: "contract:", code: 70 },
			{ name: "dialog-closedby", rejection: "popover and closedby", prefix: "contract:", code: 70 },
			{ name: "dialog-dynamic-closedby", rejection: "popover and closedby", prefix: "contract:", code: 70 },
			{ name: "controlled-beforetoggle", rejection: "beforetoggle", prefix: "contract:", code: 70 },
			{ name: "popover-beforetoggle", rejection: "beforetoggle", prefix: "contract:", code: 70 },
			{ name: "popover-duplicate", rejection: "one static popover", prefix: "contract:", code: 70 },
			{ name: "popover-dynamic-popover", rejection: "one static popover", prefix: "contract:", code: 70 },
			{ name: "media-undeclared", rejection: "missing-media", prefix: "contract:", code: 70 },
			{ name: "table-order-same", rejection: "two rows of a table view compare Same", prefix: "contract:", code: 70 },
			{ name: "signal-text-manual-arity", rejection: "Signal.from_interpolation", prefix: "contract:", code: 70 },
			{ name: "keep-current-subscription", rejection: "keep_current cannot issue a subscription", prefix: "contract:", code: 70 },
			{ name: "interval-zero", rejection: "Interval(0) has no period", prefix: "contract:", code: 70 },
			{ name: "timer-overflow", rejection: "Timer(3000000000) is longer", prefix: "contract:", code: 70 },
			{ name: "interval-overflow", rejection: "Interval(2147483648) is longer", prefix: "contract:", code: 70 },
			{ name: "timer-overflow-boundary", rejection: "Timer(2147483648) is longer", prefix: "contract:", code: 70 },
			{ name: "timeout-zero", rejection: "a timeout of Ms(0)", prefix: "contract:", code: 70 },
			{ name: "raw-controlled-attributes", rejection: "", prefix: "", code: 0 },
		]
		dir = "${o.build_dir}/key-contracts"
		SpecSuite.fresh_dir!(dir)?
		var $problems = []
		for test in cases {
			case_dir = "${dir}/${test.name}"
			Path.create_all!(Path.utf8(case_dir))?
			fixture = Path.read_utf8!(Path.utf8("${o.root}/tests/key-contracts/${test.name}.roc.txt"))?
			up = Str.join_with(List.repeat("..", case_dir.split_on("/").keep_if(|part| !part.is_empty()).len()), "/")
			source = fixture.replace_each("<PLATFORM>", "${up}/${o.root.drop_prefix("/")}/platform/main.roc").replace_each("<ORACLE>", "${up}/${o.root.drop_prefix("/")}/platform/main-fuzz.roc")
			main = "${case_dir}/main.roc"
			runner = "${case_dir}/runner"
			wasm = "${case_dir}/app.wasm"
			Path.write_utf8!(Path.utf8(main), source)?
			Proc.run!(SpecSuite.build_job(o, "dev", main, SpecSuite.native_target, runner))?
			Proc.run!(SpecSuite.build_job(o, "dev", main, "wasm32", wasm))?
			spec = "${case_dir}/contract.scm"
			Path.write_utf8!(Path.utf8(spec), "(test \"contract\" (steps (mark-metrics)))")?
			{ code, stdout } = Proc.merged!({ program: runner, args: [spec], cwd: case_dir })?
			message = Str.from_utf8_lossy(stdout)
			if code != test.code or !message.contains(test.prefix) or !message.contains(test.rejection) {
				$problems = $problems.append("native key contract ${test.name}: expected ${test.prefix} ${test.rejection}, got ${code.to_str()}: ${message}")
			}
		}
		{ code, .. } = Proc.output!({ program: o.node, args: ["tests/browser/key-contracts-browser.mjs", "--fixtures", dir, "--runtime", SpecSuite.runtime, "--chrome", o.chrome], cwd: o.root })?
		Ok(if (code == 0) $problems else $problems.append("browser key contracts failed (see above)"))
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
	## has), and a focus feedback loop that both runners must stop with
	## resource_limit rather than hanging the replay. Report-frame mutations
	## also hold both runners to rejecting an invalid hold lifecycle.
	broken_specs : List(Broken)
	broken_specs = [
		{ example: "handlers", spec: "tests/apps/handlers/specs/keyboard.scm", good: "(press \"Escape\")", bad: "(press (label \"Keyboard editable\") \"Enter\")", rejection: "unmodelled" },
		{ example: "handlers", spec: "tests/apps/handlers/specs/keyboard.scm", good: "(press \"Escape\")", bad: "(press (label \"Keyboard editable\") \"j\")", rejection: "unmodelled" },
		{ example: "handlers", spec: "tests/apps/handlers/specs/keyboard.scm", good: "(press (label \"Prevented shortcut link\") \"Control+Enter\")", bad: "(press (label \"Unprevented shortcut link\") \"Shift+Enter\")", rejection: "unmodelled" },
		{ example: "handlers", spec: "tests/apps/handlers/specs/keyboard.scm", good: "(press \"Escape\")", bad: "(press \"a\")", rejection: "unmodelled" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-many-touches.scm", good: "(pointer-up (test-id \"pointer-capture\") :id 2)", bad: "(pointer-down (test-id \"pointer-capture\") :pointer touch :id 18)", rejection: "at most 16" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-capture.scm", good: "(hold-reports)", bad: "(pointer-down (test-id \"pointer-plain\") :pointer touch :id 2)", rejection: "touch" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-capture.scm", good: "(hold-reports)", bad: "(pointer-down (test-id \"pointer-plain\") :pointer pen :id 2)", rejection: "mouse or pen" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-two-touches.scm", good: ":pointer touch", bad: ":pointer pen", rejection: "mouse or pen" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-capture.scm", good: "(pointer-down (test-id \"pointer-capture\"))", bad: "(click (test-id \"pointer-inside\"))", rejection: "give :at" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-two-touches.scm", good: "(hold-reports)", bad: "(pointer-cancel :id 2)", rejection: "pointer-cancel" },
		{ example: "controls", spec: "tests/apps/controls/specs/pointer-capture.scm", good: "(pointer-up (test-id \"pointer-outside\"))", bad: "(navigate \"/leave-pointer-document\")", rejection: "cross-document navigation" },
		{ example: "kanban-board", spec: "examples/kanban-board/specs/initial-render.scm", good: "(expect-text (test-id \"board-total\") \"5\")", bad: "(expect-text (test-id \"board-total\") \"6\")", rejection: "expected \\\"6\\\"" },
		{ example: "workers", spec: "tests/apps/workers/specs/crash.scm", good: "(expect-text (test-id \"log\") \"crash:lost AppCrash\")", bad: "(expect-text (test-id \"log\") \"crash:lost Contract\")", rejection: "expected \\\"crash:lost Contract\\\"" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(click (role button :name \"Start focus loop\"))", rejection: "resource_limit" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(hold-reports)", bad: "(hold-reports) (hold-reports)", rejection: "reports are already held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(hold-reports)", bad: "(release-reports)", rejection: "reports are not held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(expect-reports-replaced 0)", bad: "(hold-reports)", rejection: "spec ended while reports were held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(release-reports)", bad: "(navigate \"/leave-held-document\")", rejection: "cross-document navigation" },
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
