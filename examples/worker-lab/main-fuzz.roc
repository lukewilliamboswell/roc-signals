app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Scm
import pf.Soak
import pf.SpecRunner
import pf.Wire
import Lab
import LabApp

## Worker Lab as a roc-fuzz target (its specs run through `main.roc`). The
## walks answer pending jobs as `Soak.step` does: answer it with the task's
## pure function standing in for its worker (`stand_in`), lose the job with
## a fault class, time it out, or leave it pending, so every prime and tile
## calculation runs inside the leak check.
## - generated: explorer-driven walks of starts, cancels, resets, parameter
##   edits (restarts) and answers, settled after every step, which must free
##   everything they allocated.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-a-run-answered-and-reset.scm`).
##
## The walk keeps away from the faulty workload. Its crash task crashes on
## every input by design, and a walk answers jobs in process, where a crash
## ends the walk as a finding; that task's behaviour is specified instead
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

## The walk's stand-in for a worker: each task's answer from the pure
## function its `run!` wraps.
stand_in : Str, List(U8), List(U8) -> List(U8)
stand_in = |task, prep, input|
	if task == LabApp.primes(Unlimited).name() {
		LabApp.primes(Unlimited).stand_in(|span| Ok(Lab.count_primes(span)))(prep, input)
	} else if task == LabApp.tiles(Unlimited).name() {
		LabApp.tiles(Unlimited).stand_in(|spec| Ok(Wire.Bytes.from_list(Lab.tile(spec))))(prep, input)
	} else {
		crash "lab walk: the walk keeps away from worker task \"${task}\""
	}

## A walk's `after` hook: steer, then the settle check (`Soak.settled`).
steered : St -> St
steered = |s| Soak.settled(program)(steer(s))

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| Soak.walk_with(program, start({}), Soak.session_bytes(session), stand_in, steered))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "worker-lab",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
