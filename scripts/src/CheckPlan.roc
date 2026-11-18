import SpecSuite

## Which stages of `check` a run runs, for which apps, and what it builds.
##
## With no selection `check` runs the whole gate in one go, as a
## contributor runs it. CI runs the same gate as `CheckPlan.parts` parallel
## legs, each `check -- --part K/N`: every stage belongs to exactly one part,
## or is a per-app stage that every part runs for its own share of the apps
## (`SpecSuite.spec_apps`), so the legs together run every stage, and every
## per-app stage for every app, exactly once. A leg prints a `SKIP` line for
## each stage another part runs, and a leg whose selection would be empty is
## refused.
##
## Apps are dealt by need: an app a part's own stages use (`needs`: the
## Chrome contracts' test apps, the examples the release dry run and the
## journeys load) belongs to that part, so its builds are made once, there,
## and its specs run beside the stages that use them; the rest are dealt
## round-robin among `spare_parts`. Before its first stage that needs
## builds, a run makes, in one bounded batch, the native runners and browser
## builds of its apps and of what its stages need. `builds_made` is every
## build a run makes, as (root, target, opt) with the stages that use it,
## and its `expect`s hold the whole gate to building each once and the
## parts to repeating none of another part's.
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
	## Part 1 holds the checks of the tree, the `expect`s and the examples'
	## shipping sizes (13 `--opt=size` builds); part 2 the platform's inputs
	## and the key contracts; part 3 the docs samples and the
	## js-framework-benchmark; part 4 the runtime's
	## contract tests on the test apps and the stages beside them; part 5 the
	## examples' journeys, the release dry run and the tool, which runs from
	## the dry run's copy. Each part also runs every per-app stage for its
	## own apps.
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
		{ name: "example sizes", placement: Part(1) },
		{ name: "specs", placement: PerApp },
		{ name: "native lifetime contracts", placement: Part(4) },
		{ name: "short walks", placement: PerApp },
		{ name: "grammar coverage", placement: Part(5) },
		{ name: "broken-spec self-check", placement: PerApp },
		{ name: "declaration refusals", placement: Part(4) },
		{ name: "runtime unit tests", placement: Part(4) },
		{ name: "runtime contracts in Chrome", placement: Part(4) },
		{ name: "example journeys in Chrome", placement: Part(5) },
		{ name: "js-framework-benchmark", placement: Part(3) },
		{ name: "release dry run", placement: Part(5) },
		{ name: "signals.roc", placement: Part(5) },
	]

	## The parts that take the apps no part's own stages need, dealt
	## round-robin: the parts whose own stages build least.
	spare_parts : List(U64)
	spare_parts = [1, 2]

	## The builds of the shared batch (`SpecSuite.build_all!`) a stage uses
	## beyond the per-app stages': app names for native runners, for
	## development browser builds and for shipping (`--opt=size`) browser
	## builds (`tests/apps/NAME` for a test app no list names). A stage not named
	## here makes what it needs itself (`own_builds`), or nothing.
	needs : Str -> { natives : List(Str), webs : List(Str), sized : List(Str) }
	needs = |stage| match stage {
		"native lifetime contracts" => { natives: ["files", "dbg"], webs: [], sized: [] }
		"grammar coverage" => { natives: ["kanban-board"], webs: [], sized: [] }
		"runtime contracts in Chrome" => {
			natives: ["unsafe-html", "controls", "table", "services", "prerender", "startup-corpus"],
			webs: ["unsafe-html", "tests/apps/effects", "controls", "services", "workers", "files", "file-effects", "ports", "markup", "description-preparation", "startup", "startup-corpus", "startup-queue", "construction", "table", "outbox", "dbg", "dbg-job-only", "prepared", "tasks", "deep-payload", "prerender", "crypto"],
			sized: ["startup-queue"],
		}
		"runtime unit tests" => { natives: [], webs: ["write-scaling"], sized: ["write-scaling"] }
		"example journeys in Chrome" => { natives: [], webs: ["worker-lab", "reading-list", "status-page", "log-explorer", "million-row-explorer", "conduit"], sized: [] }
		"release dry run" => { natives: [], webs: SpecSuite.apps, sized: [] }
		_ => { natives: [], webs: [], sized: [] }
	}

	## One build: a root, the system it is built for (`native` is the native
	## spec runners' target, `x64musl` in the gate; `host` the system the
	## gate runs on) and the optimisation level.
	Build : { root : Str, target : Str, opt : Str }

	## The inputs of a run's builds the tree holds rather than the scripts:
	## the docs sample directories with specs, the catalogue's examples, and
	## the apps with a spec a compiler-keyed skip moves to an `--opt=size`
	## build (`CompilerSkips`), on a compiler the skip names.
	Inputs : { samples : List(Str), catalog : List(Str), size_specs : List(Str) }

	## The builds a stage makes itself, outside the shared batch.
	own_builds : Str, Inputs -> List(Build)
	own_builds = |stage, inputs| match stage {
		"key contracts" => [
			{ root: "tests/apps/key-contracts/main.roc", target: "native", opt: "dev" },
			{ root: "tests/apps/key-contracts/main.roc", target: "wasm32", opt: "dev" },
			{ root: "tests/key-contracts/oracle.roc.txt", target: "native", opt: "dev" },
		]
		"cross links" => ["arm64mac", "x64mac", "x64win"].map(|target| { root: "tests/apps/tasks/main.roc", target, opt: "dev" })
		"docs samples" => inputs.samples.map(|dir| [{ root: "${dir}/main.roc", target: "native", opt: "dev" }, { root: "${dir}/main.roc", target: "wasm32", opt: "dev" }]).join()
		"example sizes" => inputs.catalog.map(|slug| { root: "examples/${slug}/main.roc", target: "wasm32", opt: "size" })
		"declaration refusals" => [{ root: "tests/fixtures/declarations/main.roc", target: "native", opt: "dev" }]
		"runtime contracts in Chrome" => [
			{ root: "scripts/unicode_symbols.roc", target: "host", opt: "dev" },
			{ root: "tests/key-contracts/picture-path-no-init.roc.txt", target: "native", opt: "dev" },
		]
		"js-framework-benchmark" => [{ root: "benchmarks/js-framework-benchmark/roc-signals-keyed/app/main.roc", target: "wasm32", opt: "dev" }]
		_ => []
	}

	## Every build a plan makes, each with the stages that use it, in the
	## order of the stages; a build made by two stages, or twice by one,
	## appears once for each time it is made. The shared batch's builds are
	## made once, for the per-app stages and the `needs` of the plan's
	## stages. `signals.roc`'s builds are the tool's own (it compiles its
	## apps as an author's `build` and `test` do, which is what it checks),
	## so they are not the gate's to share and are not listed.
	builds_made : Plan, Inputs -> List({ build : Build, used_by : List(Str) })
	builds_made = |p, inputs| {
		made = CheckPlan.builds(p, inputs.size_specs)
		users = |name, kind| {
			own = if (CheckPlan.runs(p, "specs") and p.apps.contains(name)) ["specs"] else []
			needed = p.stages.keep_if(
				|stage| {
					n = CheckPlan.needs(stage)
					match kind {
						Native => n.natives.contains(name)
						Web => n.webs.contains(name)
						Sized => n.sized.contains(name)
					}
				},
			)
			mine = match kind {
				Sized => if (inputs.size_specs.contains(name) and own != []) own else []
				_ => own
			}
			mine.concat(needed)
		}
		root_of = |name| if (name.starts_with("tests/apps/")) "${name}/main.roc" else "${SpecSuite.dir_of(name)}/main.roc"
		batch = made.natives.map(|name| { build: { root: root_of(name), target: "native", opt: "dev" }, used_by: users(name, Native) })
			.concat(made.webs.map(|name| { build: { root: root_of(name), target: "wasm32", opt: "dev" }, used_by: users(name, Web) }))
		sized = made.sized.map(|name| { build: { root: root_of(name), target: "wasm32", opt: "size" }, used_by: users(name, Sized) })
		own = p.stages.map(|stage| CheckPlan.own_builds(stage, inputs).map(|build| { build, used_by: [stage] })).join()
		batch.concat(sized).concat(own)
	}

	## The builds `made` holds more than once, each named once.
	repeated : List({ build : Build, used_by : List(Str) }) -> List(Build)
	repeated = |made| {
		listed = made.map(|m| m.build)
		listed.fold([], |seen, b| if (!seen.contains(b) and listed.keep_if(|x| x == b).len() > 1) seen.append(b) else seen)
	}

	## The apps two parts' own stages both need: each would be built in both
	## parts, so dealing by need cannot place it once.
	contested : List(Stage), List(Str) -> List({ name : Str, parts : List(U64) })
	contested = |all, apps| apps.keep_oks(
		|name| {
			wanted = needing(all, name)
			if (wanted.len() > 1) Ok({ name, parts: wanted }) else Err(Uncontested)
		},
	)

	## Which part each app belongs to: the one part whose own stages need
	## it, or, for an app no part's stages need, the next of `spare_parts`
	## in turn.
	deal : List(Stage), List(Str) -> List({ name : Str, part : U64 })
	deal = |all, apps| {
		var $free = 0.U64
		var $out = []
		for name in apps {
			match needing(all, name) {
				[part, ..] => {
					$out = $out.append({ name, part })
				}
				[] => {
					part = CheckPlan.spare_parts.get($free % CheckPlan.spare_parts.len()) ?? 1
					$free = $free + 1
					$out = $out.append({ name, part })
				}
			}
		}
		$out
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
			mine = CheckPlan.deal(all, apps).keep_if(|d| d.part == index).map(|d| d.name)
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
	## specs use them), with the shipping builds of those of its apps in
	## `size_specs` (whose compiler-keyed skips run specs on that build),
	## then those its other stages need. Empty when it runs no stage that
	## needs builds.
	builds : Plan, List(Str) -> { natives : List(Str), webs : List(Str), sized : List(Str) }
	builds = |p, size_specs| {
		own = if (CheckPlan.runs(p, "specs")) p.apps else []
		extra = p.stages.map(CheckPlan.needs)
		{
			natives: dedup(own.concat(extra.map(|n| n.natives).join())),
			webs: dedup(own.concat(extra.map(|n| n.webs).join())),
			sized: dedup(own.keep_if(|name| size_specs.contains(name)).concat(extra.map(|n| n.sized).join())),
		}
	}

	## What `check -- --plan` prints: for each part, the stages it runs,
	## the apps its per-app stages run for, how many builds it makes (at
	## `--opt=dev` and at `--opt=size`), and any build another part also
	## makes; then the whole gate's builds, and any it makes twice.
	describe : List(Stage), U64, List(Str), Inputs -> List(Str)
	describe = |all, count, apps, inputs| {
		per_app = all.keep_if(|s| s.placement == PerApp).map(|s| s.name)
		counts = |made| {
			dev = made.keep_if(|m| m.build.opt == "dev").len()
			"${made.len().to_str()} builds (${dev.to_str()} --opt=dev, ${(made.len() - dev).to_str()} --opt=size)"
		}
		var $lines = ["check runs ${all.len().to_str()} stages; CI runs them as ${count.to_str()} parts (check -- --part K/${count.to_str()})", "every part runs the per-app stages for its own apps: ${Str.join_with(per_app, ", ")}"]
		var $by_part = []
		for index in 1.U64..=count {
			match CheckPlan.plan(all, count, apps, OnePart({ index, total: count })) {
				Ok(p) => {
					$by_part = $by_part.append((index, CheckPlan.builds_made(p, inputs)))
				}
				Err(error) => {
					$lines = $lines.append(CheckPlan.refusal(error))
				}
			}
		}
		by_part = $by_part
		for (index, made) in by_part {
			own = all.keep_if(|s| s.placement == Part(index)).map(|s| s.name)
			mine = CheckPlan.deal(all, apps).keep_if(|d| d.part == index).map(|d| d.name)
			elsewhere = by_part.keep_if(|(k, _)| k != index).map(|(_, other)| other.map(|m| m.build)).join()
			shared = dedup_builds(made.map(|m| m.build).keep_if(|b| elsewhere.contains(b)))
			$lines = $lines
				.append("part ${index.to_str()}/${count.to_str()}: ${Str.join_with(own, ", ")}")
				.append("  apps (${mine.len().to_str()}): ${Str.join_with(mine, ", ")}")
				.append("  ${counts(made)}; repeated in another part: ${if (shared == []) "none" else Str.join_with(shared.map(show_build), ", ")}")
		}
		match CheckPlan.plan(all, count, apps, Whole) {
			Ok(p) => {
				made = CheckPlan.builds_made(p, inputs)
				twice = CheckPlan.repeated(made)
				$lines = $lines.append("whole gate: ${counts(made)}; made twice: ${if (twice == []) "none" else Str.join_with(twice.map(show_build), ", ")}")
			}
			Err(error) => {
				$lines = $lines.append(CheckPlan.refusal(error))
			}
		}
		$lines
			.append("signals.roc's own builds (its apps' runners and --opt=size modules, which it checks) are the tool's and not listed")
			.append("with --without-sizes, as CI runs it, the example sizes' --opt=size builds are not made here: CI's Site job builds those modules to publish them and reports their sizes")
	}

	## Every build a plan makes, one line each: its root, target and opt,
	## and the stages that use it (`check -- --plan --builds`).
	build_lines : Plan, Inputs -> List(Str)
	build_lines = |p, inputs| CheckPlan.builds_made(p, inputs).map(|m| "  ${show_build(m.build)}: ${Str.join_with(m.used_by, ", ")}")

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

dedup_builds : List(CheckPlan.Build) -> List(CheckPlan.Build)
dedup_builds = |items| items.fold([], |seen, item| if (seen.contains(item)) seen else seen.append(item))

show_build : CheckPlan.Build -> Str
show_build = |b| "${b.root} (${b.target}, --opt=${b.opt})"

## The parts whose own stages need `name`'s native runner or browser build.
needing : List(CheckPlan.Stage), Str -> List(U64)
needing = |all, name| {
	parts = all.keep_oks(
		|s| match s.placement {
			Part(k) => {
				n = CheckPlan.needs(s.name)
				if (n.natives.contains(name) or n.webs.contains(name)) Ok(k) else Err(NotNeeded)
			}
			PerApp => Err(NotNeeded)
		},
	)
	parts.fold([], |seen, k| if (seen.contains(k)) seen else seen.append(k))
}

## Inputs as the tree holds them today, for the tests below: two sample
## directories stand in for the twenty.
example_inputs : CheckPlan.Inputs
example_inputs = { samples: ["www/samples/counter", "www/samples/todos"], catalog: SpecSuite.apps, size_specs: ["files"] }

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
			b = CheckPlan.builds(p, [])
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
## the rest naming the part that runs each; an app its own stages need is
## dealt to it, the rest to the spare parts; its builds are its apps' and
## what its stages need, each once.
expect {
	all = [{ name: "a", placement: Part(1) }, { name: "specs", placement: PerApp }, { name: "grammar coverage", placement: Part(2) }]
	match CheckPlan.plan(all, 2, ["x", "y", "kanban-board"], OnePart({ index: 2, total: 2 })) {
		Ok(p) => p.stages == ["specs", "grammar coverage"] and p.apps == ["y", "kanban-board"] and p.skip == [{ name: "a", part: 1 }] and CheckPlan.builds(p, []) == { natives: ["y", "kanban-board"], webs: ["y", "kanban-board"], sized: [] } and CheckPlan.skip_line({ name: "a", part: 1 }) == "SKIP a: part 1/${CheckPlan.parts.to_str()} runs it"
		Err(_) => Bool.False
	}
}

## The whole gate makes each build once: no two stages, and no stage and
## the shared batch, build the same root for the same target at the same
## opt.
expect {
	match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, Whole) {
		Ok(p) => CheckPlan.repeated(CheckPlan.builds_made(p, example_inputs)) == []
		Err(_) => Bool.False
	}
}

## No build is made by two parts: every app a part's own stages need is
## needed by that part alone, and so is dealt to it, and no part makes
## another's builds.
expect {
	var $all = []
	for index in 1.U64..=CheckPlan.parts {
		match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, OnePart({ index, total: CheckPlan.parts })) {
			Ok(p) => {
				$all = $all.concat(CheckPlan.builds_made(p, example_inputs))
			}
			Err(_) => {
				$all = $all.append({ build: { root: "refused", target: "", opt: "" }, used_by: [] }).append({ build: { root: "refused", target: "", opt: "" }, used_by: [] })
			}
		}
	}
	CheckPlan.contested(CheckPlan.stages, SpecSuite.spec_apps) == [] and CheckPlan.repeated($all) == []
}

## The parts together make exactly the whole gate's builds.
expect {
	var $all = []
	for index in 1.U64..=CheckPlan.parts {
		match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, OnePart({ index, total: CheckPlan.parts })) {
			Ok(p) => {
				$all = $all.concat(CheckPlan.builds_made(p, example_inputs).map(|m| m.build))
			}
			Err(_) => {}
		}
	}
	match CheckPlan.plan(CheckPlan.stages, CheckPlan.parts, SpecSuite.spec_apps, Whole) {
		Ok(p) => {
			whole = CheckPlan.builds_made(p, example_inputs).map(|m| m.build)
			whole.len() == $all.len() and whole.all(|b| $all.contains(b))
		}
		Err(_) => Bool.False
	}
}

## Two parts needing one app is reported, and the app goes to the first.
expect {
	all = [{ name: "release dry run", placement: Part(1) }, { name: "grammar coverage", placement: Part(2) }, { name: "specs", placement: PerApp }]
	CheckPlan.contested(all, ["kanban-board", "x"]) == [{ name: "kanban-board", parts: [1, 2] }] and CheckPlan.deal(all, ["kanban-board"]) == [{ name: "kanban-board", part: 1 }]
}

## A stage and the shared batch building one root twice is a repeat.
expect CheckPlan.repeated([{ build: { root: "a", target: "wasm32", opt: "dev" }, used_by: ["specs"] }, { build: { root: "a", target: "wasm32", opt: "dev" }, used_by: ["runtime unit tests"] }, { build: { root: "a", target: "wasm32", opt: "size" }, used_by: ["runtime unit tests"] }]) == [{ root: "a", target: "wasm32", opt: "dev" }]

## A part is written K/N.
expect (CheckPlan.parse_part("2/5"), CheckPlan.parse_part("2"), CheckPlan.parse_part("a/5")) == (Ok({ index: 2, total: 5 }), Err(BadPart("2")), Err(BadPart("a/5")))

## The stages `check` reached must be exactly the placed ones, in order.
expect {
	all = [{ name: "a", placement: Part(1) }, { name: "b", placement: PerApp }]
	(CheckPlan.called_problems(all, ["a", "b"]), CheckPlan.called_problems(all, ["a", "c"]), CheckPlan.called_problems(all, ["b", "a"]))
		== ([], ["check never reaches the stage b that CheckPlan.stages places", "check runs the stage c, which CheckPlan.stages does not place"], ["check reaches its stages in another order, or more than once, than CheckPlan.stages lists them"])
}
