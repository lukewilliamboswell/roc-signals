import pf.Engine exposing [File]
import Lab

## Worker Lab's store: the run and what it has done, held at the root, and
## every transition over it as a pure function that returns its writes.
##
## - `run`: the serial of the latest run. It goes on counting through a
##   reset, so a job of a new run is never taken for one of an old run.
## - `work`: what a run does, a group that "Reset" starts again with the
##   write its description generated:
##   - `jobs`: the run's jobs, a table by index. A job's answer writes its
##     own row and admits the next waiting one, so each write touches the
##     rows it names; the job grid and the picture's bands are views of it
##     and wake only the rows a write touched.
##   - `refused`: the refusals counted since the last reset.
##   - `ticks`: the ticks of the page's clock counted while strips were
##     drawn.
##   - `save`: the picture the user last asked to save.
##
## The parameters as typed are not here: only the panel that edits them
## reads them, so they are that panel's state, and it hands them to the
## decision that starts a run.
LabStore := [Bench].{

	store = Engine.store(
		LabStore.Bench,
		{
			run: Engine.cell(0.U64),
			work: {
				jobs: Engine.table([]),
				refused: Engine.cell(0.U64),
				ticks: Engine.cell(0.U64),
				save: Engine.cell(Engine.outbox({})),
			}.Engine.Cells.with_reset(|cells, reset| { jobs: cells.jobs, refused: cells.refused, ticks: cells.ticks, save: cells.save, reset }),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = LabStore.store.handles()

	## Start a run with the parameters as typed, after run `run`; one
	## already going is superseded. Invalid parameters start nothing.
	started : Lab.Form, U64 -> List(Engine.Write(_))
	started = |typed, run|
		match Lab.params(typed) {
			Ok(params) => {
				next = run + 1
				[
					LabStore.h.run.put(next),
					LabStore.h.work.jobs.change(|jobs| Lab.admit(jobs.load(Lab.jobs_for(params, next)))),
					LabStore.h.work.ticks.put(0),
				]
			}
			Err(_) => []
		}

	## A parameter changed: while a run is going, it restarts with the new
	## parameters (when they are valid), superseding the old run's jobs.
	edited : { typed : Lab.Form, run : U64, going : Bool } -> List(Engine.Write(_))
	edited = |{ typed, run, going }| if (going) LabStore.started(typed, run) else []

	## Stop every job that has not finished. Finished jobs keep their answers.
	cancelled : List(Engine.Write(_))
	cancelled = [LabStore.h.work.jobs.change(|jobs| jobs.update_all(|_, job| Lab.cancelled(job)))]

	## Ask again for every job that ended without an answer: each goes back
	## to waiting as a new attempt, and the answers so far are kept. A
	## picture with a lost or cancelled strip is finished this way.
	retried : List(Engine.Write(_))
	retried = [LabStore.h.work.jobs.change(|jobs| Lab.admit(jobs.update_all(|_, job| Lab.again(job))))]

	## The request of the row whose job is `job` came back, for the attempt
	## it was issued for. A refusal sends the job back to waiting for
	## another attempt, counted; anything else finishes it. Either way the
	## next waiting job is admitted, except that a drawn strip keeps its
	## slot until its URL comes back. An answer for an attempt the row has
	## moved past changes nothing.
	finished : Lab.Job, { run : U64, attempt : U64 }, Try(Lab.Answer, Lab.Ended) -> List(Engine.Write(_))
	finished = |job, issued, outcome|
		if Lab.is_attempt(job, issued) and Lab.is_running(job) {
			settled = Lab.settled(job, outcome)
			placed = LabStore.h.work.jobs.change(|jobs| Lab.admit(jobs.replace(settled.index, settled)))
			match outcome {
				Err(Refused) => [placed, LabStore.h.work.refused.change(|count| count + 1)]
				_ => [placed]
			}
		} else {
			[]
		}

	## The URL of the strip the row's job drew came back, or why there is
	## none; either way its slot is free, and the next waiting strip is
	## admitted.
	shown : Lab.Job, { run : U64, attempt : U64 }, Try(Str, Str) -> List(Engine.Write(_))
	shown = |job, issued, outcome|
		if Lab.is_attempt(job, issued) and Lab.awaits_url(job) {
			linked = Lab.linked(job, outcome)
			[LabStore.h.work.jobs.change(|jobs| Lab.admit(jobs.replace(linked.index, linked)))]
		} else {
			[]
		}

	## One tick of the page's clock, counted while strips are being drawn.
	ticked : Bool -> List(Engine.Write(_))
	ticked = |drawing| if (drawing) [LabStore.h.work.ticks.change(|count| count + 1)] else []

	## Keep `file`, the picture, for the save the user asked for.
	saved : File -> List(Engine.Write(_))
	saved = |file| [LabStore.h.work.save.change(|box| box.post(file))]
}

## The parameters of a run of `jobs` jobs of the lightest weight.
asked_for : Lab.Workload, Str -> Lab.Form
asked_for = |workload, jobs| { ..Lab.form, workload, jobs_text: jobs, weight_text: "1" }

## The jobs a store holds.
jobs_in : Engine.Store(_, _) -> Lab.Jobs
jobs_in = |store| store.read(LabStore.h.work.jobs)

## The job at `index` in a store.
job_in : Engine.Store(_, _), U64 -> Lab.Job
job_in = |store, index| jobs_in(store).get(index) ?? crash "LabStore's tests: no job ${index.to_str()}"

## A run admits `window` jobs and keeps the rest waiting; a finished job
## admits the next.
expect {
	run = LabStore.store.after(LabStore.started(asked_for(Primes, "20"), 0))
	before = Lab.tally(jobs_in(run))
	after = Lab.tally(jobs_in(run.after(LabStore.finished(job_in(run, 3), { run: 1, attempt: 0 }, Ok(Primes(7))))))
	actual = [before.running, before.waiting, after.running, after.waiting, after.done]
	actual == [15, 5, 15, 4, 1]
}

## A refused job waits for another attempt and is counted, and a stale
## answer changes nothing.
expect {
	run = LabStore.store.after(LabStore.started(asked_for(Primes, "2"), 0))
	refused = run.after(LabStore.finished(job_in(run, 1), { run: 1, attempt: 0 }, Err(Refused)))
	stale = refused.after(LabStore.finished(job_in(refused, 1), { run: 1, attempt: 0 }, Ok(Primes(1))))
	actual = [job_in(refused, 1).attempt, refused.read(LabStore.h.work.refused), Lab.tally(jobs_in(refused)).running, Lab.tally(jobs_in(stale)).done]
	actual == [1, 1, 2, 0]
}

## Invalid parameters start nothing; valid ones start the next run, and a
## change of parameter restarts only a run that is going.
expect {
	invalid = LabStore.store.after(LabStore.started(asked_for(Primes, "257"), 0))
	first = LabStore.store.after(LabStore.started(asked_for(Primes, "3"), 0))
	idle = first.after(LabStore.edited({ typed: asked_for(Primes, "5"), run: 1, going: Bool.False }))
	going = first.after(LabStore.edited({ typed: asked_for(Primes, "5"), run: 1, going: Bool.True }))
	runs = |store| "run ${store.read(LabStore.h.run).to_str()} of ${jobs_in(store).len().to_str()}"
	actual =
		\\invalid: ${runs(invalid)}
		\\first: ${runs(first)}
		\\idle: ${runs(idle)}
		\\going: ${runs(going)}, job 1 of run ${job_in(going, 0).run.to_str()}
	expected =
		\\invalid: run 0 of 0
		\\first: run 1 of 3
		\\idle: run 1 of 3
		\\going: run 2 of 5, job 1 of run 2
	actual == expected
}

## Cancelling stops what has not finished and keeps the answers; retrying
## asks again for what stopped; a reset drops the run but not its serial.
expect {
	run = LabStore.store.after(LabStore.started(asked_for(Primes, "20"), 0))
	answered = run.after(LabStore.finished(job_in(run, 0), { run: 1, attempt: 0 }, Ok(Primes(7))))
	cancelled = answered.after(LabStore.cancelled)
	retried = cancelled.after(LabStore.retried)
	reset = retried.after([LabStore.h.work.refused.put(4), LabStore.h.work.ticks.put(9)]).after([LabStore.h.work.reset])
	counts = |store| {
		tally = Lab.tally(jobs_in(store))
		"${tally.done.to_str()} done, ${tally.running.to_str()} running, ${tally.waiting.to_str()} waiting, ${tally.cancelled.to_str()} cancelled"
	}
	actual =
		\\cancelled: ${counts(cancelled)}
		\\retried: ${counts(retried)}, job 2 at attempt ${job_in(retried, 1).attempt.to_str()}
		\\reset: ${counts(reset)}, run ${reset.read(LabStore.h.run).to_str()}, ${reset.read(LabStore.h.work.refused).to_str()} refused, ${reset.read(LabStore.h.work.ticks).to_str()} ticks
	expected =
		\\cancelled: 1 done, 0 running, 0 waiting, 19 cancelled
		\\retried: 1 done, 15 running, 4 waiting, 0 cancelled, job 2 at attempt 1
		\\reset: 0 done, 0 running, 0 waiting, 0 cancelled, run 1, 0 refused, 0 ticks
	actual == expected
}

## A drawing admits one strip fewer than the window, since the page's
## clock holds a slot, and composes nothing until every strip is drawn. The
## clock is counted only while strips are being drawn.
expect {
	drawing = LabStore.store.after(LabStore.started(asked_for(Draw, "20"), 0))
	ticked = drawing.after(LabStore.ticked(Lab.drawing(jobs_in(drawing)))).after(LabStore.ticked(Bool.False))
	actual = {
		running: Lab.tally(jobs_in(drawing)).running,
		drawing: Lab.drawing(jobs_in(drawing)),
		composed: Lab.composition(jobs_in(drawing)) == Skip,
		strips: Lab.count_jobs(jobs_in(drawing), Lab.is_strip),
		ticks: ticked.read(LabStore.h.work.ticks),
	}
	actual == { running: 14, drawing: Bool.True, composed: Bool.True, strips: 20, ticks: 1 }
}
