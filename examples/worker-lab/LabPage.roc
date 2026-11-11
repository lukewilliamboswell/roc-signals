import pf.Engine exposing [Elem, File, In, Root, Row, RowRef, State, Val]
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
## A drawing's jobs are strips. A row whose strip is drawn asks, with a
## second `latest` site, for a URL that shows the strip's file, and the
## picture panel lays the strips out as they arrive, in whatever order the
## workers finish them. When every strip is drawn, a `Worker.derive_when`
## asks one more job to compose them; the picture it answers is shown, its
## digest taken, and a click saves it.
##
## The pool panel is a `worker-pool-panel` element that
## `examples/shared/pool-panel.mjs`, which the page loads, defines and draws
## from the runtime's monitor. To the
## engine it is an ordinary empty element.
##
## The picture's tasks build files, so they come from outside (`Draw`):
## `LabApp` passes the real ones from `Picture`, and the fuzz target, which
## cannot import the platform's `Files` module, passes stand-ins.
LabPage := [].{
	Ctx : In(Root, Lab.S)

	## The tasks that draw a picture: a strip per deadline, and the
	## composition of every strip into one picture.
	Draw : { strip : [Unlimited, Ms(U32)] -> Worker.Task(Lab.StripSpec, Lab.Drawn, [TooLarge]), compose : Worker.Task(Lab.Composition, File, [TooLarge]) }

	## The composed picture, as the layer that asks for it holds it.
	Composed : Engine.Remote(File, Worker.Error([TooLarge]))

	## The URL that shows the composed picture.
	Link : [NoLink, Link(Str), Unlinked(Str)]

	## The composed picture's SHA-256 digest, in hex.
	Sum : [NoSum, Sum(Str), Unsummed(Str)]

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

	## The lab's program, with the picture's tasks `draw`.
	program : Draw -> Engine.Program
	program = |draw|
		Engine.program_boot({ storage_keys: [], max_inflight: Lab.max_inflight }, |_| LabPage.main(draw))
			.with_workers([LabPage.primes(Unlimited).registration(), LabPage.tiles(Unlimited).registration(), LabPage.crasher(Unlimited).registration(), (draw.strip)(Unlimited).registration(), draw.compose.registration()])

	heartbeat_ms : U32
	heartbeat_ms = 200

	## The page's clock while strips are drawn.
	clock_ms : U32
	clock_ms = 100

	## The requests for what a row wants.
	plan : Draw -> (Lab.Want -> List(Engine.Req))
	plan = |draw| |want|
		match want {
			Hold => []
			Run({ task, deadline, .. }) =>
				match task {
					Count(range) => [LabPage.primes(deadline).request(range)]
					Crash(range) => [LabPage.crasher(deadline).request(range)]
					Tile(spec) => [LabPage.tiles(deadline).request(spec)]
					Strip(spec) => [(draw.strip)(deadline).request(spec)]
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

	## A row's result: decode it with the task that ran, and finish the job.
	react : Draw -> (Lab.S, Lab.Want, Engine.Res -> Lab.S)
	react = |draw| |s, want, res|
		match want {
			Hold => s
			Run({ run, index, attempt, task, .. }) => {
				outcome =
					match task {
						Count(_) => LabPage.primes(Unlimited).result(res).map_ok(|n| Primes(n)).map_err(Lab.ended)
						Crash(_) => LabPage.crasher(Unlimited).result(res).map_ok(|n| Primes(n)).map_err(Lab.ended)
						Tile(_) => LabPage.tiles(Unlimited).result(res).map_ok(|bytes| Tile(Lab.summarize(bytes.to_list()))).map_err(Lab.ended)
						Strip(_) => (draw.strip)(Unlimited).result(res).map_ok(Lab.drawn).map_err(LabPage.strip_ended)
					}
				Lab.finish(s, { run, index, attempt }, outcome)
			}
		}

	## The request for a drawn strip's URL.
	plan_url : Lab.UrlWant -> List(Engine.Req)
	plan_url = |want|
		match want {
			Show({ file, .. }) => [file.object_url()]
			Hold => []
		}

	## A strip's URL, or why there is none.
	react_url : Lab.S, Lab.UrlWant, Engine.Res -> Lab.S
	react_url = |s, want, res|
		match want {
			Show({ run, index, attempt, .. }) => Lab.shown(s, { run, index, attempt }, Engine.file_url(res).map_err(Lab.file_error_text))
			Hold => s
		}

	## One label-and-number metric; the `test_id` sits on the value.
	metric : Str, Str, Val(ctx, Str) -> Elem(ctx)
	metric = |id, label, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value numeric"), Engine.test_id(id), Html.aria_label(label)])])

	## A labelled number box that edits one parameter.
	field : Str, Val(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	field = |label, value, h| Html.div("field", [Html.p(label, "field-label"), Html.number_input(Engine.const(label), value, [Engine.class("input w-28")], h)])

	job_row : Draw, State(Ctx, Lab.S), RowRef(Ctx, Lab.Job) -> Elem(Row(Ctx, Lab.Job))
	job_row = |draw, st0, row| {
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
				Engine.latest(row.field(Lab.want_of), LabPage.plan(draw), st.on_result(LabPage.react(draw))),
				Engine.latest(row.field(Lab.url_want), LabPage.plan_url, st.on_result(LabPage.react_url)),
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
									[Html.option("primes", "Count primes"), Html.option("tiles", "Draw tiles"), Html.option("faulty", "Count primes, every fourth job crashing"), Html.option("draw", "Draw the Mandelbrot set")],
									st.set_value(
										|s, text| Lab.edited({
											..s,
											workload: Lab.workload_from_str(text),
										}),
									),
								),
							],
						),
						LabPage.field(
							"Jobs",
							v.map(|s| s.jobs_text),
							st.set_value(
								|s, text| Lab.edited({
									..s,
									jobs_text: text,
								}),
							),
						),
						LabPage.field(
							"Weight",
							v.map(|s| s.weight_text),
							st.set_value(
								|s, text| Lab.edited({
									..s,
									weight_text: text,
								}),
							),
						),
						LabPage.field(
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
						Html.action_button(Engine.const("Retry stopped jobs"), v.map(|s| !s.jobs.any(Lab.is_stopped)), [Engine.class("button")], st.update(Lab.retry)),
						Html.action_button(Engine.const("Reset"), v.map(|s| s.jobs.is_empty()), [Engine.class("button-ghost")], st.update(Lab.reset)),
					],
				),
				Html.p(
					"Weight sets each job's size: ${Lab.numbers_per_weight.to_str()} numbers to test, or ${Lab.pixels_per_weight.to_str()} pixels along a tile's side. For a picture, Jobs is its number of strips (at most ${Lab.max_strips.to_str()}) and Weight its width, ${Lab.pixels_per_draw_weight.to_str()} pixels each (at most ${Lab.max_draw_weight.to_str()}). At most ${Lab.window.to_str()} jobs are in flight at once (the program's bound of ${Lab.max_inflight.to_str()} requests, less the heartbeat's); the rest wait their turn. Changing a parameter during a run restarts it, and the old run's jobs stop.",
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
				Engine.watch(Engine.const({}), |_| [Interval(LabPage.heartbeat_ms)], beats.on_result(|n, _, _| n + 1)),
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
					LabPage.heartbeat({}),
					LabPage.metric("done", "Done", t.map(|x| x.done.to_str())),
					LabPage.metric("running", "Running", t.map(|x| x.running.to_str())),
					LabPage.metric("waiting", "Waiting", t.map(|x| x.waiting.to_str())),
					LabPage.metric("stopped", "Timed out, lost, failed or cancelled", t.map(|x| (x.timed_out + x.lost + x.failed + x.cancelled).to_str())),
					LabPage.metric("primes", "Primes found", t.map(|x| x.primes.to_str())),
					LabPage.metric("tile-bytes", "Tile bytes received", t.map(|x| x.tile_bytes.to_str())),
					LabPage.metric("checksum", "Checksum", t.map(Lab.checksum_text)),
				],
			),
			Html.p_v(t.map(Lab.progress_text), [Engine.class("hint"), Engine.test_id("progress")]),
		],
	)

	# ---------------------------------------------------------------- picture

	## One band of the picture: its strip once it has a URL, and until then
	## a placeholder of the strip's shape that says where the strip is.
	band : RowRef(ctx, Lab.Band) -> Elem(Row(ctx, Lab.Band))
	band = |row| {
		look = row.field(|b| b.look)
		key = row.key()
		Engine.element(
			"div",
			[Engine.class_v(look.map(Lab.look_class)), Engine.attr_v("style", row.field(Lab.look_style)), Engine.test_id_v(key.map(|k| "strip-${k}"))],
			[
				Engine.when(
					look.map(|l| Lab.look_url(l) != ""),
					|| Engine.element("img", [Engine.attr_v("src", look.map(Lab.look_url)), Engine.attr_v("alt", key.map(|k| "Strip ${k}")), Engine.class("block w-full"), Engine.test_id_v(key.map(|k| "strip-image-${k}"))], []),
					|| Engine.text_v(look.map(Lab.look_text)),
				),
			],
		)
	}

	## The picture's bands, top first.
	bands : Val(ctx, Lab.S) -> Elem(ctx)
	bands = |v| Html.div("grid", [Engine.each(v.map(|s| Lab.bands(s.jobs)), |b| (b.index + 1).to_str(), LabPage.band)])

	## The composed picture, when it is answered.
	picture_file : Composed -> [Run(File), Skip]
	picture_file = |remote|
		match remote.answered() {
			Ok(file) => Run(file)
			Err(NoAnswer) => Skip
		}

	## A layer holding the URL that shows the composed picture.
	link_of : { init : Link, pending : (Link, [Run(File), Skip] -> Link), plan : ([Run(File), Skip] -> List(Engine.Req)), resolve : (Link, [Run(File), Skip], Engine.Res -> Link) }
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
	sum_of : { init : Sum, pending : (Sum, [Run(File), Skip] -> Sum), plan : ([Run(File), Skip] -> List(Engine.Req)), resolve : (Sum, [Run(File), Skip], Engine.Res -> Sum) }
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
	shown : State(ctx, Lab.S), Val(ctx, Lab.S), Val(ctx, Composed), Val(ctx, Link), Val(ctx, Sum) -> Elem(ctx)
	shown = |st, v, r, link, sum|
		Html.div(
			"grid gap-3",
			[
				Engine.when(
					link.map(|l| LabPage.link_url(l) != ""),
					|| Engine.element("img", [Engine.attr_v("src", link.map(LabPage.link_url)), Engine.attr("alt", "The Mandelbrot set, composed from its strips"), Engine.class("block w-full"), Engine.test_id("picture-image")], []),
					|| LabPage.bands(v),
				),
				Html.p_v(r.map(LabPage.composed_text), [Engine.class("hint"), Engine.test_id("composed")]),
				Html.p_v(sum.map(LabPage.sum_text), [Engine.class("hint break-all font-mono"), Engine.test_id("digest")]),
				Html.action_button(
					Engine.const("Save picture"),
					r.map(|remote| remote.answered().is_err()),
					[Engine.class("button justify-self-start")],
					st.update_by(
						r,
						|s, remote|
							match remote.answered() {
								Ok(file) => Lab.keep_to_save(s, file)
								Err(NoAnswer) => s
							},
					),
				),
			],
		)

	## The picture panel: the strips as they arrive, then the composed
	## picture, its digest and a button that saves it, and the page's clock
	## while strips are drawn.
	picture : Draw, State(Ctx, Lab.S) -> Elem(Ctx)
	picture = |draw, st| {
		v = st.val()
		Html.section(
			"Picture",
			"panel grid content-start gap-4 p-5",
			[
				Html.h2("Picture", "panel-title"),
				Html.p_v(v.map(Lab.picture_text), [Engine.class("hint"), Engine.test_id("picture")]),
				Worker.derive_when(
					draw.compose,
					v.map(Lab.composition),
					|r| {
						picked = r.map(LabPage.picture_file)
						Engine.resource(
							picked,
							LabPage.link_of,
							|link| Engine.resource(
								picked.lift(),
								LabPage.sum_of,
								|sum| LabPage.shown(st.lift().lift().lift(), v.lift().lift().lift(), r.lift().lift(), link.lift(), sum),
							),
						)
					},
				),
				LabPage.metric("draw-ticks", "Page clock ticks while drawing, one per ${LabPage.clock_ms.to_str()} ms", v.map(Lab.ticks_text)),
				Html.p(
					"Each strip is drawn by a worker and shown as soon as it arrives, so the picture fills in in the order the workers finish. The pool panel's links mount the page again with another pool size, which starts any drawing over. With the page's own thread (inline) no strip can be drawn: building a file needs a worker.",
					"hint",
				),
				# `latest`, not `watch`: the clock must stop when drawing does.
				Engine.latest(
					v.map(Lab.drawing),
					|on| if (on) [Interval(LabPage.clock_ms)] else [],
					st.on_result(|s, _, _| Lab.tick(s)),
				),
			],
		)
	}

	page : Draw, State(Ctx, Lab.S) -> Elem(Ctx)
	page = |draw, st| {
		v = st.val()
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
				LabPage.controls(st),
				Engine.derive(v.map(|s| Lab.tally(s.jobs)), LabPage.totals),
				Html.div(
					"grid items-start gap-4 lg:grid-cols-2",
					[
						LabPage.picture(draw, st),
						Engine.element("worker-pool-panel", [Engine.class("block"), Engine.attr("role", "region"), Html.aria_label("Worker pool"), Engine.test_id("pool-panel")], []),
					],
				),
				Engine.on_post(v.map(|s| s.save), |file| [File.save(file, {})], Engine.ignore({})),
				Html.p_v(v.map(|s| "Refused at the in-flight bound and retried: ${s.refused.to_str()}"), [Engine.class("hint"), Engine.test_id("refused")]),
				Html.ul([Engine.class("grid gap-2"), Html.aria_label("Jobs")], [Engine.each(v.map(|s| s.jobs), |j| (j.index + 1).to_str(), |row| LabPage.job_row(draw, st, row))]),
			],
		)
	}

	main : Draw -> Elem(Root)
	main = |draw| Engine.state(Lab.initial, |st| LabPage.page(draw, st))
}
