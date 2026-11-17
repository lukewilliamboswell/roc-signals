import cli.Env
import cli.Path
import CompilerSkips
import Proc
import SpecSuite
import PlatformTest

## The steps `check_all.roc` and `spec.roc` share.
Checks := [].{

	## The tools Blueprint.roc puts on PATH, and the package compiler: `roc`, the
	## latest Roc nightly, which the environment expects on PATH and never pins
	## (roc-automation's model). `roc-stable`, pinned in Blueprint.roc, runs and
	## checks the scripts only. Native spec runners are built for `x64musl`,
	## the system CI runs on; `spec.roc` replaces the target with the one it
	## was given or the system's own.
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
		Ok({ root, build_dir, compiler: "roc", nightly, tooling: "roc-stable", zig: "zig", node: "node", chrome: "google-chrome", filter, target: "x64musl" })
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
		results = Proc.parallel!(dirs.map(|dir| { program: o.compiler, args: ["test", "${dir}/main.roc"], cwd: o.root }), Proc.compiler_jobs!(App)?)?
		Ok(List.map2(dirs, results, |dir, r| if (r.code == 0) [] else ["roc test ${dir}/main.roc failed: ${r.output.trim()}"]).join())
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
			{ name: "web-attribute-aria-case-typo", expectation: Rejected(["\"ARIA-LABLE\" is not an ARIA attribute", "did you mean \"aria-label\"?"]) },
			{ name: "web-attribute-class-case", expectation: Rejected(["an HTML element reads \"CLASS\" as \"class\": set `class` with Engine.class or Engine.class_s"]) },
			{ name: "web-attribute-aria-case", expectation: Rejected(["write \"aria-label\": ARIA attribute names are lowercase"]) },
			{ name: "web-event-prevent", expectation: Rejected(["on_with"]) },
			{ name: "web-event-files", expectation: Rejected(["on_files"]) },
			{ name: "web-event-key", expectation: Rejected(["on_key"]) },
			{ name: "web-event-empty", expectation: Rejected(["nonempty event type"]) },
			{ name: "web-method-patch", expectation: Rejected(["write", "PATCH"]) },
			{ name: "web-method-forbidden", expectation: Rejected(["browser refuses"]) },
			{ name: "web-method-empty", expectation: Rejected(["one or more token characters"]) },
			{ name: "web-method-space", expectation: Rejected(["one or more token characters"]) },
			{ name: "web-text-tag", expectation: Rejected(["This argument has the type: Str But the function needs the first argument to be: Engine.Tag"]) },
			{ name: "web-interpolation", expectation: Rejected(["Web.AttrName"]) },
			{ name: "web-shared-constant", expectation: Rejected(["Web.AttrName", "Str"]) },
			{ name: "web-method-request", expectation: Rejected(["Fetch({ cache: [Default, ForceCache, NoCache, NoStore, Reload], credentials: [Include, SameOrigin], headers: List((Str, Str)), method: Str,", "But the annotation says it should be: Engine.Request"]) },
			{ name: "web-method-upload", expectation: Rejected(["method: Str ?? …", "But upload needs the first argument to be: Core.UploadProps"]) },
			{ name: "web-upload-get", expectation: Rejected(["GET carries no body, so it cannot upload a file"]) },
			{ name: "web-method-sent", expectation: Rejected(["The first branch is: Web.Method But the match is expected to have the type: Str"]) },
			{ name: "web-public-family", expectation: Compiles },
			{ name: "vocabulary-tag-typo", expectation: Rejected(["did you mean \"div\"", "Web.Tag.from_str"]) },
			{ name: "vocabulary-tag-unknown", expectation: Rejected(["pinned roc-parser vocabulary", "Web.Tag.from_str"]) },
			{ name: "vocabulary-tag-obsolete", expectation: Rejected(["pinned roc-parser vocabulary", "Web.Tag.from_str"]) },
			{ name: "vocabulary-tag-mathml", expectation: Rejected(["is a MathML element", "does not create in its namespace", "Web.Tag.from_str"]) },
			{ name: "vocabulary-tag-svg-case", expectation: Rejected(["did you mean \"linearGradient\"", "Web.Tag.from_str"]) },
			{ name: "vocabulary-aria-typo", expectation: Rejected(["did you mean \"aria-label\"", "Web.AttrName.from_str"]) },
			{ name: "vocabulary-aria-future", expectation: Rejected(["not an ARIA attribute", "Web.AttrName.from_str"]) },
			{ name: "vocabulary-uncalled", expectation: Rejected(["did you mean \"div\"", "Web.Tag.from_str"]) },
			{ name: "vocabulary-escape", expectation: Compiles },
			{ name: "vocabulary-tag-colon-case", expectation: Rejected(["<Data:Point-x> holds a colon, which SVG keeps as local text only in a name that starts with an ASCII letter and holds no ASCII capitals", "write \"data:point-x\""]) },
			{ name: "missing-keymap", expectation: Rejected(["Engine.KeyProps"]) },
			{ name: "key-prevent", expectation: Rejected(["Engine.KeyProps"]) },
			{ name: "document-row", expectation: Rejected(["outside_rows"]) },
			{ name: "document-state-in-row", expectation: Rejected(["outside_rows"]) },
			{ name: "dialog-open-text", expectation: Rejected(["Bool"]) },
			{ name: "dialog-close-text", expectation: Rejected(["Bool"]) },
			{ name: "popover-toggle-text", expectation: Rejected(["Bool"]) },
			{ name: "table-bookkeeping", expectation: Rejected(["This with_id method is being called on a value whose type doesn't have that method"]) },
			{ name: "internal-module", expectation: Rejected(["package module is private"]) },
			{ name: "wire-internal-module", expectation: Rejected(["does not name a public module"]) },
			{ name: "wire-internal-encode", expectation: Rejected(["pf.Wire.encode_with_files does not exist."]) },
			{ name: "wire-internal-decode", expectation: Rejected(["pf.Wire.decode_with_held does not exist."]) },
			{ name: "wire-internal-state", expectation: Rejected(["pf.Wire.encode_state does not exist."]) },
			{ name: "wire-opaque-encoder", expectation: Rejected(["The type Enc is not exposed by the module pf.Wire."]) },
			{ name: "wire-opaque-reader", expectation: Rejected(["The type State is not exposed by the module pf.Wire."]) },
			{ name: "wire-custom-codec", expectation: Compiles },
			{ name: "port-opaque-out", expectation: Rejected(["an instance of PortJson.Out"]) },
			{ name: "port-opaque-body", expectation: Rejected(["The type OutBody is not exposed by the module pf.PortJson."]) },
			{ name: "port-custom-codec", expectation: Compiles },
			{ name: "wire-record-key", expectation: Rejected(["which does not have a method named encode_key_start", "which does not have a method named parse_key_start"]) },
			{ name: "wire-nominal-key", expectation: Rejected(["which does not have a method named encode_key_start", "which does not have a method named parse_key_start"]) },
			{ name: "ask-reaction-type", expectation: Rejected(["type mismatch"]) },
			{ name: "ask-mixed-plan", expectation: Rejected(["incompatible types"]) },
			{ name: "ask-await-command", expectation: Rejected(["Engine.Command"]) },
			{ name: "crypto-key-forge", expectation: Rejected(["cannot use opaque nominal type", "Core.CryptoKey"]) },
			{ name: "crypto-key-token", expectation: Rejected(["This token method is being called on a value whose type doesn't have that method"]) },
			{ name: "crypto-key-worker", expectation: Rejected(["method named encoder_for", "Core.CryptoKey"]) },
			{ name: "crypto-key-port", expectation: Rejected(["method named encoder_for", "Core.CryptoKey"]) },
			{ name: "ask-private-constructor", expectation: Rejected(["cannot use opaque nominal type", "You're attempting to create an instance of Core.Ask, but it's an opaque type."]) },
			{ name: "ask-private-reader", expectation: Rejected(["The type Ask does not have an associated", "named read."]) },
			{ name: "layout-scroll-text", expectation: Rejected(["top: U32"]) },
			{ name: "layout-size-text", expectation: Rejected(["width: U32"]) },
			{ name: "layout-seen-text", expectation: Rejected(["ratio_permille: U16"]) },
			{ name: "timeout-zero", expectation: Rejected(["a timeout of Ms(0)"]) },
			{ name: "port-float-key", expectation: Rejected(["parse_key_f64"]) },
			{ name: "checkbox-text-payload", expectation: Rejected(["This string literal is being used where a non-string type is needed", "Bool"]) },
			{ name: "select-text-payload", expectation: Rejected(["The sixth argument", "[Chose(Str), NotOffered]"]) },
			{ name: "sort-tuple", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-tag", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-record", expectation: Rejected(["order_relative_to"]) },
			{ name: "sort-key", expectation: Rejected(["order_relative_to"]) },
			{ name: "signal-text-str-part", expectation: Rejected(["to_text_signal"]) },
			{ name: "signal-text-mixed-parts", expectation: Rejected(["✗ type mismatch", "It has the type: Engine.Signal(Engine.Root, U64) But you are trying to use it as: Engine.Signal(Engine.Root, Str)"]) },
			{ name: "signal-text-record-part", expectation: Rejected(["to_str"]) },
			{ name: "signal-text-shared-literal", expectation: Rejected(["type mismatch", "Engine.Signal"]) },
			{ name: "signal-text-positive", expectation: Compiles },
			{ name: "worker-module-duplicate", expectation: ConstantCrash({ at: "main = Engine.program(|| Engine.text(\"\")).with_workers([job.registration()]).with_workers([job.registration()])", rules: ["worker task \"test/duplicate-worker\" is registered twice"] }) },
			{ name: "port-record-duplicate", expectation: ConstantCrash({ at: "registrations = Port.registrations(ports)", rules: ["port \"test/duplicate\" is declared twice"] }) },
			{ name: "port-module-duplicate", expectation: ConstantCrash({ at: "main = program", rules: ["port \"test/across-modules\" is declared twice"] }) },
			{ name: "port-record-data", expectation: ConstantCrash({ at: "registrations = Port.registrations(ports)", rules: ["Port.registrations: field \"actions.label\" is not a port"] }) },
			{ name: "mount-table-order-same", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two rows of a table view compare Same", "site /0"] }) },
			{ name: "mount-table-key", expectation: ConstantCrash({ at: "Err(DuplicateKey(key)) => crash \"rows lists the key \${key.to_str()} twice\"", rules: ["rows lists the key 1 twice"] }) },
			{ name: "mount-two-handlers", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: two handlers for the \"click\" event on one <button> at site /0 (element /, \"Save\")"] }) },
			{ name: "mount-empty-row-handlers", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["two handlers", "row template", "site /0"] }) },
			{ name: "mount-row-shape", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["row template must be a single element", "site /0"] }) },
			{ name: "mount-table-row-shape", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["a table view row template must be a single element", "site /0"] }) },
			{ name: "mount-app-crash", expectation: ConstantCrash({ at: "main = Engine.program(|| crash \"first page failed\")", rules: ["The crash happened with this message: first page failed"] }) },
			{ name: "mount-inline-expect", expectation: ConstantExpect({ at: "expect boot.url != \"/\"", rules: ["expect failed"] }) },
			{ name: "mount-unreached-nested-row", expectation: Compiles },
			{ name: "markup-input-value", expectation: Rejected(["line 1", "checkbox"]) },
			{ name: "markup-boolean-value", expectation: Rejected(["line 1, column 8: \"false\" is not a value of disabled; expected \"\", \"disabled\""]) },
			{ name: "markup-hidden-value", expectation: Rejected(["line 1, column 4: \"flase\" is not a value of hidden; expected \"\", \"hidden\", \"until-found\""]) },
			{ name: "markup-aria-value", expectation: Rejected(["line 1, column 9: \"ture\" is not a value of aria-pressed;", "did you mean \"true\"?"]) },
			{ name: "markup-element-attribute", expectation: Rejected(["line 1, column 6: <div> has no attribute \"value\""]) },
			{ name: "markup-element-name", expectation: Rejected(["line 1", "div"]) },
			{ name: "markup-aria-name", expectation: Rejected(["line 1", "aria-label"]) },
			{ name: "markup-svg-case", expectation: Rejected(["line 1, column 6: <svg> has no attribute \"viewbox\""]) },
			{ name: "markup-svg-numbers", expectation: Rejected(["line 1, column 6: \"0 0 10\" is not a value of viewBox; expected 4 numbers"]) },
			{ name: "markup-svg-path", expectation: Rejected(["line 1, column 7: \"M nonsense\" is not a value of d; expected valid SVG path data"]) },
			{ name: "markup-repair", expectation: Rejected(["line 1, column 4: the HTML parser would move content away from its written parent"]) },
			{ name: "markup-handler", expectation: Rejected(["line 1", "holds no handlers"]) },
			{ name: "markup-comment-root", expectation: Rejected(["line 1", "one element root"]) },
			{ name: "markup-text-root", expectation: Rejected(["line 1", "one element root"]) },
			{ name: "markup-two-roots", expectation: Rejected(["line 1", "exactly one element root"]) },
			{ name: "markup-doctype", expectation: Rejected(["line 1, column 1: the HTML parser would discard written markup"]) },
			{ name: "markup-boolean-hole", expectation: Rejected(["Boolean attribute", "Html.boolean"]) },
			{ name: "markup-partial-attribute", expectation: Rejected(["hole"]) },
			{ name: "markup-comment-hole", expectation: Rejected(["line 1, column 10: hole index 0: holes are not allowed in comments, declarations or markup delimiters"]) },
			{ name: "markup-child-part", expectation: Rejected(["to_text_signal"]) },
			{ name: "markup-tag-hole", expectation: Rejected(["line 1, column 2: hole index 0: expected character data or an entire quoted attribute value"]) },
			{ name: "markup-attribute-hole", expectation: Rejected(["line 1, column 4: hole index 0: expected character data or an entire quoted attribute value"]) },
			{ name: "markup-raw-part", expectation: Rejected(["to_text_signal", "Str"]) },
			{ name: "markup-arity-fewer", expectation: ConstantCrash({ at: "view = {", rules: ["contract", "fewer parts"] }) },
			{ name: "markup-arity-more", expectation: ConstantCrash({ at: "view = {", rules: ["contract", "more parts"] }) },
			{ name: "markup-opaque-plan", expectation: Rejected(["This is not a record, so it does not have any fields to access. It is: Html.Markup(Ctx) But I need a record with a plan field."]) },
			{ name: "markup-mathml-handler", expectation: Rejected(["line 1", "holds no handlers"]) },
			{ name: "markup-svg-input-handler", expectation: Rejected(["line 1", "holds no handlers"]) },
			{ name: "markup-processing-instruction", expectation: Rejected(["line 1", "processing instruction"]) },
			{ name: "input-kind-mixed", expectation: Compiles },
			{ name: "input-kind-typo", expectation: Rejected(["is not an input type", "did you mean \"checkbox\""]) },
			{ name: "input-kind-text", expectation: Rejected(["This argument has the type: Str But the function needs the second argument to be: Html.InputType"]) },
			{ name: "input-kind-union", expectation: Rejected(["It has the type: [Unlisted] But the annotation says it should be: Html.InputType"]) },
			{ name: "markup-property-value", expectation: Rejected(["line 1", "Engine.Prop.value", "Engine.prop_s", "constructor"]) },
			{ name: "markup-property-checked", expectation: Rejected(["line 1", "Engine.Prop.checked", "constructor"]) },
			{ name: "markup-property-value-hole", expectation: Rejected(["line 1", "Engine.Prop.value", "constructor"]) },
			{ name: "markup-property-checked-hole", expectation: Rejected(["line 1", "Engine.Prop.checked", "constructor"]) },
			{ name: "markup-property-uppercase", expectation: Rejected(["line 1", "Engine.Prop.value"]) },
			{ name: "markup-property-option", expectation: Rejected(["line 1", "Engine.Prop.value"]) },
			{ name: "markup-property-foreign", expectation: Compiles },
			{ name: "construction-paragraph", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the paragraph first", "site"] }) },
			{ name: "construction-insert-table-section", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["insert a table section first", "site"] }) },
			{ name: "construction-invalid-table-child", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["move it outside the table", "site"] }) },
			{ name: "construction-table-part-outside", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["a table part needs its table context", "site"] }) },
			{ name: "construction-nested-anchor", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier anchor first", "site"] }) },
			{ name: "construction-nested-form", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["ignore the nested form", "site"] }) },
			{ name: "construction-nested-button", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier button first", "site"] }) },
			{ name: "construction-list-item", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier list item first", "site"] }) },
			{ name: "construction-description-item", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier description item first", "site"] }) },
			{ name: "construction-option", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier option first", "site"] }) },
			{ name: "construction-heading", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["close the earlier heading first", "site"] }) },
			{ name: "construction-void", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["a void element cannot hold children", "site"] }) },
			{ name: "construction-text-content", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["reads this content as text", "site"] }) },
			{ name: "construction-foster-table-text", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["move the text outside the table", "site"] }) },
			{ name: "construction-empty-each", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["insert a table section first", "site"] }) },
			{ name: "construction-empty-row-void-text", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["a void element cannot hold children", "site"] }) },
			{ name: "markup-table-row", expectation: Compiles },
			{ name: "markup-table-row-outside", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: <tr> under <div>: a table part needs its table context"] }) },
			{ name: "construction-raw-svg-colon", expectation: Compiles },
			{ name: "construction-raw-svg-colon-refused", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: raw <:foo> cannot be created under <svg>", "must begin with an ASCII letter", "at site / (element /0)"] }) },
			{ name: "construction-empty-table-view", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: <tr> inside <table>: the HTML parser would insert a table section first in the row template of a table view at site /0"] }) },
			{ name: "construction-text-hole", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: text inside <table>: the HTML parser would move the text outside the table; a text hole here can hold text, whatever it holds now at site /0"] }) },
			{ name: "construction-row-text-hole", expectation: ConstantCrash({ at: "mounted = Engine.mounts(main)", rules: ["contract: text inside <table>: the HTML parser would move the text outside the table; a text hole here can hold text, whatever it holds now in the row template of an each at site /0"] }) },
		]
		dir = "${o.build_dir}/key-type-errors"
		SpecSuite.fresh_dir!(dir)?
		var $fixtures = []
		for test in cases {
			fixture = Path.read_utf8!(Path.utf8("${o.root}/tests/type-errors/${test.name}.roc.txt"))?
			case_dir = "${dir}/${test.name}"
			Path.create_all!(Path.utf8(case_dir))?
			up = Str.join_with(List.repeat("..", case_dir.split_on("/").keep_if(|part| !part.is_empty()).len()), "/")
			platform_path = "${up}/${o.root.drop_prefix("/")}/platform/main.roc"
			source = fixture.replace_each("<PLATFORM>", platform_path)
			path = "${case_dir}/main.roc"
			Path.write_utf8!(Path.utf8(path), source)?
			$fixtures = $fixtures.append({ test, source, path })
		}
		fixtures = $fixtures
		jobs = Proc.compiler_jobs!(App)?
		Proc.note!("== declaration contracts: roc check of ${fixtures.len().to_str()} fixtures, ${jobs.to_str()} at a time; each must fail naming its rule, or compile")
		results = Proc.parallel_with!(fixtures.map(|f| { program: o.compiler, args: ["check", f.path], cwd: o.root }), jobs, Line)?
		var $problems = []
		for (fixture, result) in List.map2(fixtures, results, |fixture, result| (fixture, result)) {
			{ test, source, .. } = fixture
			code = result.code
			output = result.output
			diagnostic = diagnostic_message(output, source)
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

	## The declaration and request contracts, as cases of two apps, each
	## built once: `tests/apps/key-contracts` (the platform's contracts) and
	## the fixture `tests/key-contracts/oracle.roc.txt` (those of the native
	## oracle and the engine package, which only a fixture may name). An
	## instance boots at a case's path to mount that case alone. Natively
	## every case is one run of its app's runner on a spec that boots there,
	## which must end with the case's class and rule and exit code; both
	## apps' root paths must pass, so a case's failure is its own. In Chrome
	## `tests/browser/key-contracts-browser.mjs` mounts the platform app's
	## one Wasm build at each case its table names (an oracle case has no
	## browser build to mount, and naming one is a problem).
	key_contracts! : SpecSuite.Options => Try(List(Str), _)
	key_contracts! = |o| {
		cases = [
			{ name: "oracle-flags", rejection: "unknown command batch flags", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-crypto-password-invalid", rejection: "bad utf8", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-crypto-password-overlong", rejection: "bad utf8", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-crypto-password-surrogate", rejection: "bad utf8", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-crypto-password-truncated", rejection: "bad utf8", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-crypto-password-empty", rejection: "", prefix: "", code: 0, program: Oracle },
			{ name: "oracle-missing-transition", rejection: "marked batch is missing TRANSITION", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-unmarked-transition", rejection: "TRANSITION requires marked batch", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-transition-trailing", rejection: "TRANSITION must be last", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-transition-truncated", rejection: "short command", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-leading-zero", rejection: "leading zero", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-apply-file", rejection: "value property on file input", prefix: "contract:", code: 70, program: Oracle },
			{ name: "document-bound", rejection: "32", prefix: "contract:", code: 70, program: Contracts },
			{ name: "apply-noncontrol", rejection: "ApplyValue", prefix: "contract:", code: 70, program: Contracts },
			{ name: "apply-without-value", rejection: "ApplyValue", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-open", rejection: "owned by the controlled dialog", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-dynamic-open", rejection: "owned by the controlled dialog", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-popover", rejection: "popover and closedby", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-dynamic-popover", rejection: "popover and closedby", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-closedby", rejection: "popover and closedby", prefix: "contract:", code: 70, program: Contracts },
			{ name: "dialog-dynamic-closedby", rejection: "popover and closedby", prefix: "contract:", code: 70, program: Contracts },
			{ name: "controlled-beforetoggle", rejection: "beforetoggle", prefix: "contract:", code: 70, program: Contracts },
			{ name: "popover-beforetoggle", rejection: "beforetoggle", prefix: "contract:", code: 70, program: Contracts },
			{ name: "popover-duplicate", rejection: "one static popover", prefix: "contract:", code: 70, program: Contracts },
			{ name: "popover-dynamic-popover", rejection: "one static popover", prefix: "contract:", code: 70, program: Contracts },
			{ name: "media-undeclared", rejection: "missing-media", prefix: "contract:", code: 70, program: Contracts },
			{ name: "table-order-same", rejection: "two rows of a table view compare Same", prefix: "contract:", code: 70, program: Contracts },
			{ name: "signal-text-manual-arity", rejection: "Signal.from_interpolation", prefix: "contract:", code: 70, program: Contracts },
			{ name: "keep-current-subscription", rejection: "keep_current cannot issue a subscription", prefix: "contract:", code: 70, program: Contracts },
			{ name: "interval-zero", rejection: "Interval(0) has no period", prefix: "contract:", code: 70, program: Contracts },
			{ name: "timer-overflow", rejection: "Timer(3000000000) is longer", prefix: "contract:", code: 70, program: Contracts },
			{ name: "interval-overflow", rejection: "Interval(2147483648) is longer", prefix: "contract:", code: 70, program: Contracts },
			{ name: "timer-overflow-boundary", rejection: "Timer(2147483648) is longer", prefix: "contract:", code: 70, program: Contracts },
			{ name: "timeout-zero", rejection: "a timeout of Ms(0)", prefix: "contract:", code: 70, program: Contracts },
			{ name: "raw-controlled-attributes", rejection: "", prefix: "", code: 0, program: Contracts },
			{ name: "oracle-namespace", rejection: "unknown namespace kind", prefix: "executor:", code: 70, program: Oracle },
			{ name: "oracle-content-container", rejection: "invalid child container", prefix: "executor:", code: 70, program: Oracle },
			{ name: "raw-uppercase-value", rejection: "claimed by a property", prefix: "contract:", code: 70, program: Contracts },
			{ name: "construction-later-branch", rejection: "close the paragraph first", prefix: "contract:", code: 70, program: Oracle },
			{ name: "construction-later-row", rejection: "close the paragraph first", prefix: "contract:", code: 70, program: Oracle },
			{ name: "construction-later-state", rejection: "close the paragraph first", prefix: "contract:", code: 70, program: Oracle },
			{ name: "construction-later-text", rejection: "move the text outside the table; a text hole here can hold text", prefix: "contract:", code: 70, program: Oracle },
			{ name: "construction-later-row-text", rejection: "move the text outside the table; a text hole here can hold text", prefix: "contract:", code: 70, program: Oracle },
		]
		dir = "${o.build_dir}/key-contracts"
		SpecSuite.fresh_dir!(dir)?
		browser_test = "tests/browser/key-contracts-browser.mjs"
		in_browser = browser_fixtures(Path.read_utf8!(Path.utf8("${o.root}/${browser_test}"))?, cases.keep_if(|test| test.program == Contracts).map(|test| test.name))
		var $problems = in_browser.unknown.map(|name| "${browser_test} mounts the key contract ${name}, which is no case of tests/apps/key-contracts")
		oracle_dir = "${dir}/oracle"
		Path.create_all!(Path.utf8(oracle_dir))?
		fixture = Path.read_utf8!(Path.utf8("${o.root}/tests/key-contracts/oracle.roc.txt"))?
		up = Str.join_with(List.repeat("..", oracle_dir.split_on("/").keep_if(|part| !part.is_empty()).len()), "/")
		Path.write_utf8!(Path.utf8("${oracle_dir}/main.roc"), fixture.replace_each("<PLATFORM>", "${up}/${o.root.drop_prefix("/")}/platform/main.roc").replace_each("<ORACLE>", "${up}/${o.root.drop_prefix("/")}/platform/main-fuzz.roc"))?
		runner_of = |program| match program {
			Contracts => "${dir}/runner"
			Oracle => "${oracle_dir}/runner"
		}
		wasm = "${dir}/app.wasm"
		jobs = [
			{ program: Contracts, job: SpecSuite.build_job(o, "dev", "tests/apps/key-contracts/main.roc", o.target, runner_of(Contracts)) },
			{ program: Oracle, job: SpecSuite.build_job(o, "dev", "${oracle_dir}/main.roc", o.target, runner_of(Oracle)) },
		].concat(if (in_browser.listed.is_empty()) [] else [{ program: Contracts, job: SpecSuite.build_job(o, "dev", "tests/apps/key-contracts/main.roc", "wasm32", wasm) }])
		limit = Proc.compiler_jobs!(App)?
		Proc.note!("== key contracts: ${cases.len().to_str()} cases of 2 apps; ${jobs.len().to_str()} builds, ${limit.to_str()} at a time")
		built = Proc.parallel!(jobs.map(|j| j.job), limit)?
		failed = List.map2(jobs, built, |j, r| (j, r)).keep_if(|(_, r)| r.code != 0)
		for (j, r) in failed {
			$problems = $problems.append("key contracts: ${Proc.show(j.job)} exited with ${r.code.to_str()}")
		}
		if !failed.is_empty() {
			return Ok($problems)
		}
		run_case! = |program, name, path| {
			spec = "${dir}/${name}.scm"
			Path.write_utf8!(Path.utf8(spec), contract_spec(path))?
			{ code, stdout } = Proc.merged!({ program: runner_of(program), args: [spec], cwd: dir })?
			Ok({ code, message: Str.from_utf8_lossy(stdout) })
		}
		for (program, label) in [(Contracts, "key-contracts"), (Oracle, "oracle")] {
			root = run_case!(program, "${label}-root", "/")?
			if root.code != 0 {
				$problems = $problems.append("key contracts: the ${label} app's root path must break no contract, got ${root.code.to_str()}: ${root.message}")
			}
		}
		for test in cases {
			{ code, message } = run_case!(test.program, test.name, "/${test.name}")?
			if code != test.code or !message.contains(test.prefix) or !message.contains(test.rejection) {
				$problems = $problems.append("native key contract ${test.name}: expected ${test.prefix} ${test.rejection}, got ${code.to_str()}: ${message}")
			}
		}
		if in_browser.listed.is_empty() {
			return Ok($problems)
		}
		{ code, .. } = Proc.output!({ program: o.node, args: [browser_test, "--wasm", wasm, "--runtime", SpecSuite.runtime, "--chrome", o.chrome], cwd: o.root })?
		Ok(if (code == 0) $problems else $problems.append("browser key contracts failed (see above)"))
	}

	## Run the specs of one app that `o.filter` selects natively, and in
	## Chrome when `browser`, with the builds `SpecSuite.build!` made. Each
	## run is judged by `SpecSuite.judge`: a runner that stops before giving
	## every selected spec a result, or exits with a code its lines do not
	## explain, is a problem in the tally beside the failures it reported.
	## A listed app with no specs at all is a problem of its native tally.
	## Returns the tallies, how many specs the filter selected and the
	## native runner's path. `shipping` says whether the `--opt=size` build
	## a compiler-keyed skip runs specs on is to be made here (`Build`) or
	## was made by the caller's batch (`Built`).
	run_app! : SpecSuite.Options, Str, Bool, [Build, Built] => Try({ native : SpecSuite.Tally, browser : SpecSuite.Tally, selected : U64, runner : Str }, _)
	run_app! = |o, example, browser, shipping| {
		every = SpecSuite.spec_files!(example)?
		specs = SpecSuite.select(o.filter, every)
		runner = SpecSuite.runner_of(o, example)
		ran = SpecSuite.native_specs!({ example, runner, specs })?
		native = if (every.is_empty()) { ..ran, problems: ran.problems.append("${example} is listed for specs but its specs directory holds none") } else ran
		Proc.note!(SpecSuite.summary(example, Native, native))
		in_browser =
			if browser {
				all = SpecSuite.spec_files!(example)?.map(SpecSuite.id_of)
				match SpecSuite.active_skips({ skips: CompilerSkips.skips, nightly: o.nightly, example, known: all, selected: specs.map(SpecSuite.id_of) }) {
					Err(problem) => { ..SpecSuite.empty_tally, problems: [problem] }
					Ok(skips) => {
						skip = skips.map(|s| s.spec)
						for s in skips {
							Proc.note!(SpecSuite.skip_line(o.nightly, s))
						}
						t = SpecSuite.browser_specs!(o, { example, runner, wasm: SpecSuite.wasm_of(o, example), specs, skip })?
						shipped = Checks.size_build_specs!(o, { example, runner, specs: specs.keep_if(|path| skip.contains(SpecSuite.id_of(path))), shipping })?
						total = { ..SpecSuite.add(t, shipped), skipped: t.skipped + skip.len() }
						Proc.note!(SpecSuite.summary(example, Browser, total))
						total
					}
				}
			} else {
				SpecSuite.empty_tally
			}
		Ok({ native, browser: in_browser, selected: specs.len(), runner })
	}

	## Run in Chrome, on an `--opt=size` build of `example`, the specs a
	## compiler-keyed skip keeps from its development build, which must pass
	## there: the behaviour they check is still checked on the build that
	## ships, so a regression of it cannot hide behind the skip. Their
	## summary is printed under `example (size Wasm)`; only their problems
	## join the tally, whose counts belong to the development run.
	size_build_specs! : SpecSuite.Options, { example : Str, runner : Str, specs : List(Str), shipping : [Build, Built] } => Try(SpecSuite.Tally, _)
	size_build_specs! = |o, { example, runner, specs, shipping }| {
		if specs.is_empty() {
			return Ok(SpecSuite.empty_tally)
		}
		wasm = SpecSuite.size_wasm_of(o, example)
		# `Built`: the caller's batch made it (`SpecSuite.build_all!`).
		if shipping == Build {
			Path.create_all!(Path.utf8(wasm.drop_suffix("/app.wasm")))?
			Proc.run!(SpecSuite.build_job(o, "size", "${SpecSuite.dir_of(example)}/main.roc", "wasm32", wasm))?
		}
		t = SpecSuite.browser_specs!(o, { example: "${example} (size Wasm)", runner, wasm, specs, skip: [] })?
		Proc.note!(SpecSuite.summary("${example} (size Wasm)", Browser, t))
		Ok({ ..SpecSuite.empty_tally, problems: t.problems })
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
	## also hold both runners to rejecting an invalid hold lifecycle. State
	## assertions on a paragraph, which has no shown, checked, disabled or
	## value state, must fail in both runners with one message rather than
	## read a default. A link to a `mailto:` URL leaves the app in both
	## runners, never resolving as a path on its origin. A fill Chrome's typing would
	## change (a read-only control, text over `maxlength`, a line break in a
	## single-line control, white space around an email address, a control
	## in a disabled field set) and a scripted change its value setter would
	## rewrite are refused by both. So is a click on an HTML button the
	## browser does not draw because it sits under an SVG mount root.
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
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(expect-shown (test-id \"state\") hidden)", rejection: "is neither a dialog nor a popover, so it has no shown state" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(expect-checked (test-id \"state\") false)", rejection: "has no checked state: it is not an <input>" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(expect-disabled (test-id \"state\") false)", rejection: "has no disabled state" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(expect-value (test-id \"state\") \"\")", rejection: "has no live value property" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(fill (label \"Read-only field\") \"abc\")", rejection: "is read-only" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(fill (label \"Short field\") \"abcd\")", rejection: "it is longer than its maxlength 3" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(fill (label \"Short field\") \"a\\nb\")", rejection: "a single-line control turns a line break into a space" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(fill (label \"Email field\") \" a@b \")", rejection: "an email control trims white space" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(fill (label \"Fenced field\") \"x\")", rejection: "is disabled" },
		{ example: "controls", spec: "tests/apps/controls/specs/focus.scm", good: "(click (role button :name \"Focus upper\"))", bad: "(change (label \"Email field\") \" a@b \")", rejection: "cannot take" },
		{ example: "namespaces", spec: "tests/apps/namespaces/specs/svg-root.scm", good: "(navigate \"/#hidden\")", bad: "(click (role button :name \"Toggle namespace subtree\"))", rejection: "is not rendered: the browser draws no HTML element inside SVG outside foreignObject" },
		{ example: "services", spec: "tests/apps/services/specs/url-links.scm", good: "(click (role link :name \"Follow raw fragment\"))", bad: "(click (role link :name \"Write mail\"))", rejection: "the click navigates to mailto:a@b, which leaves the app" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(hold-reports)", bad: "(hold-reports) (hold-reports)", rejection: "reports are already held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(hold-reports)", bad: "(release-reports)", rejection: "reports are not held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(expect-reports-replaced 0)", bad: "(hold-reports)", rejection: "spec ended while reports were held" },
		{ example: "services", spec: "tests/apps/services/specs/reports.scm", good: "(release-reports)", bad: "(navigate \"/leave-held-document\")", rejection: "cross-document navigation" },
	]

	## The broken specs whose bad step breaks a contract the engine refuses
	## by poisoning the instance: an outbox posted twice in one turn. In
	## Chrome the replay fails the spec with the contract's message. The
	## native runner shares the page's process, so there the refusal is a
	## crash that ends the run (exit 70) before the spec has a result; the
	## suite must report that run as a failure (`SpecSuite.judge`), never
	## count it as a shorter run that passed.
	crashing_specs : List(Broken)
	crashing_specs = [
		{ example: "outbox", spec: "tests/apps/outbox/specs/list.scm", good: "(click (role button :name \"Send both\"))", bad: "(click (role button :name \"Send twice\"))", rejection: "posted 2 times in one turn" },
	]

	## Each runner must reject each deliberately broken spec. With
	## `Rejects` (`broken_specs`) the native runner reports it as failed;
	## with `Crashes` (`crashing_specs`) it runs the broken spec before the
	## original, crashes on the first and leaves both without a result, and
	## the suite's verdict on that run must say so with exit 70. In Chrome
	## both are failed with `rejection`. A runner that passes one is not
	## evidence of anything.
	broken_spec! : SpecSuite.Options, Broken, [Rejects, Crashes] => Try(List(Str), _)
	broken_spec! = |o, { example, spec, good, bad, rejection }, natively| {
		original = Path.read_utf8!(Path.utf8(spec))?
		if !original.contains(good) {
			return Ok(["broken-spec self-check: ${spec} no longer holds ${good}; choose a new assertion to break"])
		}
		runner = SpecSuite.runner_of(o, example)
		dir = "${o.build_dir}/broken-spec/${example}"
		SpecSuite.fresh_dir!(dir)?
		broken = "${dir}/broken.scm"
		Path.write_utf8!(Path.utf8(broken), original.replace_each(good, bad))?
		rejected = |lines| lines.any(|l| SpecSuite.json_field(l, "status") == "failed" and SpecSuite.json_message(l).contains(rejection))
		native_problems = match natively {
			Rejects => if (rejected(SpecSuite.run_native!(runner, [broken])?.lines)) [] else ["broken-spec self-check: the native runner did not reject the broken ${spec}"]
			Crashes => {
				run = SpecSuite.run_native!(runner, [broken, spec])?
				verdict = SpecSuite.judge({ example, stage: Native, expected: ["broken", SpecSuite.id_of(spec)], run })
				if run.code == 70 and verdict.unreported == 2 and verdict.problems.len() == 2 {
					[]
				} else {
					["broken-spec self-check: the crashing ${spec} did not end the native run with 70 and two specs without a result, as the suite must report (exit ${run.code.to_str()}; ${Str.join_with(verdict.problems, "; ")})"]
				}
			}
		}
		steps = Proc.capture!({ program: runner, args: ["--emit-steps", broken], cwd: "." })?
		Path.write_bytes!(Path.utf8("${dir}/steps.jsonl"), steps)?
		{ stdout, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--wasm", SpecSuite.wasm_of(o, example), "--runtime", SpecSuite.runtime, "--steps", "${dir}/steps.jsonl", "--chrome", o.chrome, "--json-lines"], cwd: "." })?
		in_browser = Str.from_utf8_lossy(stdout).split_on("\n")
		Ok(
			native_problems
				.concat(if (rejected(in_browser)) [] else ["broken-spec self-check: the browser runner did not reject the broken ${spec}"]),
		)
	}

	## A native target override lets the same early-refusal contract run on a
	## contributor's system; CI uses the ordinary native suite target.
	DeclarationProps := { target : Str ?? "x64musl" }

	## Build one crash-on-init fixture and require every malformed declaration
	## name to fail identically before native execution and browser emission.
	## Rejected output is never replayed as if it were a valid browser story.
	declaration_refusals! : SpecSuite.Options, DeclarationProps => Try(List(Str), _)
	declaration_refusals! = |o, props| {
		dir = "${o.build_dir}/declaration-refusals"
		SpecSuite.fresh_dir!(dir)?
		runner = "${dir}/runner"
		Proc.run!(SpecSuite.build_job(o, "dev", "tests/fixtures/declarations/main.roc", props.target, runner))?
		cases = [
			{ name: "unknown-task", message: "expect-pending-work names worker catalogue entry \"misspelt-task\", which the program does not register" },
			{ name: "unknown-port", message: "expect-port-sends names port \"misspelt-port\", which the program does not declare" },
			{ name: "command-as-subscription", message: "expect-port-subscriptions names port \"command\", which is a command port; this step requires a subscription port" },
			{ name: "subscription-as-command", message: "expect-port-sends names port \"subscription\", which is a subscription port; this step requires a command port" },
			{ name: "command-as-call", message: "expect-port-call names port \"command\", which is a command port; this step requires a call port" },
			{ name: "unknown-media", message: "expect-media-subscriptions names media query \"misspelt-query\", which the program does not declare" },
			{ name: "unknown-setup-media", message: "setup names media query \"misspelt-query\", which the program does not declare" },
			{ name: "unknown-local", message: "expect-no-local-storage names local-storage key \"misspelt-local\", which is neither declared nor seeded or positively established in this spec" },
			{ name: "unknown-session", message: "expect-no-session-storage names session-storage key \"misspelt-session\", which is neither declared nor seeded or positively established in this spec" },
		]
		var $problems = []
		for case in cases {
			path = "tests/fixtures/declarations/specs/${case.name}.scm"
			expected = "${path}:3:5: ${case.message}"
			var $failures = []
			for mode in ["native", "emit"] {
				args = if (mode == "emit") ["--emit-steps", path] else [path]
				result = Proc.merged!({ program: runner, args, cwd: o.root })?
				Path.write_bytes!(Path.utf8("${dir}/${case.name}-${mode}.log"), result.stdout)?
				if result.code != 1 {
					$problems = $problems.append("declaration refusal ${case.name} ${mode}: expected exit1, got ${result.code.to_str()}")
				}
				match declaration_failure({ bytes: result.stdout, id: case.name, expected }) {
					Ok(message) => {
						$failures = $failures.append(message)
					}
					Err(message) => {
						$problems = $problems.append("declaration refusal ${case.name} ${mode}: ${message}")
					}
				}
			}
			if $failures.len() != 2 or ($failures.first() != $failures.last()) {
				$problems = $problems.append("declaration refusal ${case.name}: native and emit did not produce the same positioned error")
			}
		}
		known = Proc.merged!({ program: runner, args: ["--emit-steps", "tests/fixtures/declarations/specs/known.scm"], cwd: o.root })?
		Path.write_bytes!(Path.utf8("${dir}/known-emit.log"), known.stdout)?
		if known.code != 0 or !(Str.from_utf8(known.stdout)?).contains("Declarations without initialization") {
			$problems = $problems.append("known declarations were not emitted without initializing the crash-on-init fixture")
		}
		Ok($problems)
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

	## The browser runner's `choose-files` gives the app files read from
	## disk, as a user's choice is: `replay.mjs --check-choose-files` chooses
	## one as the step does, removes its disk file and finds that a read, a
	## slice and a worker's read of it then fail.
	choose_files! : SpecSuite.Options => Try(List(Str), _)
	choose_files! = |o| {
		# replay.mjs names each read that did not fail on stderr.
		{ code, .. } = Proc.output!({ program: o.node, args: ["tests/browser/replay.mjs", "--check-choose-files", "--chrome", o.chrome], cwd: "." })?
		if (code == 0) Ok([]) else Ok(["choose-files: a chosen file is not read from disk (see above)"])
	}

	## Add a stage's problems to those a gate has collected. A stage that
	## cannot run (a tool that will not start, a build that will not link)
	## aborts the gate with its error instead; the problems collected before
	## it are printed first, as the `FAIL` lines `finish!` would print, so
	## one run shows everything it found, not only the abort. The verdict is
	## unchanged: the gate still fails with the stage's error.
	gather! : List(Str), Try(List(Str), e) => Try(List(Str), e)
	gather! = |problems, stage| {
		found = Checks.hold!(problems, stage)?
		Ok(problems.concat(found))
	}

	## Pass on the result of a stage that yields something other than
	## problems (a build, a prepared input), printing the problems collected
	## so far, as `gather!` does, if the stage aborts.
	hold! : List(Str), Try(a, e) => Try(a, e)
	hold! = |problems, stage| {
		for line in aborted_lines(problems, stage) {
			Proc.warn!(line)
		}
		stage
	}

	## End a gate: it passes when it collected no problem, and otherwise
	## prints each as a `FAIL` line and exits with 1.
	finish! : Str, List(Str) => Try({}, [Exit(I32)])
	finish! = |task, problems|
		if problems.is_empty() {
			Proc.note!("${task}: passed")
			Ok({})
		} else {
			for line in failure_lines(problems) {
				Proc.warn!(line)
			}
			Err(Exit(1))
		}
}

## Which of the key-contract fixtures `names` the browser test `script`
## mounts, by the `["NAME",` that opens each entry of its fixture table, and
## the names that table holds that are not fixtures, each of which would ask
## the browser for a build no one made.
browser_fixtures : Str, List(Str) -> { listed : List(Str), unknown : List(Str) }
browser_fixtures = |script, names| {
	table = script.split_on("const fixtures = [").get(1) ?? ""
	entries = (table.split_on("\n];").first() ?? "").split_on("\n").keep_oks(
		|line| match line.trim().split_on("[\"") {
			["", rest, ..] => rest.split_on("\"").first()
			_ => Err(NotAnEntry)
		},
	)
	{ listed: names.keep_if(|name| entries.contains(name)), unknown: entries.drop_if(|name| names.contains(name)) }
}

## The browser test's table names the fixtures it mounts; a fixture it does
## not name is not built for the browser, and a name that is no fixture is
## reported.
expect {
	script = "const x = 1;\nconst fixtures = [\n  [\"document-bound\", [\"more than 32\", \"site\"]],\n  [\"raw-controlled-attributes\", [], false],\n  [\"gone\", [\"x\"]],\n];\nconst y = [\"oracle-flags\"];\n"
	browser_fixtures(script, ["oracle-flags", "document-bound", "raw-controlled-attributes"]) == { listed: ["document-bound", "raw-controlled-attributes"], unknown: ["gone"] }
}

## The spec that boots an app at `path` and only mounts it: a case's
## contract is refused at mount, or at the first turn's requests, before
## any step.
contract_spec : Str -> Str
contract_spec = |path| "(test \"contract\"\n  (setup (initial-location \"${path}\"))\n  (steps (mark-metrics)))\n"

## A case's spec boots at its path.
expect contract_spec("/dialog-open") == "(test \"contract\"\n  (setup (initial-location \"/dialog-open\"))\n  (steps (mark-metrics)))\n"

## What a gate prints for the problems it collected: one `FAIL` line each.
failure_lines : List(Str) -> List(Str)
failure_lines = |problems| problems.map(|problem| "FAIL ${problem}")

## What a gate prints when a stage aborts it: the problems collected before
## the stage, as `FAIL` lines, and nothing when it ran or nothing was found.
aborted_lines : List(Str), Try(a, e) -> List(Str)
aborted_lines = |problems, stage| match stage {
	Ok(_) => []
	Err(_) => failure_lines(problems)
}

## A stage that runs prints nothing yet, whatever was collected before it;
## the gate reports at its end.
expect aborted_lines(["fmt failed"], Ok([])) == []

## An aborting stage prints every problem collected before it, in order, as
## the end of the gate would have.
expect aborted_lines(["fmt failed", "size changed"], Err(CommandFailed("zig"))) == ["FAIL fmt failed", "FAIL size changed"]

## An abort with nothing collected prints nothing beside its own error.
expect aborted_lines([], Err(CommandFailed("zig"))) == []

# The compiler's own words in a diagnostic, as one line with single spaces: a
# report header keeps its title but not the fixture's path, and blank lines,
# echoed source lines and their caret underlines are dropped, so a fixture's
# rule can only be met by what the compiler says, never by the source line it
# quotes or the directory it names.
diagnostic_message : Str, Str -> Str
diagnostic_message = |output, source| {
	written = source.split_on("\n").map(|line| line.trim()).keep_if(|line| !line.is_empty())
	said = output.split_on("\n").map(|line| line.trim()).keep_if(
		|line| {
			echoed = !line.starts_with("──") and written.contains(line)
			underline = line.to_utf8().all(|byte| byte == '^' or byte == ' ')
			!(echoed or underline)
		},
	)
	titled = said.map(|line| if (line.starts_with("── ")) line.drop_prefix("── ").split_on(" ─").first() ?? "" else line)
	Str.join_with(titled, " ")
}

## A rule quoted only by the echoed source line, the caret line or the header's
## path is not part of the message; the header's title and the compiler's own
## sentence are, joined across its wrapped lines.
expect {
	source = "app [main] {}\n\tmarkup = \"<path d=\\\"M nonsense\\\"/>\"\n"
	output = "── ✗ invalid string ─ cases/markup-svg-path/main.roc:2:11\n\nThe from_quote implementation rejected it.\n\nmarkup = \"<path d=\\\"M nonsense\\\"/>\"\n         ^^^^^^^^^^\n\nIt returned this error message:\n\n    line 1, column 7: \"M nonsense\" is not a value of d; expected valid SVG path\n    data\n\n── 1 error and 0 warnings ─ cases/markup-svg-path/main.roc\n"
	message = diagnostic_message(output, source)
	!message.contains("<path") and !message.contains("markup-svg-path") and !message.contains("^") and message.contains("expected valid SVG path data") and message.contains("line 1, column 7") and message.contains("✗ invalid string")
}

# Declaration refusals are parse-phase errors, never executed assertion failures.
# Decode the structured record so quotes and source positions are compared exactly.
declaration_failure : { bytes : List(U8), id : Str, expected : Str } -> Try(Str, Str)
declaration_failure = |{ bytes, id, expected }| {
	text = Str.from_utf8(bytes) ? |_| "runner output was not UTF-8"
	lines = text.split_on("\n").keep_if(|line| line.starts_with("{"))
	line = match lines {
		[only] => only
		_ => return Err("runner did not return exactly one structured refusal")
	}
	record : { protocol : Str, id : Str, name : Str, status : Str, duration_ns : U64, failure : { phase : Str, kind : Str, message : Str, step : U64, line : U64, column : U64 } }
	record = Json.parse(line) ? |_| "runner returned a malformed refusal record"
	if record.protocol != "roc-signals/spec-result/v2" or record.id != id or record.name != "" or record.status != "error" or record.duration_ns != 0 or record.failure.phase != "parse" or record.failure.kind != "parse" or record.failure.step != 0 or record.failure.line != 3 or record.failure.column != 5 or record.failure.message != expected {
		return Err("runner returned the wrong error: ${line}")
	}
	if text.contains("declaration fixture unexpectedly initialized") {
		return Err("the fixture initialized before refusing its declaration")
	}
	Ok(record.failure.message)
}
