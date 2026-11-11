import Checks
import Proc
import SpecSuite
import Targets

## The slow suite: soak.
Slow := [].{

	## The apps soaked in Chrome: every example, and the worker app (soak.mjs
	## holds its jobs and checks its worker instance flat too).
	browser_soak_apps : List(Str)
	browser_soak_apps = SpecSuite.apps.append("worker-search")

	## A native soak: one app's round-trip spec, which the app's native spec
	## runner repeats on the engine alone with flat live allocations and
	## bytes after the runner's two warm-up cycles (`RUNNER --soak 48`).
	NativeSoak : { example : Str, spec : Str }

	## The native soaks, one round trip per app.
	native_soaks : List(NativeSoak)
	native_soaks = [
		{ example: "form-builder", spec: "round-trip-answer-and-reorder" },
		{ example: "kanban-board", spec: "round-trip-add-and-delete-a-card" },
		{ example: "data-grid", spec: "round-trip-filter-and-page" },
		{ example: "markdown-editor", spec: "round-trip-load-two-documents" },
		{ example: "conduit", spec: "round-trip-sign-in-page-and-home" },
		{ example: "field-notes", spec: "round-trip-draft-filter-and-reorder" },
		{ example: "status-page", spec: "round-trip-refresh-answered-healthy" },
		{ example: "spreadsheet-lite", spec: "round-trip-edit-reorder-filter-and-mode" },
		{ example: "worker-lab", spec: "round-trip-a-run-answered-and-reset" },
		{ example: "reading-list", spec: "round-trip-finish-and-read-again" },
		{ example: "log-explorer", spec: "round-trip-search-on-the-timeline" },
		{ example: "supersede", spec: "round-trip-late-branch" },
		{ example: "worker-search", spec: "round-trip-search-and-report" },
	]

	## How many times a native soak repeats its round trip.
	soak_cycles : U64
	soak_cycles = 48

	## Build each soaked app's native runner and soak its round trip, in
	## parallel; a soak that fails, or does not pass its spec, is a problem.
	native_soak! : SpecSuite.Options => Try(List(Str), _)
	native_soak! = |o| {
		SpecSuite.build!(o, Slow.native_soaks.map(|s| s.example), [])?
		jobs = Slow.native_soaks.map(
			|s| {
				program: SpecSuite.runner_of(o, s.example),
				args: ["--soak", Slow.soak_cycles.to_str(), "${SpecSuite.dir_of(s.example)}/specs/${s.spec}.scm"],
				cwd: o.root,
			},
		)
		results = Proc.parallel!(jobs, Proc.cpus!())?
		Ok(List.map2(Slow.native_soaks, results, |s, r| if (r.code == 0 and r.output.contains("\"status\":\"passed\"")) [] else ["native soak ${s.example} ${s.spec}: ${r.output.trim()}"]).join())
	}

	## Every fuzz target's examples, every app's native soak, then every
	## app's browser soak.
	soak! : SpecSuite.Options => Try(List(Str), _)
	soak! = |o| {
		Checks.prepare_platform!(o)?
		SpecSuite.build_web_platform!(o)?
		Proc.note!("== fuzz targets")
		var $problems = Targets.fuzz_check_all!(o, Targets.fuzz_targets)?
		Proc.note!("== native soaks")
		$problems = $problems.concat(Slow.native_soak!(o)?)
		SpecSuite.build_with!(o, [], Slow.browser_soak_apps, "size")?
		for example in Slow.browser_soak_apps {
			Proc.note!("== browser soak ${example}")
			$problems = $problems.concat(Targets.browser_soak!(o, example, SpecSuite.wasm_of(o, example))?)
		}
		Ok($problems)
	}

	finish! : Str, List(Str) => Try({}, [Exit(I32)])
	finish! = |task, problems|
		if problems.is_empty() {
			Proc.note!("${task}: passed")
			Ok({})
		} else {
			for p in problems {
				Proc.warn!("FAIL ${p}")
			}
			Err(Exit(1))
		}
}
