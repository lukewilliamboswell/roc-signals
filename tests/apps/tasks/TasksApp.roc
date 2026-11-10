import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## Tasks test app: worker tasks read the files they are sent through
## effects and answer with files they built, which the page then holds,
## previews, saves and sends on.
##
## - "Upload" gives the app files. "Upper" upper-cases the first one in a
##   worker, four bytes at a time (or 1 MiB, "Upper in 1 MiB chunks"),
##   into a new file; "Overflow" copies it three times, which a small
##   `max-output-bytes` refuses; "Many" answers
##   with 17 files, one more than a job may return, which is a contract
##   error in the job's worker; "Few" answers with three, which a page
##   holding 62 files has no room for.
## - "Square" squares a number and calls no effect, so it answers even
##   where a job's effects are unavailable (`workers: "inline"`).
## - "Add batch" appends a line to a log across jobs: each job starts a
##   builder from the previous log, by reference, and the log in state is
##   replaced only by a delivered answer. "Save log" saves it.
## - "Fetch" downloads `/data.csv` into a file; "Count lines" counts its
##   lines in a task.
## - "Crash", "Twice" (finishing a builder twice) and "Timed" (a deadline)
##   end their jobs without an answer; "Stop" cancels whatever runs.
## - "Panel" mounts two jobs on the first file: one that stops when the
##   panel closes, and one that is kept and answers to the page.
## - `outcome` shows the last answer, `built` the last built file and
##   `preview` its text, read back on the page.
TasksApp := [].{
	S : {
		files : List(File),
		run : Run,
		outcome : Str,
		built : List(File),
		log : List(File),
		batch : U64,
		fetching : [Idle, Get(Str)],
		fetched : List(File),
		save : [Idle, Save(File, Str, U64)],
		saves : U64,
		panel : Bool,
		kept : Str,
	}

	## The job the app wants now; a new value cancels the job of the old.
	Run : [Idle, Upper({ source : File, chunk : U64 }), Append({ previous : List(File), lines : List(Str) }), Count({ file : File, chunk : U64 }), Overflow(File), Crash(File), Twice(U64), Many(U64), Timed(File), Square(U64)]

	## A task that calls no effect.
	square : Worker.Task(U64, U64, Engine.FileError)
	square = Worker.task({ name: "test.roc-signals/tasks/square", run!: |n| Ok(n * n) })

	Outcome(a) : Try(a, Worker.Error(Engine.FileError))

	upper : Worker.Task({ source : File, chunk : U64 }, File, Engine.FileError)
	upper = Worker.task({ name: "test.roc-signals/tasks/upper", run!: TasksApp.upper! })

	## Upper-case `source` into a new file, `chunk` bytes at a time.
	upper! : { source : File, chunk : U64 } => Try(File, Engine.FileError)
	upper! = |{ source, chunk }| {
		out = File.build!({ name: "${source.name()}.upper", mime: Mime("text/plain") })
		var $at = 0.U64
		while $at < source.size() {
			len = if (source.size() - $at < chunk) source.size() - $at else chunk
			bytes = source.read!({ start: $at, len })?
			out.append!(bytes.map(|b| if (b >= 'a' and b <= 'z') b - 32 else b))?
			$at = $at + len
		}
		Ok(out.finish!())
	}

	append : Worker.Task({ previous : List(File), lines : List(Str) }, File, Engine.FileError)
	append = Worker.task({ name: "test.roc-signals/tasks/append", run!: TasksApp.append! })

	## The previous log, by reference, followed by `lines`.
	append! : { previous : List(File), lines : List(Str) } => Try(File, Engine.FileError)
	append! = |{ previous, lines }| {
		start_from = match previous {
			[log] => From(log)
			_ => Empty
		}
		out = File.build!({ name: "log.txt", mime: Mime("text/plain"), start_from })
		for line in lines {
			out.append!("${line}\n".to_utf8())?
		}
		Ok(out.finish!())
	}

	count_lines : Worker.Task({ file : File, chunk : U64 }, U64, Engine.FileError)
	count_lines = Worker.task({ name: "test.roc-signals/tasks/count-lines", run!: TasksApp.count_lines! })

	## The number of newlines in `file`, read `chunk` bytes at a time.
	count_lines! : { file : File, chunk : U64 } => Try(U64, Engine.FileError)
	count_lines! = |{ file, chunk }| {
		var $lines = 0.U64
		var $at = 0.U64
		while $at < file.size() {
			len = if (file.size() - $at < chunk) file.size() - $at else chunk
			bytes = file.read!({ start: $at, len })?
			$lines = $lines + bytes.count_if(|b| b == '\n')
			$at = $at + len
		}
		Ok($lines)
	}

	overflow : Worker.Task(File, File, Engine.FileError)
	overflow = Worker.task({ name: "test.roc-signals/tasks/overflow", run!: TasksApp.overflow! })

	## Three copies of `source`, copied through the job's memory.
	overflow! : File => Try(File, Engine.FileError)
	overflow! = |source| {
		bytes = source.contents!()?
		out = File.build!({ name: "copies.txt" })
		out.append!(bytes)?
		out.append!(bytes)?
		out.append!(bytes)?
		Ok(out.finish!())
	}

	crashes : Worker.Task(File, U64, Engine.FileError)
	crashes = Worker.task({ name: "test.roc-signals/tasks/crash", run!: TasksApp.crashes! })

	## Read the file, then crash.
	crashes! : File => Try(U64, Engine.FileError)
	crashes! = |file| {
		size = file.contents!().map_ok(|bytes| bytes.len()) ?? 0
		crash "the crash task gives up after reading ${size.to_str()} bytes"
	}

	twice : Worker.Task(U64, U64, Engine.FileError)
	twice = Worker.task({ name: "test.roc-signals/tasks/twice", run!: TasksApp.twice! })

	## Finish a builder twice, which is a contract error.
	twice! : U64 => Try(U64, Engine.FileError)
	twice! = |n| {
		out = File.build!({ name: "twice.txt" })
		first = out.finish!()
		second = out.finish!()
		Ok(first.size() + second.size() + n)
	}

	many : Worker.Task(U64, List(File), Engine.FileError)
	many = Worker.task({ name: "test.roc-signals/tasks/many", run!: TasksApp.many! })

	## `n` one-byte files.
	many! : U64 => Try(List(File), Engine.FileError)
	many! = |n| {
		var $files = []
		while $files.len() < n {
			out = File.build!({ name: "part-${$files.len().to_str()}.txt" })
			out.append!(['x'])?
			$files = $files.append(out.finish!())
		}
		Ok($files)
	}

	## The size of a file, as a job reads it: the panel's two jobs and the
	## timed one.
	size! : File => Try(U64, Engine.FileError)
	size! = |file| file.contents!().map_ok(|bytes| bytes.len())

	timed : Worker.Task(File, U64, Engine.FileError)
	timed = Worker.task({ name: "test.roc-signals/tasks/timed", run!: TasksApp.size!, deadline: Ms(5000) })

	stopped : Worker.Task(File, U64, Engine.FileError)
	stopped = Worker.task({ name: "test.roc-signals/tasks/stopped", run!: TasksApp.size! })

	kept : Worker.Task(File, U64, Engine.FileError)
	kept = Worker.task({ name: "test.roc-signals/tasks/kept", run!: TasksApp.size!, on_dispose: Keep })

	Ctx : In(Root, S)

	received : S, Engine.Received -> S
	received = |s, { files, refused: _ }| { ..s, files: s.files.concat(files) }

	## The job a button asks for, on the first file when it needs one.
	ask : (File -> Run) -> (S -> S)
	ask = |make| |s| match s.files {
		[first, ..] => { ..s, run: make(first), outcome: "running" }
		[] => s
	}

	## Count the fetched file's lines, `chunk` bytes at a time.
	count_fetched : U64 -> (S -> S)
	count_fetched = |chunk| |s| match s.fetched {
		[file] => { ..s, run: Count({ file, chunk }), outcome: "running" }
		_ => s
	}

	plan : Run -> List(Engine.Req)
	plan = |run| match run {
		Idle => []
		Upper(input) => [TasksApp.upper.request(input)]
		Append(input) => [TasksApp.append.request(input)]
		Count(input) => [TasksApp.count_lines.request(input)]
		Overflow(file) => [TasksApp.overflow.request(file)]
		Crash(file) => [TasksApp.crashes.request(file)]
		Twice(n) => [TasksApp.twice.request(n)]
		Many(n) => [TasksApp.many.request(n)]
		Square(n) => [TasksApp.square.request(n)]
		Timed(file) => [TasksApp.timed.request(file)]
	}

	describe : File -> Str
	describe = |f| "${f.name()}:${f.size().to_str()}:${f.mime()}"

	## What a job's answer does to the state. The job is done, so `run` goes
	## back to `Idle`: a request's input in state holds the files it names,
	## and keeping it would keep them alive.
	answered : S, Run, Engine.Res -> S
	answered = |s, run, res| {
		next = TasksApp.took(s, run, res)
		{ ..next, run: Idle }
	}

	took : S, Run, Engine.Res -> S
	took = |s, run, res| match run {
		Idle => s
		Upper(_) => TasksApp.took_file(s, TasksApp.upper.result(res), |f| { ..s, built: [f] })
		Append(_) => TasksApp.took_file(s, TasksApp.append.result(res), |f| { ..s, log: [f] })
		Overflow(_) => TasksApp.took_file(s, TasksApp.overflow.result(res), |f| { ..s, built: [f] })
		Count(_) =>
			match TasksApp.count_lines.result(res) {
				Ok(n) => { ..s, outcome: "lines ${n.to_str()}" }
				Err(Failed(e)) => { ..s, outcome: "error ${Str.inspect(e)}" }
				Err(e) => { ..s, outcome: "failed ${Str.inspect(e)}" }
			}
		Crash(_) => TasksApp.took_size(s, TasksApp.crashes.result(res))
		Twice(_) => TasksApp.took_size(s, TasksApp.twice.result(res))
		Timed(_) => TasksApp.took_size(s, TasksApp.timed.result(res))
		Square(_) => TasksApp.took_size(s, TasksApp.square.result(res))
		Many(_) =>
			match TasksApp.many.result(res) {
				Ok(files) => { ..s, outcome: "files ${files.len().to_str()}" }
				Err(Failed(e)) => { ..s, outcome: "error ${Str.inspect(e)}" }
				Err(e) => { ..s, outcome: "failed ${Str.inspect(e)}" }
			}
	}

	took_file : S, Outcome(File), (File -> S) -> S
	took_file = |s, outcome, keep| match outcome {
		Ok(f) => { ..keep(f), outcome: "built ${TasksApp.describe(f)}" }
		Err(Failed(e)) => { ..s, outcome: "error ${Str.inspect(e)}" }
		Err(e) => { ..s, outcome: "failed ${Str.inspect(e)}" }
	}

	took_size : S, Outcome(U64) -> S
	took_size = |s, outcome| match outcome {
		Ok(n) => { ..s, outcome: "size ${n.to_str()}" }
		Err(Failed(e)) => { ..s, outcome: "error ${Str.inspect(e)}" }
		Err(e) => { ..s, outcome: "failed ${Str.inspect(e)}" }
	}

	## Save `files`' first file under `name` (its own when empty) in the
	## turn of the click.
	save_first : S, List(File), Str -> S
	save_first = |s, files, name| match files {
		[f, ..] => { ..s, save: Save(f, name, s.saves + 1), saves: s.saves + 1 }
		[] => s
	}

	listing : List(File) -> Str
	listing = |files| if (files.is_empty()) "none" else Str.join_with(files.map(TasksApp.describe), "|")

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"tasks",
			[
				Html.file_input(Engine.const("Upload"), { selection: Multiple }, st.on_files(TasksApp.received)),
				Html.button("Upper", [], st.update(TasksApp.ask(|f| Upper({ source: f, chunk: 4 })))),
				Html.button("Upper in 1 MiB chunks", [], st.update(TasksApp.ask(|f| Upper({ source: f, chunk: 1048576 })))),
				Html.button("Overflow", [], st.update(TasksApp.ask(|f| Overflow(f)))),
				Html.button("Crash", [], st.update(TasksApp.ask(|f| Crash(f)))),
				Html.button("Timed", [], st.update(TasksApp.ask(|f| Timed(f)))),
				Html.button("Twice", [], st.update(|s| { ..s, run: Twice(s.batch), outcome: "running" })),
				Html.button("Many", [], st.update(|s| { ..s, run: Many(17), outcome: "running" })),
				Html.button("Few", [], st.update(|s| { ..s, run: Many(3), outcome: "running" })),
				Html.button("Square", [], st.update(|s| { ..s, run: Square(7), outcome: "running" })),
				Html.button("Stop", [], st.update(|s| { ..s, run: Idle, outcome: "stopped" })),
				Html.button(
					"Add batch",
					[],
					st.update(|s| { ..s, batch: s.batch + 1, run: Append({ previous: s.log, lines: ["batch ${(s.batch + 1).to_str()}"] }), outcome: "running" }),
				),
				Html.button("Fetch", [], st.update(|s| { ..s, fetching: Get("/data.csv") })),
				Html.button("Count lines", [], st.update(TasksApp.count_fetched(3))),
				Html.button("Count lines in 1 MiB chunks", [], st.update(TasksApp.count_fetched(1048576))),
				Html.button("Save", [], st.update(|s| TasksApp.save_first(s, s.built, ""))),
				Html.button("Save log", [], st.update(|s| TasksApp.save_first(s, s.log, "log-copy.txt"))),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Html.button("Forget files", [], st.update(|s| { ..s, files: [], built: [], log: [], fetched: [], run: Idle })),
				Html.p_v(v.map(|s| s.outcome), [Engine.test_id("outcome")]),
				Html.p_v(v.map(|s| TasksApp.listing(s.built)), [Engine.test_id("built")]),
				Html.p_v(v.map(|s| TasksApp.listing(s.log)), [Engine.test_id("log")]),
				Html.p_v(v.map(|s| TasksApp.listing(s.fetched)), [Engine.test_id("fetched")]),
				Html.p_v(v.map(|s| s.kept), [Engine.test_id("kept")]),
				# One job at a time: a new `run` cancels the job of the old one.
				Engine.latest(v.map(|s| s.run), TasksApp.plan, st.on_result(TasksApp.answered)),
				Engine.latest(
					v.map(|s| s.fetching),
					|f| match f {
						Get(url) => [File.fetch({ url: url })]
						Idle => []
					},
					st.on_result(
						|s, _, res| match Engine.fetched(res) {
							Ok(body) => { ..s, fetched: [body], outcome: "fetched ${TasksApp.describe(body)}" }
							Err(e) => { ..s, outcome: "fetch failed ${Str.inspect(e)}" }
						},
					),
				),
				# The built file's text, read back on the page.
				Engine.state(
					"",
					|preview| Engine.element(
						"section",
						[],
						[
							Engine.latest(
								v.map(|s| s.built).lift(),
								|built| match built {
									[f] => [f.read_utf8({})]
									_ => []
								},
								preview.on_result(
									|_, _, res| match Engine.file_text(res) {
										Ok(text) => text
										Err(e) => "unread ${Str.inspect(e)}"
									},
								),
							),
							Html.p_v(preview.val(), [Engine.test_id("preview")]),
						],
					),
				),
				Engine.on_change(
					v.map(|s| s.save),
					|save| match save {
						Save(f, "", _) => [File.save(f, {})]
						Save(f, name, _) => [File.save(f, { name: Named(name) })]
						Idle => []
					},
					Engine.ignore({}),
				),
				Engine.when(
					v.map(|s| s.panel and !s.files.is_empty()),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[
							Engine.latest(
								v.map(|s| s.files.first()),
								|first| match first {
									Ok(f) => [TasksApp.stopped.request(f)]
									Err(_) => []
								},
								st.on_result(|s, _, res| { ..s, kept: "stopped answered ${Str.inspect(TasksApp.stopped.result(res))}" }),
							),
							Engine.latest(
								v.map(|s| s.files.first()),
								|first| match first {
									Ok(f) => [TasksApp.kept.request(f)]
									Err(_) => []
								},
								st.on_result(
									|s, _, res| match TasksApp.kept.result(res) {
										Ok(n) => { ..s, kept: "kept ${n.to_str()}" }
										Err(e) => { ..s, kept: "kept failed ${Str.inspect(e)}" }
									},
								),
							),
						],
					),
					|| Engine.text(""),
				),
			],
		)
	}

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ files: [], run: Idle, outcome: "idle", built: [], log: [], batch: 0, fetching: Idle, fetched: [], save: Idle, saves: 0, panel: Bool.False, kept: "" }, TasksApp.view))
			.with_workers([
				TasksApp.upper.registration(),
				TasksApp.append.registration(),
				TasksApp.count_lines.registration(),
				TasksApp.overflow.registration(),
				TasksApp.crashes.registration(),
				TasksApp.twice.registration(),
				TasksApp.many.registration(),
				TasksApp.square.registration(),
				TasksApp.timed.registration(),
				TasksApp.stopped.registration(),
				TasksApp.kept.registration(),
			])
}
