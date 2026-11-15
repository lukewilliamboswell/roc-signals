import SpecSuite

## Which stages of `check` a run runs, and for which apps.
##
## With no selection `check` runs the whole gate in one go, as a
## contributor runs it. CI runs the same gate as `CheckPlan.parts` parallel
## legs, each `check -- --part K/N`: every stage belongs to exactly one part,
## or is a per-app stage that every part runs for its own share of the apps
## (`SpecSuite.spec_apps`, dealt round-robin), so the legs together run
## every stage, and every per-app stage for every app, exactly once. A leg
## prints a `SKIP` line for each stage another part runs, and a leg whose
## selection would be empty is refused. A stage that needs another's
## output builds it in its own leg: before its first stage that needs
## builds, a run builds, in one bounded batch, the native runners and
## browser builds of its apps and those its other stages name in `needs`
## (so a part may build an app another part also builds; the whole gate
## builds each once).
CheckPlan := [].{

	## Where a stage runs when the gate is split: in one part, or in every
	## part for that part's apps.
	Placement : [Part(U64), PerApp]

	## A stage of `check`, by the name `check_all.roc` runs it under.
	Stage : { name : Str, placement : Placement }

	## How many parts CI splits the gate into. CI's Check matrix has one leg
	## for each, and a `--part K/N` whose N differs is refused.
	parts : U64
	parts = 5

	## The stages, in the order `check` runs them, and where each runs.
	## Part 1 holds the checks of the tree and the `expect`s; part 2 the
	## platform's inputs and the key contracts; part 3 the docs samples and
	## the js-framework-benchmark; part 4 the runtime's contract tests and
	## the stages beside them; part 5 the release dry run and the tool,
	## which runs from the dry run's copy. Each part also runs every
	## per-app stage for its share of the apps.
	stages : List(Stage)
	stages = [
		{ name: "script pins", placement: Part(1) },
		{ name: "file names", placement: Part(1) },
		{ name: "script modes", placement: Part(1) },
		{ name: "formatting", placement: Part(1) },
		{ name: "example files", placement: Part(1) },
		{ name: "fuzz target registry", placement: Part(1) },
		{ name: "spec lists", placement: Part(1) },
		{ name: "platform JavaScript sizes", placement: Part(1) },
		{ name: "platform packages", placement: Part(1) },
		{ name: "API docs", placement: Part(1) },
		{ name: "platform expects", placement: Part(1) },
		{ name: "app expects", placement: Part(1) },
		{ name: "declaration type fixtures", placement: Part(1) },
		{ name: "fuzz expects", placement: Part(1) },
		{ name: "tool bundle", placement: Part(1) },
		{ name: "script expects", placement: Part(1) },
		{ name: "key contracts", placement: Part(2) },
		{ name: "host tests", placement: Part(2) },
		{ name: "cross links", placement: Part(2) },
		{ name: "fuzz targets", placement: Part(1) },
		{ name: "docs samples", placement: Part(3) },
		{ name: "debug file sizes", placement: Part(3) },
		{ name: "example sizes", placement: PerApp },
		{ name: "specs", placement: PerApp },
		{ name: "native lifetime contracts", placement: Part(4) },
		{ name: "short walks", placement: PerApp },
		{ name: "grammar coverage", placement: Part(4) },
		{ name: "broken-spec self-check", placement: PerApp },
		{ name: "declaration refusals", placement: Part(4) },
		{ name: "runtime unit tests", placement: Part(4) },
		{ name: "runtime contracts in Chrome", placement: Part(4) },
		{ name: "js-framework-benchmark", placement: Part(3) },
		{ name: "release dry run", placement: Part(5) },
		{ name: "signals.roc", placement: Part(5) },
	]

	## The builds of `SpecSuite.build!` a stage uses beyond its part's own
	## apps': app names for native runners and for browser builds
	## (`tests/apps/NAME` for a test app no list names). The per-app stages
	## use their apps' builds; a stage not named here makes what it needs
	## itself, or nothing.
	needs : Str -> { natives : List(Str), webs : List(Str) }
	needs = |stage| match stage {
		"native lifetime contracts" => { natives: ["files", "dbg"], webs: [] }
		"grammar coverage" => { natives: ["kanban-board"], webs: [] }
		"runtime contracts in Chrome" => {
			natives: ["controls", "table", "services", "prerender"],
			webs: ["tests/apps/effects", "controls", "services", "workers", "files", "file-effects", "ports", "markup", "construction", "table", "outbox", "dbg", "dbg-job-only", "worker-lab", "prepared", "tasks", "deep-payload", "reading-list", "status-page", "log-explorer", "million-row-explorer", "conduit", "prerender"],
		}
		"release dry run" => { natives: [], webs: SpecSuite.apps }
		_ => { natives: [], webs: [] }
	}

	## The stages that need what another stage made in the same run: the
	## tool runs from the release dry run's copy, so they share a part.
	together : List((Str, Str))
	together = [("signals.roc", "release dry run")]

	## What a run was asked for: the whole gate, or one part of it.
	Selection : [Whole, OnePart({ index : U64, total : U64 })]

	## What a run runs: the stages, in order; the apps its per-app stages
	## run for; and each stage it skips, with the part that runs it.
	Plan : { label : Str, stages : List(Str), apps : List(Str), skip : List({ name : Str, part : U64 }) }

	## Why a selection cannot be planned.
	Refusal : [NoSuchPart({ index : U64, total : U64 }), WrongTotal({ index : U64, total : U64 }), EmptyPart(U64)]

	## Plan a selection over `stages`, `parts` parts and the apps `apps`. A
	## part outside its total, a total other than `parts` (the stages are
	## placed for exactly that many), and a part that would run nothing
	## are refused.
	plan : List(Stage), U64, List(Str), Selection -> Try(Plan, Refusal)
	plan = |all, count, apps, selection| match selection {
		Whole => Ok({ label: "check", stages: all.map(|s| s.name), apps, skip: [] })
		OnePart({ index, total }) => {
			if total == 0 or index == 0 or index > total {
				return Err(NoSuchPart({ index, total }))
			}
			if total != count {
				return Err(WrongTotal({ index, total }))
			}
			placed_here = |s| match s.placement {
				Part(k) => k == index
				PerApp => Bool.True
			}
			mine = apps.map_with_index(|name, position| (name, position)).keep_if(|(_, position)| position % total + 1 == index).map(|(name, _)| name)
			chosen = all.keep_if(placed_here).map(|s| s.name)
			has_own = all.any(|s| s.placement == Part(index))
			if !has_own and mine.is_empty() {
				return Err(EmptyPart(index))
			}
			skip = all.keep_oks(
				|s| match s.placement {
					Part(k) if k != index => Ok({ name: s.name, part: k })
					_ => Err(Runs)
				},
			)
			Ok({ label: "check part ${index.to_str()}/${total.to_str()}", stages: chosen, apps: mine, skip })
		}
	}

	## A refused plan, as the problem that fails the run.
	refusal : Refusal -> Str
	refusal = |error| match error {
		NoSuchPart({ index, total }) => "check: part ${index.to_str()}/${total.to_str()} is not one of ${total.to_str()} parts numbered from 1"
		WrongTotal({ index, total }) => "check: part ${index.to_str()}/${total.to_str()} names ${total.to_str()} parts, but CheckPlan.stages are placed in ${CheckPlan.parts.to_str()}; run --part K/${CheckPlan.parts.to_str()}"
		EmptyPart(index) => "check: part ${index.to_str()} would run no stage and no app"
	}

	## Parse `K/N`, part K of N.
	parse_part : Str -> Try({ index : U64, total : U64 }, [BadPart(Str)])
	parse_part = |text| match text.split_on("/") {
		[index, total] => match (U64.from_str(index), U64.from_str(total)) {
			(Ok(i), Ok(t)) => Ok({ index: i, total: t })
			_ => Err(BadPart(text))
		}
		_ => Err(BadPart(text))
	}

	## Whether a plan runs a stage.
	runs : Plan, Str -> Bool
	runs = |p, stage| p.stages.contains(stage)

	## The line a run prints for a stage another part runs.
	skip_line : { name : Str, part : U64 } -> Str
	skip_line = |{ name, part }| "SKIP ${name}: part ${part.to_str()}/${CheckPlan.parts.to_str()} runs it"

	## The builds a plan's stages use, each named once (two jobs writing one
	## build would race): the native runner and browser build of each of its
	## apps when it runs the per-app stages (whose specs, walks and broken
	## specs use them), then those its other stages need. Empty when it
	## runs no stage that needs builds.
	builds : Plan -> { natives : List(Str), webs : List(Str) }
	builds = |p| {
		own = if (CheckPlan.runs(p, "specs")) p.apps else []
		extra = p.stages.map(CheckPlan.needs)
		{
			natives: dedup(own.concat(extra.map(|n| n.natives).join())),
			webs: dedup(own.concat(extra.map(|n| n.webs).join())),
		}
	}

	## What `check -- --plan` prints: for each part, the stages it runs
	## and the apps its per-app stages run for; then the per-app stages.
	describe : List(Stage), U64, List(Str) -> List(Str)
	describe = |all, count, apps| {
		per_app = all.keep_if(|s| s.placement == PerApp).map(|s| s.name)
		var $lines = ["check runs ${all.len().to_str()} stages; CI runs them as ${count.to_str()} parts (check -- --part K/${count.to_str()})", "every part runs the per-app stages for its own apps: ${Str.join_with(per_app, ", ")}"]
		for index in 1.U64..=count {
			match CheckPlan.plan(all, count, apps, OnePart({ index, total: count })) {
				Ok(p) => {
					own = all.keep_if(|s| s.placement == Part(index)).map(|s| s.name)
					made = CheckPlan.builds(p)
					$lines = $lines
						.append("part ${index.to_str()}/${count.to_str()}: ${Str.join_with(own, ", ")}")
						.append("  apps (${p.apps.len().to_str()}): ${Str.join_with(p.apps, ", ")}")
						.append("  builds: ${made.natives.len().to_str()} native runners, ${made.webs.len().to_str()} browser builds")
				}
				Err(error) => {
					$lines = $lines.append(CheckPlan.refusal(error))
				}
			}
		}
		$lines
	}

	## What is wrong between the stages `check` reached (`called`, in the
	## order it reached them, whether the plan ran them or not) and the
	## stages placed: a placed stage it never reached would run in no
	## part, a reached stage that is not placed would run in every part,
	## and either order differing means the list no longer says what runs.
	called_problems : List(Stage), List(Str) -> List(Str)
	called_problems = |all, called| {
		names = all.map(|s| s.name)
		if called == names {
			[]
		} else {
			missing = names.drop_if(|name| called.contains(name)).map(|name| "check never reaches the stage ${name} that CheckPlan.stages places")
			unplaced = called.drop_if(|name| names.contains(name)).map(|name| "check runs the stage ${name}, which CheckPlan.stages does not place")
			found = missing.concat(unplaced)
			if (found == []) ["check reaches its stages in another order, or more than once, than CheckPlan.stages lists them"] else found
		}
	}

	## Every way the placement is wrong: a stage named twice, a part outside
	## `1..count`, a part with no stage of its own, and stages that must
	## share a part placed apart (or not placed at all).
	placement_problems : List(Stage), U64, List((Str, Str)) -> List(Str)
	placement_problems = |all, count, pairs| {
		names = all.map(|s| s.name)
		twice = dedup(names.keep_if(|name| names.keep_if(|n| n == name).len() > 1)).map(|name| "check stage ${name} is placed more than once")
		outside = all.keep_oks(
			|s| match s.placement {
				Part(k) if k == 0 or k > count => Ok("check stage ${s.name} is placed in part ${k.to_str()}, outside 1..${count.to_str()}")
				_ => Err(Inside)
			},
		)
		var $empty = []
		for index in 1.U64..=count {
			if !all.any(|s| s.placement == Part(index)) {
				$empty = $empty.append("check part ${index.to_str()} has no stage of its own")
			}
		}
		apart = pairs.keep_oks(
			|(a, b)| match (all.find_first(|s| s.name == a), all.find_first(|s| s.name == b)) {
				(Ok(x), Ok(y)) if x.placement == y.placement => Err(Together)
				_ => Ok("check stages ${a} and ${b} must run in one part")
			},
		)
		twice.concat(outside).concat($empty).concat(apart)
	}
}

dedup : List(Str) -> List(Str)
dedup = |items| items.fold([], |seen, item| if (seen.contains(item)) seen else seen.append(item))

## The stages as placed: each once, in parts 1..parts, every part with a
## stage of its own, and the tool beside the release dry run.
expect CheckPlan.placement_problems(CheckPlan.stages, CheckPlan.parts, CheckPlan.together) == []

## Each placement fault is reported.
expect {
	bad = [{ name: "a", placement: Part(1) }, { name: "a", placement: Part(3) }, { name: "b", placement: PerApp }, { name: "c", placement: Part(1) }]
	CheckPlan.placement_problems(bad, 2, [("b", "c")])
		== [
			"check stage a is placed more than once",
			"check stage a is placed in part 3, outside 1..2",
			"check part 2 has no stage of its own",
			"check stages b and c must run in one part",
		]
}

## Over all the parts, every stage that is not per-app runs in exactly one
## part, every per-app stage runs in every part, every app lands in exactly
## one part, and every other part prints a SKIP for each stage it does not
## run.
expect {
	apps = SpecSuite.spec_apps
	var $ok = Bool.True
	var $stages = []
	var $apps = []
	for index in 1.U64..=CheckPlan.parts {
		match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, apps, OnePart({ index, total: CheckPlan.parts })) {
			Ok(p) => {
				$stages = $stages.concat(p.stages)
				$apps = $apps.concat(p.apps)
				if p.stages.len() + p.skip.len() != CheckPlan.stages.len() {
					$ok = Bool.False
				}
			}
			Err(_) => {
				$ok = Bool.False
			}
		}
	}
	per_app = CheckPlan.stages.keep_if(|s| s.placement == PerApp).map(|s| s.name)
	each_once = CheckPlan.stages.all(
		|s| {
			times = $stages.keep_if(|name| name == s.name).len()
			if (per_app.contains(s.name)) times == CheckPlan.parts else times == 1
		},
	)
	apps_once = apps.all(|name| $apps.keep_if(|a| a == name).len() == 1) and $apps.len() == apps.len()
	$ok and each_once and apps_once
}

## With no selection the run is the whole gate: every stage, every app,
## nothing skipped, and every spec-bearing app built for both runners.
expect {
	match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, Whole) {
		Ok(p) => {
			b = CheckPlan.builds(p)
			p.stages == CheckPlan.stages.map(|s| s.name) and p.apps == SpecSuite.spec_apps and p.skip == [] and SpecSuite.spec_apps.all(|a| b.natives.contains(a) and b.webs.contains(a)) and b.webs.contains("tests/apps/effects")
		}
		Err(_) => Bool.False
	}
}

## A part outside its total, a total the stages are not placed for, and a
## part that would run nothing are refused.
expect {
	one = [{ name: "a", placement: Part(1) }, { name: "b", placement: PerApp }]
	(
		CheckPlan.plan(one, 2, ["x"], OnePart({ index: 3, total: 2 })),
		CheckPlan.plan(one, 2, ["x"], OnePart({ index: 1, total: 3 })),
		CheckPlan.plan(one, 2, ["x"], OnePart({ index: 2, total: 2 })),
	)
		== (Err(NoSuchPart({ index: 3, total: 2 })), Err(WrongTotal({ index: 1, total: 3 })), Err(EmptyPart(2)))
}

## A part runs its own stages and the per-app ones for its apps, and skips
## the rest naming the part that runs each; its builds are its apps' and
## what its stages need, each once.
expect {
	all = [{ name: "a", placement: Part(1) }, { name: "specs", placement: PerApp }, { name: "grammar coverage", placement: Part(2) }]
	match CheckPlan.plan(all, 2, ["x", "y", "kanban-board"], OnePart({ index: 2, total: 2 })) {
		Ok(p) => p.stages == ["specs", "grammar coverage"] and p.apps == ["y"] and p.skip == [{ name: "a", part: 1 }] and CheckPlan.builds(p) == { natives: ["y", "kanban-board"], webs: ["y"] } and CheckPlan.skip_line({ name: "a", part: 1 }) == "SKIP a: part 1/${CheckPlan.parts.to_str()} runs it"
		Err(_) => Bool.False
	}
}

## A part is written K/N.
expect (CheckPlan.parse_part("2/5"), CheckPlan.parse_part("2"), CheckPlan.parse_part("a/5")) == (Ok({ index: 2, total: 5 }), Err(BadPart("2")), Err(BadPart("a/5")))

## The stages `check` reached must be exactly the placed ones, in order.
expect {
	all = [{ name: "a", placement: Part(1) }, { name: "b", placement: PerApp }]
	(CheckPlan.called_problems(all, ["a", "b"]), CheckPlan.called_problems(all, ["a", "c"]), CheckPlan.called_problems(all, ["b", "a"]))
		== ([], ["check never reaches the stage b that CheckPlan.stages places", "check runs the stage c, which CheckPlan.stages does not place"], ["check reaches its stages in another order, or more than once, than CheckPlan.stages lists them"])
}
