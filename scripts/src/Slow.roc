import cli.Path
import Checks
import Proc
import SpecSuite
import Targets

## The slow suite: the fuzz targets' examples, the walks and the soaks.
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
		{ example: "million-row-explorer", spec: "round-trip-clear-and-restore-a-category" },
		{ example: "supersede", spec: "round-trip-late-branch" },
		{ example: "worker-search", spec: "round-trip-search-and-report" },
		{ example: "table", spec: "round-trip-edit-scroll-and-rewrite" },
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

	## The apps walked: every spec app but the three whose pages offer a
	## contract error on purpose (a job of an unregistered task, a port used
	## as the wrong kind, an outbox posted twice in a turn), which a walk
	## reaches within a few hundred steps and which, as it must, poisons
	## the instance. Their specs and Chrome contract tests cover them.
	walk_apps : List(Str)
	walk_apps = SpecSuite.spec_apps.drop_if(|name| ["workers", "ports", "outbox"].contains(name))

	## One walk: an app, how many steps, and from which seed.
	Walk : { name : Str, steps : U64, seed : U64 }

	## The walks: 10,000 steps from seed 7 for each app, except the
	## Markdown Editor, whose documents grow as a walk types into them, so
	## each step costs the DOM oracle more than the last: five walks of 2,000
	## steps from seeds 1 to 5 instead.
	walks : List(Walk)
	walks = Slow.walk_apps.map(|name| if (name == "markdown-editor") [1, 2, 3, 4, 5].map(|seed| { name, steps: 2000, seed }) else [{ name, steps: 10000, seed: 7 }]).join()

	## Where an app's walk runner is built: `--opt=speed`, as the walk is
	## long and its oracle slow at `--opt=dev`.
	walker_of : SpecSuite.Options, Str -> Str
	walker_of = |o, name| "${o.build_dir}/walk/${name}/runner"

	## The spec files an app's walk reads: its round-trip spec first, whose
	## setup the walk mounts with, then the rest, whose steps answer the
	## app's requests and give the values it types (`RUNNER --walk`).
	walk_files! : Str => Try(List(Str), _)
	walk_files! = |name| {
		files = SpecSuite.spec_files!(name)?
		round_trips = files.keep_if(|f| (f.split_on("/").last() ?? f).starts_with("round-trip-"))
		Ok(round_trips.concat(files.drop_if(|f| round_trips.contains(f))))
	}

	## Walk every spec app with its native spec runner, in parallel: a
	## seeded walk of user events and browser services from a fresh mount,
	## its worker jobs run for real, settled and counter-checked after every
	## step, which must leave nothing allocated (`RUNNER --walk`).
	walks! : SpecSuite.Options => Try(List(Str), _)
	walks! = |o| {
		var $builds = []
		for name in Slow.walk_apps {
			Path.create_all!(Path.utf8("${o.build_dir}/walk/${name}"))?
			$builds = $builds.append(SpecSuite.build_job(o, "speed", "${SpecSuite.dir_of(name)}/main.roc", SpecSuite.native_target, Slow.walker_of(o, name)))
		}
		built = Proc.parallel!($builds, Proc.cpus!())?
		match List.map2(Slow.walk_apps, built, |name, r| (name, r.code)).keep_if(|(_, c)| c != 0).first() {
			Ok((name, c)) => return Err(BuildFailed("walk runner ${name}: build exited with ${c.to_str()}"))
			Err(_) => {}
		}
		var $jobs = []
		for w in Slow.walks {
			files = Slow.walk_files!(w.name)?
			$jobs = $jobs.append({ program: Slow.walker_of(o, w.name), args: ["--walk", w.steps.to_str(), "--seed", w.seed.to_str()].concat(files), cwd: o.root })
		}
		results = Proc.parallel!($jobs, Proc.cpus!())?
		Ok(List.map2(Slow.walks, results, |w, r| if (r.code == 0 and r.output.contains("\"status\":\"passed\"")) [] else ["walk ${w.name} seed ${w.seed.to_str()}: ${r.output.trim()}"]).join())
	}

	## How many steps the pull-request gate walks each app.
	short_walk_steps : U64
	short_walk_steps = 300

	## A short walk of every walked app, for `check`: 300 steps from seed 7
	## on the native spec runner `check` has already built, in parallel. It
	## catches a walk that fails early (a stale reader, a leak, a job or an
	## answer the runner cannot deliver) on every pull request; the long
	## walks are `walks!`.
	short_walks! : SpecSuite.Options => Try(List(Str), _)
	short_walks! = |o| {
		var $jobs = []
		for name in Slow.walk_apps {
			files = Slow.walk_files!(name)?
			$jobs = $jobs.append({ program: SpecSuite.runner_of(o, name), args: ["--walk", Slow.short_walk_steps.to_str(), "--seed", "7"].concat(files), cwd: o.root })
		}
		results = Proc.parallel!($jobs, Proc.cpus!())?
		Ok(List.map2(Slow.walk_apps, results, |name, r| if (r.code == 0 and r.output.contains("\"status\":\"passed\"")) [] else ["short walk ${name}: ${r.output.trim()}"]).join())
	}

	## Every fuzz target's examples, every app's walk and native soak, then
	## every app's browser soak.
	soak! : SpecSuite.Options => Try(List(Str), _)
	soak! = |o| {
		Checks.prepare_platform!(o)?
		SpecSuite.build_web_platform!(o)?
		Proc.note!("== fuzz targets")
		var $problems = Targets.fuzz_check_all!(o, Targets.fuzz_targets)?
		Proc.note!("== walks")
		$problems = $problems.concat(Slow.walks!(o)?)
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
