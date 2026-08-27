## Domain model for the dependency scheduler.
##
## The signal graph in `main.roc` is static: edges are declared once by
## `Signal.map` / `Signal.map2` / `Signal.combine` / `Ui.each_str` and cannot be
## built from runtime data. So the *task* dependency graph is not mapped onto
## the *signal* graph. Instead the whole schedule is recomputed in one pure pass
## here (topological order, forward pass, backward pass), and the keyed rows plus
## per-value equality cutoffs in the view scope the DOM work down to the rows
## that actually changed.
##
## This module holds no CSS and no display formatting beyond plain domain text.

Plan :: [].{

	## One planned task. `lag` is the manual delay a user has applied on top of
	## the earliest start its prerequisites allow, so "moving" a task is a change
	## to `lag` and "resizing" it is a change to `duration`.
	Task : {
		id : Str,
		name : Str,
		duration : U64,
		lag : U64,
		deps : List(Str),
	}

	## Where a solved row sits in the plan. The three cases are exclusive, so
	## they are one tag rather than a pair of booleans that could disagree:
	## `Blocked` is only reachable while the plan is cyclic, and a schedulable
	## row is `Critical` exactly when its slack is zero.
	Status := [Blocked, Critical, HasSlack].{
		is_eq : Status, Status -> Bool
		is_eq = |left, right|
			match left {
				Blocked =>
					match right {
						Blocked => True
						_ => False
					}
				Critical =>
					match right {
						Critical => True
						_ => False
					}
				HasSlack =>
					match right {
						HasSlack => True
						_ => False
					}
			}
	}

	## One fully scheduled task.
	Row : {
		id : Str,
		name : Str,
		duration : U64,
		lag : U64,
		start : U64,
		finish : U64,
		latest_start : U64,
		slack : U64,
		status : Status,
		deps : List(Str),
		deps_text : Str,
	}

	## A whole solved schedule. A non-empty `cycle` names the tasks that could
	## not be topologically ordered; every row is then reported as unscheduled.
	## `rows` keeps the stable authoring order so keyed rows never move; `path`
	## is the critical path in topological order.
	Schedule : {
		rows : List(Row),
		path : List(Str),
		project_end : U64,
		cycle : List(Str),
	}

	Early : { id : Str, start : U64, finish : U64 }

	Late : { id : Str, latest_start : U64 }

	## The starting project used by the example.
	initial_tasks : List(Task)
	initial_tasks = [
		{ id: "spec", name: "Write spec", duration: 2, lag: 0, deps: [] },
		{ id: "api", name: "Build API", duration: 4, lag: 0, deps: ["spec"] },
		{ id: "ui", name: "Build UI", duration: 3, lag: 0, deps: ["spec"] },
		{ id: "docs", name: "Write docs", duration: 1, lag: 0, deps: ["spec"] },
		{ id: "sync", name: "Integrate", duration: 2, lag: 0, deps: ["api", "ui"] },
		{ id: "qa", name: "QA pass", duration: 2, lag: 0, deps: ["sync"] },
		{ id: "launch", name: "Launch", duration: 0, lag: 0, deps: ["qa"] },
	]

	## Saturating subtraction on day counts.
	sat_sub : U64, U64 -> U64
	sat_sub = |left, right| if left > right {
		left - right
	} else {
		0
	}

	## Human-readable prerequisite list for a task.
	deps_label : List(Str) -> Str
	deps_label = |deps|
		if deps.is_empty() {
			"none"
		} else {
			Str.join_with(deps, "+")
		}

	## Kahn-style topological sort. Bounded by `tasks.len()` passes, so a cyclic
	## graph terminates and reports its unordered tasks instead of hanging.
	topo : List(Task) -> { order : List(Task), stuck : List(Task) }
	topo = |tasks| {
		known = tasks.map(|t| t.id)
		var $order = []
		var $remaining = tasks

		for _pass in 0..<tasks.len() {
			placed = $order.map(|t| t.id)
			var $next = []
			for t in $remaining {
				blocked = t.deps.keep_if(|d| known.contains(d) and !placed.contains(d))
				if blocked.is_empty() {
					$order = $order.append(t)
				} else {
					$next = $next.append(t)
				}
			}
			$remaining = $next
		}

		{ order: $order, stuck: $remaining }
	}

	## Forward pass: earliest start/finish in topological order.
	forward : List(Task) -> List(Early)
	forward = |order| {
		var $acc = []
		for t in order {
			var $earliest = 0
			for d in t.deps {
				finish = $acc.find_first(|r| r.id == d).map_ok(|found| found.finish).ok_or(0)
				$earliest = if finish > $earliest {
					finish
				} else {
					$earliest
				}
			}
			start = $earliest + t.lag
			$acc = $acc.append({ id: t.id, start, finish: start + t.duration })
		}
		$acc
	}

	## Backward pass: latest start in reverse topological order. A task with no
	## successors may finish at the project end; otherwise it must finish early
	## enough for every successor to still start on time, allowing for that
	## successor's own manual lag.
	backward : List(Task), U64 -> List(Late)
	backward = |order, project_end| {
		var $acc = []
		count = order.len()
		for step in 0..<count {
			t =
				match order.get(Plan.sat_sub(count, step + 1)) {
					Ok(found) => found
					Err(_) => {
						crash "backward pass index out of range"
					}
				}
			var $latest_finish = project_end
			for s in order {
				if s.deps.contains(t.id) {
					bound =
						$acc
							.find_first(|r| r.id == s.id)
							.map_ok(|found| Plan.sat_sub(found.latest_start, s.lag))
							.ok_or(project_end)
					$latest_finish = if bound < $latest_finish {
						bound
					} else {
						$latest_finish
					}
				}
			}
			$acc = $acc.append({ id: t.id, latest_start: Plan.sat_sub($latest_finish, t.duration) })
		}
		$acc
	}

	## Solve the whole schedule in one pure pass.
	compute : List(Task) -> Schedule
	compute = |tasks| {
		sorted = Plan.topo(tasks)
		if !sorted.stuck.is_empty() {
			# A cycle: report it and leave every task unscheduled, but still
			# render a row per task so the user can remove the offending edge.
			unscheduled =
				tasks.map(
					|t| {
						id: t.id,
						name: t.name,
						duration: t.duration,
						lag: t.lag,
						start: 0,
						finish: 0,
						latest_start: 0,
						slack: 0,
						status: Blocked,
						deps: t.deps,
						deps_text: Plan.deps_label(t.deps),
					},
				)
			{ rows: unscheduled, path: [], project_end: 0, cycle: sorted.stuck.map(|t| t.id) }
		} else {
			early = Plan.forward(sorted.order)
			var $end = 0
			for r in early {
				$end = if r.finish > $end {
					r.finish
				} else {
					$end
				}
			}
			late = Plan.backward(sorted.order, $end)
			solve =
				|t| {
					e = early.find_first(|r| r.id == t.id).ok_or({ id: t.id, start: 0, finish: 0 })
					latest_start =
						late.find_first(|r| r.id == t.id).map_ok(|found| found.latest_start).ok_or(0)
					slack = Plan.sat_sub(latest_start, e.start)
					{
						id: t.id,
						name: t.name,
						duration: t.duration,
						lag: t.lag,
						start: e.start,
						finish: e.finish,
						latest_start,
						slack,
						status: if slack == 0 {
							Critical
						} else {
							HasSlack
						},
						deps: t.deps,
						deps_text: Plan.deps_label(t.deps),
					}
				}
			path = sorted.order.map(solve).keep_if(|r| Status.is_eq(r.status, Critical)).map(|r| r.name)
			{ rows: tasks.map(solve), path, project_end: $end, cycle: [] }
		}
	}

	## True when `task_id` already lists `dep_id` as a prerequisite.
	has_dep : List(Task), Str, Str -> Bool
	has_dep = |tasks, task_id, dep_id|
		tasks.find_first(|t| t.id == task_id).map_ok(|found| found.deps.contains(dep_id)).ok_or(False)

	## Add a prerequisite edge. Self-edges and duplicates are ignored; a cycle is
	## deliberately allowed through so the app can detect and report it.
	add_dep : List(Task), Str, Str -> List(Task)
	add_dep = |tasks, task_id, dep_id|
		if task_id == dep_id {
			tasks
		} else {
			tasks.map(
				|t|
					if t.id == task_id and !t.deps.contains(dep_id) {
						{ ..t, deps: t.deps.append(dep_id) }
					} else {
						t
					},
			)
		}

	## Remove a prerequisite edge.
	remove_dep : List(Task), Str, Str -> List(Task)
	remove_dep = |tasks, task_id, dep_id|
		tasks.map(
			|t|
				if t.id == task_id {
					{ ..t, deps: t.deps.keep_if(|d| d != dep_id) }
				} else {
					t
				},
		)

	## Stable insertion sort of scheduled rows by descending slack, so the tasks
	## with the most room float to the top and the critical path sinks.
	by_slack : List(Row) -> List(Row)
	by_slack = |rows| {
		var $out = []
		for row in rows {
			var $merged = []
			var $placed = False
			for existing in $out {
				if $placed == False and row.slack > existing.slack {
					$merged = $merged.append(row)
					$placed = True
				}
				$merged = $merged.append(existing)
			}
			$out = if $placed {
				$merged
			} else {
				$merged.append(row)
			}
		}
		$out
	}

	## Add or remove a prerequisite edge from a checkbox event.
	set_dep : List(Task), Str, Str, Bool -> List(Task)
	set_dep = |tasks, task_id, dep_id, present|
		if present {
			Plan.add_dep(tasks, task_id, dep_id)
		} else {
			Plan.remove_dep(tasks, task_id, dep_id)
		}

	## Move a task one day later.
	delay : List(Task), Str -> List(Task)
	delay = |tasks, task_id|
		tasks.map(
			|t| if t.id == task_id {
				{ ..t, lag: t.lag + 1 }
			} else {
				t
			},
		)

	## Move a task one day earlier, never before its prerequisites allow.
	pull_in : List(Task), Str -> List(Task)
	pull_in = |tasks, task_id|
		tasks.map(
			|t| if t.id == task_id {
				{ ..t, lag: Plan.sat_sub(t.lag, 1) }
			} else {
				t
			},
		)

	## Resize a task one day longer.
	extend : List(Task), Str -> List(Task)
	extend = |tasks, task_id|
		tasks.map(
			|t| if t.id == task_id {
				{ ..t, duration: t.duration + 1 }
			} else {
				t
			},
		)

	## Resize a task one day shorter, never below zero.
	shorten : List(Task), Str -> List(Task)
	shorten = |tasks, task_id|
		tasks.map(
			|t| if t.id == task_id {
				{ ..t, duration: Plan.sat_sub(t.duration, 1) }
			} else {
				t
			},
		)
}
