import pf.Engine exposing [Elem, File, Row, Signal, State]
import pf.Html
import pf.Worker
import pf.Wire
import Lab
import LabStore
import Picture

## Worker Lab: a run of CPU-bound jobs, each computed by a Roc task
## in a Web Worker while the page stays responsive. Here a run is a batch:
## the jobs one press of "Start" asks for with one set of parameters (one
## execution of a task is a job, as everywhere else).
##
## The run is the page's store (`LabStore`). Its jobs are a table by index,
## and the job grid is a view of it: each row is handed its own job, and a
## job's answer wakes that row and the row it admits, not the grid.
##
## Each row of the job grid owns its job: the row's `Engine.watch_latest` site
## issues the typed request for its job while the job is running and gives it
## up when the job stops wanting it. So cancelling a run, or changing a
## parameter while it goes (which restarts it), stops the superseded work in
## the workers, and a reset disposes the rows and their jobs with them. The
## grid draws every job for that reason: a row a window left out would have
## no site to ask for its job.
##
## "Running" means the page has handed the job to the runtime: with more jobs
## in flight than workers, the runtime queues the rest, which the pool panel
## shows. The heartbeat is an interval the engine delivers; it keeps counting
## while the workers compute, and stalls when a computation holds the page's
## own thread (mount the app with `workers: "inline"` to see it).
##
## A drawing's jobs are strips. A row whose strip is drawn asks, with a
## second `latest` site, for a URL that shows the strip's file, and the
## picture panel lays the strips out as they arrive, in whatever order the
## workers finish them: its bands are a second view of the jobs' table, the
## strips alone. When every strip is drawn, a `Worker.resource_when` asks one
## more job to compose them; the picture it answers is shown, its digest
## taken, and a click saves it.
##
## The pool panel is a `worker-pool-panel` element that
## `examples/shared/pool-panel.mjs`, which the page loads, defines and draws
## from the runtime's monitor. To the
## engine it is an ordinary empty element.
##
## The picture's tasks build files, so they live in `Picture`, beside the
## platform's `Files` module they use.
LabApp := [].{

	## The composed picture, as the layer that asks for it holds it.
	Composed : Engine.Remote(File, Worker.Error([TooLarge]))

	## The URL that shows the composed picture.
	Link : [NoLink, Link(Str), Unlinked(Str)]

	## The composed picture's SHA-256 digest, in hex.
	Sum : [NoSum, Sum(Str), Unsummed(Str)]

	## Counts the primes in a range. The lab's timeout is a parameter of
	## each run, so each task is made with the timeout its jobs ask for;
	## the name and function, and so the registration, are the same for all.
	primes : [Unlimited, Ms(U32)] -> Worker.Task(Lab.Span, U64, Worker.Never)
	primes = |timeout| Worker.task({
		name: "roc-signals.example/worker-lab/primes",
		run!: |span| Ok(Lab.count_primes(span)),
		timeout,
	})

	## Draws one tile; its pixels come back as one block of bytes.
	tiles : [Unlimited, Ms(U32)] -> Worker.Task(Lab.TileSpec, Wire.Bytes, Worker.Never)
	tiles = |timeout| Worker.task({
		name: "roc-signals.example/worker-lab/tile",
		run!: |spec| Ok(Wire.Bytes.from_list(Lab.tile(spec))),
		timeout,
	})

	## A task that always crashes, for the faulty workload; its message
	## names the range it was given.
	crasher : [Unlimited, Ms(U32)] -> Worker.Task(Lab.Span, U64, Worker.Never)
	crasher = |timeout| Worker.task({
		name: "roc-signals.example/worker-lab/crash",
		run!: |{ lo, hi }| crash "the worker lab's crash task crashed on [${lo.to_str()}, ${hi.to_str()}), as it always does",
		timeout,
	})

	## The lab's program.
	program : Engine.Program
	program =
		Engine.program_store({ storage_keys: [], max_inflight: Lab.max_inflight }, |_boot| LabStore.store, |_boot| LabApp.page({}))
			.with_workers([LabApp.primes(Unlimited).registration(), LabApp.tiles(Unlimited).registration(), LabApp.crasher(Unlimited).registration(), Picture.strip(Unlimited).registration(), Picture.compose.registration()])

	heartbeat_ms : U32
	heartbeat_ms = 200

	## The page's clock while strips are drawn.
	clock_ms : U32
	clock_ms = 100

	## The requests for what a row wants.
	plan : Lab.Want -> List(Engine.Request)
	plan = |want|
		match want {
			Hold => []
			Run({ task, timeout, .. }) =>
				match task {
					Count(range) => [LabApp.primes(timeout).request(range)]
					Crash(range) => [LabApp.crasher(timeout).request(range)]
					Tile(spec) => [LabApp.tiles(timeout).request(spec)]
					Strip(spec) => [Picture.strip(timeout).request(spec)]
				}
		}

	## A strip's own error, described.
	strip_ended : Worker.Error([TooLarge]) -> Lab.Ended
	strip_ended = |error|
		match error {
			Failed(TooLarge) => Failed("larger than a job may write")
			Timeout => Timeout
			Refused => Refused
			Lost(fault) => Lost(fault)
		}

	## A job's result, decoded with the task that ran.
	outcome : Lab.Task, Engine.Result -> Try(Lab.Answer, Lab.Ended)
	outcome = |task, res|
		match task {
			Count(_) => LabApp.primes(Unlimited).result(res).map_ok(|n| Primes(n)).map_err(Lab.ended)
			Crash(_) => LabApp.crasher(Unlimited).result(res).map_ok(|n| Primes(n)).map_err(Lab.ended)
			Tile(_) => LabApp.tiles(Unlimited).result(res).map_ok(|bytes| Tile(Lab.summarize(bytes.to_list()))).map_err(Lab.ended)
			Strip(_) => Picture.strip(Unlimited).result(res).map_ok(Lab.drawn).map_err(LabApp.strip_ended)
		}

	## What a row's result writes, decided from the row's job as it is when
	## the result arrives.
	answered : Lab.Job, Lab.Want, Engine.Result -> List(Engine.Write(_))
	answered = |job, want, res|
		match want {
			Hold => []
			Run({ run, attempt, task, .. }) => LabStore.finished(job, { run, attempt }, LabApp.outcome(task, res))
		}

	## The request for a drawn strip's URL.
	plan_url : Lab.UrlWant -> List(Engine.Request)
	plan_url = |want|
		match want {
			Show({ file, .. }) => [file.object_url()]
			Hold => []
		}

	## What a strip's URL, or the lack of one, writes.
	url_answered : Lab.Job, Lab.UrlWant, Engine.Result -> List(Engine.Write(_))
	url_answered = |job, want, res|
		match want {
			Show({ run, attempt, .. }) => LabStore.shown(job, { run, attempt }, Engine.file_url(res).map_err(Lab.file_error_text))
			Hold => []
		}

	## One label-and-number metric; the `test_id` sits on the value.
	metric : Str, Str, Signal(ctx, Str) -> Elem(ctx)
	metric = |id, label, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_s(value, [Engine.class("stat-value numeric"), Engine.test_id(id), Html.aria_label(label)])])

	## A labelled number box that edits one parameter.
	field : Str, Signal(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	field = |label, value, h| Html.div("field", [Html.p(label, "field-label"), Html.number_input(Engine.const(label), value, [Engine.class("input w-28")], h)])

	## One row of the job grid, handed its own job: what it is, where it
	## is, and the two sites that ask for its work and for its strip's URL.
	## Their answers are decisions over the table, since finishing one job
	## admits another.
	job_row : Signal(Row(ctx, U64), U64), State(Row(ctx, U64), Lab.Job) -> Elem(Row(ctx, U64))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	job_row = |index, held| {
		job = held.signal()
		number = index.map(|i| (i + 1).to_str())
		phase = job.map(|j| j.phase)
		Html.li(
			[Engine.class("card flex flex-wrap items-center justify-between gap-2 py-2"), Html.aria_label_s(number.map(|k| "Job ${k}"))],
			[
				Html.div(
					"grid min-w-0 gap-0.5",
					[
						Html.p_s(number.map(|k| "Job ${k}"), [Engine.class("card-title")]),
						Html.p_s(job.map(|j| Lab.describe(j.task)), [Engine.class("hint numeric")]),
					],
				),
				Html.span_s(phase.map(Lab.phase_text), [Engine.class_s(phase.map(Lab.phase_class)), Engine.test_id_s(number.map(|k| "job-${k}"))]),
				Engine.watch_latest(job.map(Lab.want_of), LabApp.plan, Engine.react_by(job, LabApp.answered)),
				Engine.watch_latest(job.map(Lab.url_want), LabApp.plan_url, Engine.react_by(job, LabApp.url_answered)),
			],
		)
	}

	## The run's parameters and its buttons. The parameters as typed are
	## this panel's own state: a keystroke writes it, and in the same event
	## the store's decision restarts a run that is going.
	controls : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	controls = |{}| Engine.state(
		Lab.form,
		|form| {
			cells = LabStore.cells
			typed = form.signal()
			jobs = cells.work.jobs.signal()
			restart = Engine.handle_by({ typed, run: cells.run.signal(), going: jobs.map(Lab.active) }.Signal, |at, _| LabStore.edited(at))
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
										typed.map(|f| Lab.workload_to_str(f.workload)),
										[Engine.class("input")],
										[Html.option("primes", "Count primes"), Html.option("tiles", "Draw tiles"), Html.option("faulty", "Count primes, every fourth job crashing"), Html.option("draw", "Draw the Mandelbrot set")],
										form.set_value(|f, text| { ..f, workload: Lab.workload_from_str(text) }).also(restart),
									),
								],
							),
							LabApp.field("Jobs", typed.map(|f| f.jobs_text), form.set_value(|f, text| { ..f, jobs_text: text }).also(restart)),
							LabApp.field("Weight", typed.map(|f| f.weight_text), form.set_value(|f, text| { ..f, weight_text: text }).also(restart)),
							LabApp.field("Timeout (ms)", typed.map(|f| f.timeout_text), form.set_value(|f, text| { ..f, timeout_text: text }).also(restart)),
						],
					),
					Html.p_s(typed.map(Lab.problem), [Engine.class("hint text-red-700"), Engine.test_id("problem")]),
					Html.div(
						"toolbar",
						[
							Html.action_button(Engine.const("Start"), typed.map(|f| Lab.problem(f) != ""), [Engine.class("button-primary")], Engine.handle_by({ typed, run: cells.run.signal() }.Signal, |at, _| LabStore.started(at.typed, at.run))),
							Html.action_button(Engine.const("Cancel"), jobs.map(|table| !Lab.active(table)), [Engine.class("button")], Engine.does(LabStore.cancelled)),
							Html.action_button(Engine.const("Retry stopped jobs"), jobs.map(|table| !Lab.any_job(table, Lab.is_stopped)), [Engine.class("button")], Engine.does(LabStore.retried)),
							Html.action_button(Engine.const("Reset"), jobs.map(|table| table.len() == 0), [Engine.class("button-ghost")], Engine.does([cells.work.reset])),
						],
					),
					Html.p(
						"Weight sets each job's size: ${Lab.numbers_per_weight.to_str()} numbers to test, or ${Lab.pixels_per_weight.to_str()} pixels along a tile's side. For a picture, Jobs is its number of strips (at most ${Lab.max_strips.to_str()}) and Weight its width, ${Lab.pixels_per_draw_weight.to_str()} pixels each (at most ${Lab.max_draw_weight.to_str()}). At most ${Lab.window.to_str()} jobs are in flight at once (the program's bound of ${Lab.max_inflight.to_str()} requests, less the heartbeat's); the rest wait their turn. Changing a parameter during a run restarts it, and the old run's jobs stop.",
						"hint",
					),
				],
			)
		},
	)

	## The heartbeat has its own layer, so its ticks touch nothing else.
	heartbeat : {} -> Elem(ctx)
	heartbeat = |_| Engine.state(
		0.U64,
		|beats| Html.div(
			"stat",
			[
				Html.p("Heartbeat", "stat-label"),
				Html.p_s(beats.signal().map(|n| n.to_str()), [Engine.class("stat-value numeric"), Engine.test_id("heartbeat"), Html.aria_label("Heartbeat")]),
				Engine.watch(Engine.const({}), |_| [Interval(LabApp.heartbeat_ms)], beats.on_result(|n, _, _| n + 1)),
			],
		),
	)

	totals : Signal(ctx, Lab.Tally) -> Elem(ctx)
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
					LabApp.metric("stopped", "Timed out, lost, failed or cancelled", t.map(|x| (x.timed_out + x.lost + x.failed + x.cancelled).to_str())),
					LabApp.metric("primes", "Primes found", t.map(|x| x.primes.to_str())),
					LabApp.metric("tile-bytes", "Tile bytes received", t.map(|x| x.tile_bytes.to_str())),
					LabApp.metric("checksum", "Checksum", t.map(Lab.checksum_text)),
				],
			),
			Html.p_s(t.map(Lab.progress_text), [Engine.class("hint"), Engine.test_id("progress")]),
		],
	)

	# ---------------------------------------------------------------- picture

	## One band of the picture, handed its strip's job: the strip once it
	## has a URL, and until then a placeholder of the strip's shape that
	## says where the strip is.
	band : Signal(Row(ctx, U64), U64), State(Row(ctx, U64), Lab.Job) -> Elem(Row(ctx, U64))
	band = |index, held| {
		job = held.signal()
		look = job.map(|j| Lab.look_of(j.phase))
		number = index.map(|i| (i + 1).to_str())
		Engine.element(
			"div",
			[Engine.class_s(look.map(Lab.look_class)), Engine.attr_s("style", job.map(Lab.strip_style)), Engine.test_id_s(number.map(|k| "strip-${k}"))],
			[
				Engine.when(
					look.map(|l| Lab.look_url(l) != ""),
					|| Engine.element("img", [Engine.attr_s("src", look.map(Lab.look_url)), Engine.attr_s("alt", number.map(|k| "Strip ${k}")), Engine.class("block w-full"), Engine.test_id_s(number.map(|k| "strip-image-${k}"))], []),
					|| Engine.text_s(look.map(Lab.look_text)),
				),
			],
		)
	}

	## The picture's bands, top first: the strips among the run's jobs.
	bands : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	bands = |{}| Html.div(
		"grid",
		[Engine.table_view(LabStore.cells.work.jobs, { query: Engine.const(Strips), plan: Lab.listed, window: Engine.const(Engine.every_row) }, LabApp.band)],
	)

	## The composed picture, when it is answered.
	picture_file : Composed -> [Run(File), Skip]
	picture_file = |remote|
		match remote.answered() {
			Ok(file) => Run(file)
			Err(NoAnswer) => Skip
		}

	## A layer holding the URL that shows the composed picture.
	link_of : { init : Link, pending : (Link, [Run(File), Skip] -> Link), plan : ([Run(File), Skip] -> List(Engine.Request)), resolve : (Link, [Run(File), Skip], Engine.Result -> Link) }
	link_of = {
		init: NoLink,
		pending: |_, _| NoLink,
		plan: |picked|
			match picked {
				Run(file) => [file.object_url()]
				Skip => []
			},
		resolve: |_, _, res|
			match Engine.file_url(res) {
				Ok(url) => Link(url)
				Err(e) => Unlinked(Lab.file_error_text(e))
			},
	}

	## A layer holding the composed picture's digest.
	sum_of : { init : Sum, pending : (Sum, [Run(File), Skip] -> Sum), plan : ([Run(File), Skip] -> List(Engine.Request)), resolve : (Sum, [Run(File), Skip], Engine.Result -> Sum) }
	sum_of = {
		init: NoSum,
		pending: |_, _| NoSum,
		plan: |picked|
			match picked {
				Run(file) => [file.sha256()]
				Skip => []
			},
		resolve: |_, _, res|
			match Engine.file_digest(res) {
				Ok(bytes) => Sum(Lab.hex_bytes(bytes))
				Err(e) => Unsummed(Lab.file_error_text(e))
			},
	}

	link_url : Link -> Str
	link_url = |link|
		match link {
			Link(url) => url
			_ => ""
		}

	## What the panel says about the composed picture.
	composed_text : Composed -> Str
	composed_text = |remote|
		match Worker.status(remote) {
			Unasked => ""
			Working => "Composing the picture"
			Answered(file) => "${file.name()}, ${file.size().to_str()} bytes"
			Failed(TooLarge) => "The picture is larger than a job may write."
			Timeout => "The picture was not composed: it timed out."
			Refused => "The picture was not composed: too many requests were in flight."
			Lost(fault) => "The picture was not composed: ${Lab.fault_text(fault)}."
		}

	sum_text : Sum -> Str
	sum_text = |sum|
		match sum {
			NoSum => ""
			Sum(hex) => "SHA-256 ${hex}"
			Unsummed(why) => "No digest: ${why}"
		}

	## The picture once composed and linked, the bands until then, and what
	## it is, with a button that saves it.
	shown : Signal(ctx, Composed), Signal(ctx, Link), Signal(ctx, Sum) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	shown = |r, link, sum|
		Html.div(
			"grid gap-3",
			[
				Engine.when(
					link.map(|l| LabApp.link_url(l) != ""),
					|| Engine.element("img", [Engine.attr_s("src", link.map(LabApp.link_url)), Engine.attr("alt", "The Mandelbrot set, composed from its strips"), Engine.class("block w-full"), Engine.test_id("picture-image")], []),
					|| LabApp.bands({}),
				),
				Html.p_s(r.map(LabApp.composed_text), [Engine.class("hint"), Engine.test_id("composed")]),
				Html.p_s(sum.map(LabApp.sum_text), [Engine.class("hint break-all font-mono"), Engine.test_id("digest")]),
				Html.action_button(
					Engine.const("Save picture"),
					r.map(|remote| remote.answered().is_err()),
					[Engine.class("button justify-self-start")],
					Engine.handle_by(
						r,
						|remote, _|
							match remote.answered() {
								Ok(file) => LabStore.saved(file)
								Err(NoAnswer) => []
							},
					),
				),
			],
		)

	## The picture panel: the strips as they arrive, then the composed
	## picture, its digest and a button that saves it, and the page's clock
	## while strips are drawn.
	picture : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	picture = |{}| {
		cells = LabStore.cells
		jobs = cells.work.jobs.signal()
		drawing = jobs.map(Lab.drawing)
		Html.section(
			"Picture",
			"panel grid content-start gap-4 p-5",
			[
				Html.h2("Picture", "panel-title"),
				Html.p_s(jobs.map(Lab.picture_text), [Engine.class("hint"), Engine.test_id("picture")]),
				Worker.resource_when(
					Picture.compose,
					jobs.map(Lab.composition),
					|r| {
						picked = r.map(LabApp.picture_file)
						Engine.resource(
							picked,
							LabApp.link_of,
							|link| Engine.resource(
								picked.lift(),
								LabApp.sum_of,
								|sum| LabApp.shown(r.lift().lift(), link.lift(), sum),
							),
						)
					},
				),
				LabApp.metric("draw-ticks", "Page clock ticks while drawing, one per ${LabApp.clock_ms.to_str()} ms", jobs.map2(cells.work.ticks.signal(), Lab.ticks_text)),
				Html.p(
					"Each strip is drawn by a worker and shown as soon as it arrives, so the picture fills in in the order the workers finish. The pool panel's links mount the page again with another pool size, which starts any drawing over. With the page's own thread (inline) no strip can be drawn: building a file needs a worker.",
					"hint",
				),
				# `latest`, not `watch`: the clock must stop when drawing does.
				Engine.watch_latest(
					drawing,
					|on| if (on) [Interval(LabApp.clock_ms)] else [],
					Engine.react_by(drawing, |still, _, _| LabStore.ticked(still)),
				),
			],
		)
	}

	page : {} -> Elem(Engine.StoreRoot(_))
	page = |{}| {
		cells = LabStore.cells
		Html.div(
			"app-shell",
			[
				Html.section(
					"Worker Lab",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Worker Lab")]),
						Html.p("Roc tasks counting primes and drawing the Mandelbrot set in Web Workers, while the page keeps its heartbeat.", "app-subtitle"),
					],
				),
				LabApp.controls({}),
				Engine.derive(cells.work.jobs.signal().map(Lab.tally), LabApp.totals),
				Html.div(
					"grid items-start gap-4 lg:grid-cols-2",
					[
						LabApp.picture({}),
						Engine.element("worker-pool-panel", [Engine.class("block"), Engine.attr("role", "region"), Html.aria_label("Worker pool"), Engine.test_id("pool-panel")], []),
					],
				),
				Engine.on_post(cells.work.save.signal(), |file| [File.save(file, {})], Engine.ignore({})),
				Html.p_s(cells.work.refused.signal().map(|count| "Refused at the in-flight bound and retried: ${count.to_str()}"), [Engine.class("hint"), Engine.test_id("refused")]),
				Html.ul(
					[Engine.class("grid gap-2"), Html.aria_label("Jobs")],
					[Engine.table_view(cells.work.jobs, { query: Engine.const(Every), plan: Lab.listed, window: Engine.const(Engine.every_row) }, LabApp.job_row)],
				),
			],
		)
	}
}
