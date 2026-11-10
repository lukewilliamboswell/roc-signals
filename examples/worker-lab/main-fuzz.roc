app [target] { pf: platform "../../platform/fuzz.roc" }

import pf.Core
import pf.Dom
import pf.Fuzz
import pf.Scm
import pf.Soak
import pf.SpecRunner
import pf.Wire
import Lab
import LabApp

## Worker Lab on the fuzz platform (its specs run through `main.roc`). The
## walks answer pending jobs as `Soak.step` does: run the program in process,
## lose the job with a fault class, time it out, or leave it pending, so every
## prime and tile program runs inside the leak check.
## - generated: explorer-driven walks of starts, cancels, resets, parameter
##   edits (restarts) and answers, settled after every step, which must free
##   everything they allocated.
## - "soak-10k": 10k seeded steps, then a run started, every job answered and
##   the run reset, 48 times on the engine alone: live bytes flat.
##
## The walk keeps away from the faulty workload. Its crash program crashes on
## every input by design, and a walk runs programs in process, where a crash
## ends the walk as a finding; that program's behaviour is specified instead
## (specs/a-failed-job-loses-only-itself.scm, natively in a child process and
## in Chrome in a worker) and soaked in Chrome. So after any step that leaves
## "faulty" selected, the walk selects "primes" again in the same step, which
## restarts a running run and supersedes its crash jobs before any is
## answered. The walk also puts a parameter it made invalid back to its
## initial value (see `repair`), so it keeps reaching runs.

St : SpecRunner.S(Core.App)

program : SpecRunner.Program(Core.App)
program = Core.driver(LabApp.program)

workload : Scm.Loc
workload = Label("Workload")

## Apply `op` in a steering correction; it must succeed.
correct : St, Scm.Op -> St
correct = |s, op|
	match SpecRunner.one(program, s, op) {
		Ok(s2) => s2
		Err(msg) => crash "lab walk: steering: ${msg}"
	}

## The value the walk left in the control labelled `label`.
value_of : St, Str -> Str
value_of = |s, label|
	match SpecRunner.find(s.dom, Label(label)) {
		Ok(i) => Dom.attr_of(Dom.node(s.dom, i), "value")
		Err(_) => crash "lab walk: no control ${label}"
	}

## Put a parameter the walk made invalid back to its initial value, so the
## walk keeps reaching runs: with three number fields and mostly non-numeric
## text to type, it would otherwise spend nearly all its steps with Start
## disabled. The invalid state is still rendered (and leak-checked) in the
## step that produced it.
repair : St, { label : Str, lo : U64, hi : U64, initial : Str } -> St
repair = |s, { label, lo, hi, initial }|
	match Lab.bounded(value_of(s, label), lo, hi) {
		Ok(_) => s
		Err(_) => correct(s, Fill(Label(label), initial))
	}

## After every step: off the faulty workload (see above), and every
## parameter valid.
steer : St -> St
steer = |s0| {
	s1 = if (value_of(s0, "Workload") == "faulty") correct(s0, SelectOption(workload, "primes")) else s0
	s2 = repair(s1, { label: "Jobs", lo: 1, hi: Lab.max_jobs, initial: Lab.initial.jobs_text })
	s3 = repair(s2, { label: "Weight", lo: 1, hi: Lab.max_weight, initial: Lab.initial.weight_text })
	repair(s3, { label: "Deadline (ms)", lo: 0, hi: Lab.max_deadline_ms, initial: Lab.initial.deadline_text })
}

start : {} -> St
start = |_| SpecRunner.mount(program, "/", [])

## A walk's `after` hook: steer, then the settle check (`Soak.settled`).
steered : St -> St
steered = |s| Soak.settled(program)(steer(s))

## A round trip back to the initial state: a run of the initial parameters
## started, its jobs answered, and the run reset.
cycle : List(Scm.Op)
cycle = [Click(Role({ role: "button", name: "Start" })), Click(Role({ role: "button", name: "Reset" }))]

## What each job of a run with the initial parameters answers, in job order,
## computed as a worker instance would compute it (at run time, not as a
## compile-time constant).
answers_for : {} -> List(List(U8))
answers_for = |_|
	Lab.start(Lab.initial).jobs.map(
		|job| match job.task {
			Count(span) => Wire.encode(Lab.count_primes(span))
			_ => crash "lab soak: the initial workload counts primes"
		},
	)

## Answer every job in flight on the engine alone, oldest first, with its
## job's answer; `subs` (the heartbeat) is left running.
answer_jobs : List(U32), List(List(U8)), Core.App, List(U8) -> (Core.App, List(U8))
answer_jobs = |subs, answers, a0, b0| {
	var $a = a0
	var $b = b0
	var $k = 0.U64
	for id in Core.fx_live(a0).keep_if(|id| !subs.contains(id)) {
		(a1, b1) = Core.take_cmds(Core.result($a, id, Work(answers.get($k) ?? crash "lab soak: more jobs than the run has")), $b)
		$a = a1
		$b = b1
		$k = $k + 1
	}
	($a, $b)
}

## Soak, mode 2: an explorer-driven walk (two bytes per event) from a fresh
## mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |bytes| {
	Fuzz.expect_no_leaks!(|| Soak.walk(program, start({}), bytes, steered))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded steps (settle-checked and leak-checked), then the round trip 48
## times on the engine alone: live allocations flat after 3 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(program, start({}), 7, 10000, steered))
	# What the same walk reached, outside the leak check.
	walked = Soak.walk_n(program, start({}), 7, 10000, steered)
	shown = |id| SpecRunner.find(walked.dom, TestId(id)).map_ok(|i| Dom.text_of(walked.dom, i)) ?? "?"
	Fuzz.mark!("soak walk: ${walked.browser.issued.len().to_str()} effects issued; last run ${shown("progress")}; refused and retried ${shown("refused")}")
	s0 = start({})
	subs = Core.fx_live(s0.inst)
	answers = answers_for({})
	(s1, evs) = Soak.triples(program, s0, cycle, Soak.settled(program))
	counts = Soak.replay!(program, s1.inst, evs, 48, |a, b| answer_jobs(subs, answers, a, b), begin!, net_bytes!)
	match Soak.flat(counts, 3) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle net live bytes ${Str.inspect(counts.sublist({ start: 0, len: 4 }))} ... (${counts.len().to_str()} cycles)")
	Fuzz.keep
}

## Soak probes: a measured region around one cycle; its net live bytes.
begin! : {} => Fuzz.Measurement
begin! = |_| Fuzz.start_measure!("cycle")

net_bytes! : Fuzz.Measurement => I64
net_bytes! = |w| {
	stats = w.finish!()
	stats.exit_live_bytes.to_i64_wrap() - stats.entry_live_bytes.to_i64_wrap()
}

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program: bytes, .. }| {
	if mode == 2 {
		soak_walk!(bytes)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "worker-lab",
	examples: [
		ex("soak-10k", 3, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
