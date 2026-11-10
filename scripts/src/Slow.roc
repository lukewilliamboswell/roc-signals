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

	## Every fuzz target's examples, then every app's browser soak.
	soak! : SpecSuite.Options => Try(List(Str), _)
	soak! = |o| {
		Checks.prepare_platform!(o)?
		SpecSuite.build_web_platform!(o)?
		Proc.note!("== fuzz targets")
		var $problems = Targets.fuzz_check_all!(o, Targets.fuzz_targets)?
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
