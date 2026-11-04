import Checks
import Proc
import SpecSuite
import Targets

## The slow suite: soak.
Slow := [].{

	## Every fuzz target against its baseline, then every app's browser soak.
	soak! : SpecSuite.Options => Try(List(Str), _)
	soak! = |o| {
		Checks.prepare_platform!(o)?
		SpecSuite.build_web_platform!(o)?
		Proc.note!("== fuzz targets against their baselines")
		var $problems = Targets.fuzz_check_all!(o, Targets.fuzz_targets)?
		SpecSuite.build_with!(o, [], SpecSuite.apps, "size")?
		for example in SpecSuite.apps {
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
