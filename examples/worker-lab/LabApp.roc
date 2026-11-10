import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import pf.Worker
import pf.Wire
import Lab

## Worker Lab: a run of CPU-bound jobs, each computed by a Roc task
## in a Web Worker while the page stays responsive. Here a run is a batch:
## the jobs one press of "Start" asks for with one set of parameters (one
## execution of a task is a job, as everywhere else).
##
## Each row of the job grid owns its job: the row's `Engine.latest` site
## issues the typed request for its job while the job is running and gives it
## up when the job stops wanting it. So cancelling a run, or changing a
## parameter while it goes (which restarts it), stops the superseded work in
## the workers, and a reset disposes the rows and their jobs with them.
##
## "Running" means the page has handed the job to the runtime: with more jobs
## in flight than workers, the runtime queues the rest, which the pool panel
## shows. The heartbeat is an interval the engine delivers; it keeps counting
## while the workers compute, and stalls when a computation holds the page's
## own thread (mount the app with `workers: "inline"` to see it).
##
## The pool panel is a `worker-pool-panel` element that the example's
## `pool-panel.mjs` defines and draws from the runtime's monitor. To the
## engine it is an ordinary empty element.
LabApp := [].{
	Ctx : In(Root, Lab.S)

	## Counts the primes in a range. The lab's deadline is a parameter of
	## each run, so each task is made with the deadline its jobs ask for;
	## the name and function, and so the registration, are the same for all.
	primes : [Unlimited, Ms(U32)] -> Worker.Task(Lab.Span, U64, Worker.Never)
	primes = |deadline| Worker.task({
		name: "roc-signals.example/worker-lab/primes",
		run!: |span| Ok(Lab.count_primes(span)),
		deadline,
	})

	## Draws one tile; its pixels come back as one block of bytes.
	tiles : [Unlimited, Ms(U32)] -> Worker.Task(Lab.TileSpec, Wire.Bytes, Worker.Never)
	tiles = |deadline| Worker.task({
		name: "roc-signals.example/worker-lab/tile",
		run!: |spec| Ok(Wire.Bytes.from_list(Lab.tile(spec))),
		deadline,
	})

	## A task that always crashes, for the faulty workload; its message
	## names the range it was given.
	crasher : [Unlimited, Ms(U32)] -> Worker.Task(Lab.Span, U64, Worker.Never)
	crasher = |deadline| Worker.task({
		name: "roc-signals.example/worker-lab/crash",
		run!: |{ lo, hi }| crash "the worker lab's crash task crashed on [${lo.to_str()}, ${hi.to_str()}), as it always does",
		deadline,
	})

	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [], max_inflight: Lab.max_inflight }, |_| LabApp.main({}))
		.with_workers([LabApp.primes(Unlimited).registration(), LabApp.tiles(Unlimited).registration(), LabApp.crasher(Unlimited).registration()])

	heartbeat_ms : U32
	heartbeat_ms = 200

	## The requests for what a row wants.
	plan : Lab.Want -> List(Engine.Req)
	plan = |want|
		match want {
			Hold => []
			Run({ task, deadline, .. }) =>
				match task {
					Count(range) => [LabApp.primes(deadline).request(range)]
					Crash(range) => [LabApp.crasher(deadline).request(range)]
					Tile(spec) => [LabApp.tiles(deadline).request(spec)]
				}
		}

	## A row's result: decode it with the task that ran, and finish the job.
	react : Lab.S, Lab.Want, Engine.Res -> Lab.S
	react = |s, want, res|
		match want {
			Hold => s
			Run({ run, index, attempt, task, .. }) => {
				outcome =
					match task {
						Count(_) => LabApp.primes(Unlimited).result(res).map_ok(|n| Primes(n))
						Crash(_) => LabApp.crasher(Unlimited).result(res).map_ok(|n| Primes(n))
						Tile(_) => LabApp.tiles(Unlimited).result(res).map_ok(|bytes| Tile(Lab.summarize(bytes.to_list())))
					}
				Lab.finish(s, { run, index, attempt }, outcome)
			}
		}

	## One label-and-number metric; the `test_id` sits on the value.
	metric : Str, Str, Val(ctx, Str) -> Elem(ctx)
	metric = |id, label, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value numeric"), Engine.test_id(id), Html.aria_label(label)])])

	## A labelled number box that edits one parameter.
	field : Str, Val(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	field = |label, value, h| Html.div("field", [Html.p(label, "field-label"), Html.number_input(Engine.const(label), value, [Engine.class("input w-28")], h)])

	job_row : State(Ctx, Lab.S), RowRef(Ctx, Lab.Job) -> Elem(Row(Ctx, Lab.Job))
	job_row = |st0, row| {
		st = st0.lift_row()
		key = row.key()
		phase = row.field(|j| j.phase)
		Html.li(
			[Engine.class("card flex flex-wrap items-center justify-between gap-2 py-2"), Html.aria_label_v(key.map(|k| "Job ${k}"))],
			[
				Html.div(
					"grid min-w-0 gap-0.5",
					[
						Html.p_v(key.map(|k| "Job ${k}"), [Engine.class("card-title")]),
						Html.p_v(row.field(|j| Lab.describe(j.task)), [Engine.class("hint numeric")]),
					],
				),
				Html.span_v(phase.map(Lab.phase_text), [Engine.class_v(phase.map(Lab.phase_class)), Engine.test_id_v(key.map(|k| "job-${k}"))]),
				Engine.latest(row.field(Lab.want_of), LabApp.plan, st.on_result(LabApp.react)),
			],
		)
	}

	controls : State(Ctx, Lab.S) -> Elem(Ctx)
	controls = |st| {
		v = st.val()
		Html.section(
			"Run",
			"panel grid gap-4 p-5",
			[
				Html.h2("Run", "panel-title"),
				Html.div(
					"flex flex-wrap items-end gap-4",
					[
						Html.div(
							"field",
							[
								Html.p("Workload", "field-label"),
								Html.select(
									Engine.const("Workload"),
									v.map(|s| Lab.workload_to_str(s.workload)),
									[Engine.class("input")],
									[Html.option("primes", "Count primes"), Html.option("tiles", "Draw tiles"), Html.option("faulty", "Count primes, every fourth job crashing")],
									st.set_value(
										|s, text| Lab.edited({
											..s,
											workload: Lab.workload_from_str(text),
										}),
									),
								),
							],
						),
						LabApp.field(
							"Jobs",
							v.map(|s| s.jobs_text),
							st.set_value(
								|s, text| Lab.edited({
									..s,
									jobs_text: text,
								}),
							),
						),
						LabApp.field(
							"Weight",
							v.map(|s| s.weight_text),
							st.set_value(
								|s, text| Lab.edited({
									..s,
									weight_text: text,
								}),
							),
						),
						LabApp.field(
							"Deadline (ms)",
							v.map(|s| s.deadline_text),
							st.set_value(
								|s, text| Lab.edited({
									..s,
									deadline_text: text,
								}),
							),
						),
					],
				),
				Html.p_v(v.map(Lab.problem), [Engine.class("hint text-red-700"), Engine.test_id("problem")]),
				Html.div(
					"toolbar",
					[
						Html.action_button(Engine.const("Start"), v.map(|s| Lab.problem(s) != ""), [Engine.class("button-primary")], st.update(Lab.start)),
						Html.action_button(Engine.const("Cancel"), v.map(|s| !Lab.active(s)), [Engine.class("button")], st.update(Lab.cancel)),
						Html.action_button(Engine.const("Reset"), v.map(|s| s.jobs.is_empty()), [Engine.class("button-ghost")], st.update(Lab.reset)),
					],
				),
				Html.p(
					"Weight sets each job's size: ${Lab.numbers_per_weight.to_str()} numbers to test, or ${Lab.pixels_per_weight.to_str()} pixels along a tile's side. At most ${Lab.window.to_str()} jobs are in flight at once (the program's bound of ${Lab.max_inflight.to_str()} requests, less the heartbeat's); the rest wait their turn. Changing a parameter during a run restarts it, and the old run's jobs stop.",
					"hint",
				),
			],
		)
	}

	## The heartbeat has its own layer, so its ticks touch nothing else.
	heartbeat : {} -> Elem(ctx)
	heartbeat = |_| Engine.state(
		0.U64,
		|beats| Html.div(
			"stat",
			[
				Html.p("Heartbeat", "stat-label"),
				Html.p_v(beats.val().map(|n| n.to_str()), [Engine.class("stat-value numeric"), Engine.test_id("heartbeat"), Html.aria_label("Heartbeat")]),
				Engine.watch(Engine.const({}), |_| [Interval(LabApp.heartbeat_ms)], beats.on_result(|n, _, _| n + 1)),
			],
		),
	)

	totals : Val(In(Ctx, Lab.Tally), Lab.Tally) -> Elem(In(Ctx, Lab.Tally))
	totals = |t| Html.section(
		"Totals",
		"panel grid gap-4 p-5",
		[
			Html.h2("Totals", "panel-title"),
			Html.div(
				"stat-grid",
				[
					LabApp.heartbeat({}),
					LabApp.metric("done", "Done", t.map(|x| x.done.to_str())),
					LabApp.metric("running", "Running", t.map(|x| x.running.to_str())),
					LabApp.metric("waiting", "Waiting", t.map(|x| x.waiting.to_str())),
					LabApp.metric("stopped", "Timed out, lost or cancelled", t.map(|x| (x.timed_out + x.lost + x.cancelled).to_str())),
					LabApp.metric("primes", "Primes found", t.map(|x| x.primes.to_str())),
					LabApp.metric("tile-bytes", "Tile bytes received", t.map(|x| x.tile_bytes.to_str())),
					LabApp.metric("checksum", "Checksum", t.map(Lab.checksum_text)),
				],
			),
			Html.p_v(t.map(Lab.progress_text), [Engine.class("hint"), Engine.test_id("progress")]),
		],
	)

	page : State(Ctx, Lab.S) -> Elem(Ctx)
	page = |st| {
		v = st.val()
		Html.div(
			"app-shell",
			[
				Html.section(
					"Worker Lab",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Worker Lab")]),
						Html.p("Roc tasks counting primes and drawing tiles of the Mandelbrot set in Web Workers, while the page keeps its heartbeat.", "app-subtitle"),
					],
				),
				LabApp.controls(st),
				Engine.derive(v.map(|s| Lab.tally(s.jobs)), LabApp.totals),
				Engine.element("worker-pool-panel", [Engine.class("block"), Engine.attr("role", "region"), Html.aria_label("Worker pool"), Engine.test_id("pool-panel")], []),
				Html.p_v(v.map(|s| "Refused at the in-flight bound and retried: ${s.refused.to_str()}"), [Engine.class("hint"), Engine.test_id("refused")]),
				Html.ul([Engine.class("grid gap-2"), Html.aria_label("Jobs")], [Engine.each(v.map(|s| s.jobs), |j| (j.index + 1).to_str(), |row| LabApp.job_row(st, row))]),
			],
		)
	}

	main : {} -> Elem(Root)
	main = |_| Engine.state(Lab.initial, LabApp.page)
}
