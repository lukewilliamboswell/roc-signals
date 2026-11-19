import Proc
import Targets

## Which registered fuzz targets a run builds and runs, and the account it
## gives of every one of them afterwards.
##
## A target is never left out silently. A run starts from a plan that puts
## every registered target either in its list to run or in its list to
## skip, with the reason, and the only reasons a plan can hold are the ones
## `contributing.md` sanctions: the person named other targets, the target
## belongs to a suite in another shard of CI's Fuzz smoke job, or the run was told its
## targets are replayed elsewhere. After the run, `account` prints a `SKIP`
## line for each skipped target and one accounting line, and turns anything
## the plan does not explain (a target to run without exactly one result, a
## result for a target the plan did not run, a registry the plan does not
## cover) into a problem that fails the task.
FuzzPlan := [].{

	## Why a registered target is not run by this run.
	Skip : [NotNamed, OtherShard(Shard), Elsewhere(Str)]

	## One of `total` disjoint sets of suites, numbered from 1.
	Shard : { index : U64, total : U64 }

	## What a run was asked to run: every target, those named, one shard of
	## the registry, or none, with the reason they run elsewhere.
	Selection : [Every, Named(List(Str)), InShard(Shard), Elsewhere(Str)]

	## The targets a run runs, in registry order, and those it skips.
	Plan : { run : List(Targets.Fuzz), skip : List({ name : Str, reason : Skip }) }

	## What running one target found: no problems when it built and passed.
	Outcome : { name : Str, problems : List(Str) }

	## Plan a selection over a registry. A name that is not registered, a
	## shard that is not one of its total, and a shard that receives no
	## target are refused: each would otherwise run less than it says.
	plan : List(Targets.Fuzz), Selection -> Try(Plan, [NothingRegistered, UnknownTarget(Str), NoSuchShard(Shard), EmptyShard(Shard)])
	plan = |registry, selection| {
		if registry.is_empty() {
			return Err(NothingRegistered)
		}
		match selection {
			Every => Ok({ run: registry, skip: [] })
			Named(names) => {
				for name in names {
					if !registry.any(|target| target.name == name) {
						return Err(UnknownTarget(name))
					}
				}
				Ok({
					run: registry.keep_if(|target| names.contains(target.name)),
					skip: registry.drop_if(|target| names.contains(target.name)).map(|target| { name: target.name, reason: NotNamed }),
				})
			}
			InShard(shard) => {
				if shard.total == 0 or shard.index == 0 or shard.index > shard.total {
					return Err(NoSuchShard(shard))
				}
				var $run = []
				var $skip = []
				suites = Targets.suite_builds(registry)
				for target in registry {
					position = suites.find_first_index(|suite| suite.main == target.suite) ?? crash "fuzz shard missing suite"
					owner = position % shard.total + 1
					if owner == shard.index {
						$run = $run.append(target)
					} else {
						$skip = $skip.append({ name: target.name, reason: OtherShard({ index: owner, total: shard.total }) })
					}
				}
				if $run.is_empty() {
					return Err(EmptyShard(shard))
				}
				Ok({ run: $run, skip: $skip })
			}
			Elsewhere(reason) => Ok({ run: [], skip: registry.map(|target| { name: target.name, reason: Elsewhere(reason) }) })
		}
	}

	## A refused plan, as the problem that fails the task.
	refusal : [NothingRegistered, UnknownTarget(Str), NoSuchShard(Shard), EmptyShard(Shard)] -> Str
	refusal = |error| match error {
		NothingRegistered => "fuzz: Targets.fuzz_targets registers no target"
		UnknownTarget(name) => "fuzz: ${name} is not a registered target"
		NoSuchShard({ index, total }) => "fuzz: shard ${index.to_str()}/${total.to_str()} is not one of ${total.to_str()} shards numbered from 1"
		EmptyShard({ index, total }) => "fuzz: shard ${index.to_str()}/${total.to_str()} receives no target; use at most as many shards as there are suites"
	}

	## Parse `K/N`, shard K of N.
	parse_shard : Str -> Try(Shard, [BadShard(Str)])
	parse_shard = |text| match text.split_on("/") {
		[index, total] => match (U64.from_str(index), U64.from_str(total)) {
			(Ok(i), Ok(t)) => Ok({ index: i, total: t })
			_ => Err(BadShard(text))
		}
		_ => Err(BadShard(text))
	}

	## Why a skipped target is not run, as its `SKIP` line says.
	reason_text : Skip -> Str
	reason_text = |reason| match reason {
		NotNamed => "not named on the command line"
		OtherShard({ index, total }) => "shard ${index.to_str()}/${total.to_str()} runs it"
		Elsewhere(why) => why
	}

	## Account for a run: its `SKIP` lines and accounting line, and the
	## problems that fail it. Every registered target is run or skipped
	## exactly once, every target run has exactly one outcome, and the
	## problems are the outcomes' own followed by any the account found.
	account : List(Targets.Fuzz), Plan, List(Outcome) -> { lines : List(Str), problems : List(Str) }
	account = |registry, { run, skip }, outcomes| {
		var $problems = []
		for target in run {
			count = outcomes.keep_if(|outcome| outcome.name == target.name).len()
			if count != 1 {
				$problems = $problems.append("fuzz ${target.name}: selected to run, but the run recorded ${count.to_str()} results for it")
			}
		}
		for outcome in outcomes {
			if !run.any(|target| target.name == outcome.name) {
				$problems = $problems.append("fuzz ${outcome.name}: a result for a target this run did not select")
			}
		}
		for target in registry {
			placed = run.keep_if(|t| t.name == target.name).len() + skip.keep_if(|s| s.name == target.name).len()
			if placed != 1 {
				$problems = $problems.append("fuzz ${target.name}: registered, but the run placed it ${placed.to_str()} times among the targets it runs and skips")
			}
		}
		ran = run.len()
		skipped = skip.len()
		if ran + skipped != registry.len() {
			$problems = $problems.append("fuzz: ${ran.to_str()} ran and ${skipped.to_str()} skipped do not account for ${registry.len().to_str()} registered targets")
		}
		failed = outcomes.keep_if(|outcome| !outcome.problems.is_empty()).len()
		passed = outcomes.len() - failed
		lines = skip.map(|s| "SKIP ${s.name}: ${FuzzPlan.reason_text(s.reason)}").append("fuzz: ${registry.len().to_str()} targets: ${ran.to_str()} ran (${passed.to_str()} passed, ${failed.to_str()} failed), ${skipped.to_str()} skipped")
		{ lines, problems: outcomes.map(|outcome| outcome.problems).join().concat($problems) }
	}

	## Plan a selection, run it with `run!`, and print and return its
	## account. A refused plan is the run's one problem.
	run! : List(Targets.Fuzz), Selection, (List(Targets.Fuzz) => Try(List(Outcome), e)) => Try(List(Str), e)
	run! = |registry, selection, runner!| {
		match FuzzPlan.plan(registry, selection) {
			Err(error) => Ok([FuzzPlan.refusal(error)])
			Ok(planned) => {
				outcomes = if (planned.run.is_empty()) [] else runner!(planned.run)?
				{ lines, problems } = FuzzPlan.account(registry, planned, outcomes)
				for line in lines {
					Proc.note!(line)
				}
				Ok(problems)
			}
		}
	}
}

registry_of : List(Str) -> List(Targets.Fuzz)
registry_of = |names| names.map(|name| { name, main: "fuzz/${name}/main.roc", property: "fuzz/${name}/Property.roc", suite: "fuzz/${name}/main.roc" })

passed : List(Str) -> List(FuzzPlan.Outcome)
passed = |names| names.map(|name| { name, problems: [] })

## Every target runs by default, and the account says so.
expect {
	registry = registry_of(["a", "b", "c"])
	match FuzzPlan.plan(registry, Every) {
		Ok(p) => FuzzPlan.account(registry, p, passed(["a", "b", "c"])) == { lines: ["fuzz: 3 targets: 3 ran (3 passed, 0 failed), 0 skipped"], problems: [] }
		Err(_) => Bool.False
	}
}

## Named targets run in registry order; the rest are skipped with a reason.
expect {
	registry = registry_of(["a", "b", "c"])
	match FuzzPlan.plan(registry, Named(["c", "a", "c"])) {
		Ok(p) => p.run.map(|t| t.name) == ["a", "c"] and FuzzPlan.account(registry, p, passed(["a", "c"])).lines == ["SKIP b: not named on the command line", "fuzz: 3 targets: 2 ran (2 passed, 0 failed), 1 skipped"]
		Err(_) => Bool.False
	}
}

## A name that is not registered is refused, not ignored.
expect FuzzPlan.plan(registry_of(["a"]), Named(["z"])) == Err(UnknownTarget("z"))

## An empty registry is refused rather than passing with nothing run.
expect FuzzPlan.plan([], Every) == Err(NothingRegistered)

## For every shard count up to the registry's size, the shards are disjoint
## and together run every registered target exactly once.
expect {
	registry = registry_of(["a", "b", "c", "d", "e", "f", "g"])
	var $ok = Bool.True
	for total in 1.U64..=registry.len() {
		var $all = []
		for index in 1.U64..=total {
			match FuzzPlan.plan(registry, InShard({ index, total })) {
				Ok(p) => {
					$all = $all.concat(p.run.map(|t| t.name))
				}
				Err(_) => {
					$ok = Bool.False
				}
			}
		}
		if $all.len() != registry.len() or !registry.all(|t| $all.contains(t.name)) {
			$ok = Bool.False
		}
	}
	$ok
}

## A shard's account names the shard that runs each target it skips.
expect {
	registry = registry_of(["a", "b", "c"])
	match FuzzPlan.plan(registry, InShard({ index: 2, total: 2 })) {
		Ok(p) => FuzzPlan.account(registry, p, passed(["b"])).lines == ["SKIP a: shard 1/2 runs it", "SKIP c: shard 1/2 runs it", "fuzz: 3 targets: 1 ran (1 passed, 0 failed), 2 skipped"]
		Err(_) => Bool.False
	}
}

## More shards than targets, and a shard outside its total, are refused.
expect FuzzPlan.plan(registry_of(["a", "b"]), InShard({ index: 3, total: 3 })) == Err(EmptyShard({ index: 3, total: 3 }))
expect FuzzPlan.plan(registry_of(["a", "b"]), InShard({ index: 0, total: 2 })) == Err(NoSuchShard({ index: 0, total: 2 }))
expect FuzzPlan.plan(registry_of(["a", "b"]), InShard({ index: 1, total: 0 })) == Err(NoSuchShard({ index: 1, total: 0 }))

## A shard is written K/N.
expect FuzzPlan.parse_shard("2/6") == Ok({ index: 2, total: 6 })
expect FuzzPlan.parse_shard("2") == Err(BadShard("2"))
expect FuzzPlan.parse_shard("a/6") == Err(BadShard("a/6"))

## Targets replayed elsewhere are each skipped with that reason.
expect {
	registry = registry_of(["a", "b"])
	match FuzzPlan.plan(registry, Elsewhere("CI replays them")) {
		Ok(p) => FuzzPlan.account(registry, p, []) == { lines: ["SKIP a: CI replays them", "SKIP b: CI replays them", "fuzz: 2 targets: 0 ran (0 passed, 0 failed), 2 skipped"], problems: [] }
		Err(_) => Bool.False
	}
}

## A target's own problems fail the run, and are counted as a failure.
expect {
	registry = registry_of(["a", "b"])
	outcomes = [{ name: "a", problems: ["fuzz a: replay failed"] }, { name: "b", problems: [] }]
	FuzzPlan.account(registry, { run: registry, skip: [] }, outcomes) == { lines: ["fuzz: 2 targets: 2 ran (1 passed, 1 failed), 0 skipped"], problems: ["fuzz a: replay failed"] }
}

## A selected target with no result, or two, fails the run: it was not
## shown to have run.
expect {
	registry = registry_of(["a", "b"])
	FuzzPlan.account(registry, { run: registry, skip: [] }, passed(["a", "a"])).problems == ["fuzz a: selected to run, but the run recorded 2 results for it", "fuzz b: selected to run, but the run recorded 0 results for it"]
}

## A result for a target the run did not select fails the run.
expect {
	registry = registry_of(["a", "b"])
	FuzzPlan.account(registry, { run: registry_of(["a"]), skip: [{ name: "b", reason: NotNamed }] }, passed(["a", "b"])).problems == ["fuzz b: a result for a target this run did not select"]
}

## A plan that leaves a registered target neither run nor skipped fails the
## run, as does one that both runs and skips a target.
expect {
	registry = registry_of(["a", "b", "c"])
	FuzzPlan.account(registry, { run: registry_of(["a"]), skip: [{ name: "a", reason: NotNamed }] }, passed(["a"])).problems
		== [
			"fuzz a: registered, but the run placed it 2 times among the targets it runs and skips",
			"fuzz b: registered, but the run placed it 0 times among the targets it runs and skips",
			"fuzz c: registered, but the run placed it 0 times among the targets it runs and skips",
			"fuzz: 1 ran and 1 skipped do not account for 3 registered targets",
		]
}

## Shared-build members stay together in a shard, so the CI shards compile
## every suite once while retaining one outcome and report per member.
expect {
	registry = [
		{ name: "a", main: "fuzz/a/main.roc", property: "fuzz/a/main.roc", suite: "One.roc" },
		{ name: "b", main: "fuzz/b/main.roc", property: "fuzz/b/main.roc", suite: "Two.roc" },
		{ name: "c", main: "fuzz/c/main.roc", property: "fuzz/c/main.roc", suite: "One.roc" },
	]
	match (FuzzPlan.plan(registry, InShard({ index: 1, total: 2 })), FuzzPlan.plan(registry, InShard({ index: 2, total: 2 }))) {
		(Ok(first), Ok(second)) => first.run.map(|member| member.name) == ["a", "c"] and second.run.map(|member| member.name) == ["b"]
		_ => False
	}
}
