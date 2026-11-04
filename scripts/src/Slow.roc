import Checks
import Mutations
import Proc
import SpecSuite
import Targets

## The slow suites: soak and the engine mutation gate.
Slow := [].{

	## Every fuzz target against its baseline, then every app's browser soak.
	soak! : SpecSuite.Options => Try(List(Str), _)
	soak! = |o| {
		Checks.prepare_platform!(o)?
		SpecSuite.build_web_platform!(o)?
		var $problems = []
		for t in Targets.fuzz_targets {
			Proc.note!("== fuzz ${t.name}")
			exe = Targets.build_fuzz!(o, t)?
			$problems = $problems.concat(Targets.fuzz_check!(o, t, exe)?)
		}
		for example in SpecSuite.apps {
			Proc.note!("== browser soak ${example}")
			wasm = SpecSuite.build_wasm!(o, example)?
			$problems = $problems.concat(Targets.browser_soak!(o, example, wasm)?)
		}
		Ok($problems)
	}

	mutate! : SpecSuite.Options, Str => Try(List(Str), _)
	mutate! = |o, only| {
		Checks.prepare_platform!(o)?
		Mutations.run!(o, only)
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
