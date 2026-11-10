import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## Files in tasks: convert a CSV the user chooses into a TSV in a worker, a
## chunk at a time, keep a log that each job appends to, download a file
## into a handle and measure it in a task, and save the results.
Convert := [].{

	# region transform
	## Convert a CSV file to TSV in a worker, 64 KiB at a time: the job's
	## memory holds a chunk, never the file.
	to_tsv : Worker.Task(File, File, Engine.FileError)
	to_tsv = Worker.task({ name: "example.org/convert/tsv", run!: Convert.to_tsv! })

	to_tsv! : File => Try(File, Engine.FileError)
	to_tsv! = |source| {
		out = File.build!({ name: "${source.name()}.tsv", mime: Mime("text/tab-separated-values") })
		chunk = 65536
		var $at = 0
		while $at < source.size() {
			len = if (source.size() - $at < chunk) source.size() - $at else chunk
			bytes = source.read!({ start: $at, len })?
			out.append!(bytes.map(|b| if (b == ',') '\t' else b))?
			$at = $at + len
		}
		Ok(out.finish!())
	}
	# endregion transform

	# region append
	## Append a line to the log the last job built. The builder starts from
	## that file by reference, and the old log is unchanged unless the new
	## one is delivered.
	log_line : Worker.Task({ log : List(File), line : Str }, File, Engine.FileError)
	log_line = Worker.task({ name: "example.org/convert/log", run!: Convert.log_line! })

	log_line! : { log : List(File), line : Str } => Try(File, Engine.FileError)
	log_line! = |{ log, line }| {
		start_from = match log {
			[previous] => From(previous)
			_ => Empty
		}
		out = File.build!({ name: "convert.log", mime: Mime("text/plain"), start_from })
		out.append!("${line}\n".to_utf8())?
		Ok(out.finish!())
	}
	# endregion append

	# region measure
	## The number of lines in a file, read 1 MiB at a time.
	count_lines : Worker.Task(File, U64, Engine.FileError)
	count_lines = Worker.task({ name: "example.org/convert/lines", run!: Convert.count_lines! })

	count_lines! : File => Try(U64, Engine.FileError)
	count_lines! = |file| {
		chunk = 1048576
		var $lines = 0
		var $at = 0
		while $at < file.size() {
			len = if (file.size() - $at < chunk) file.size() - $at else chunk
			bytes = file.read!({ start: $at, len })?
			$lines = $lines + bytes.count_if(|b| b == '\n')
			$at = $at + len
		}
		Ok($lines)
	}
	# endregion measure

	# region model
	## What the page keeps: the chosen file, the converted one, the log, a
	## downloaded file, what to save, and a line for each answer.
	S : {
		source : [Nothing, Chosen(File)],
		log : List(File),
		entries : U64,
		logging : [Idle, Append({ log : List(File), line : Str })],
		download : [Idle, Get(Str)],
		downloaded : List(File),
		save : [Idle, Save(File, U64)],
		saves : U64,
		status : Str,
	}
	# endregion model

	Ctx : In(Root, S)

	chosen : S, Engine.Received -> S
	chosen = |s, { files, refused: _ }| match files {
		[f, ..] => { ..s, source: Chosen(f), status: "converting ${f.name()}" }
		[] => s
	}

	converting : S -> [Run(File), Skip]
	converting = |s| match s.source {
		Chosen(f) => Run(f)
		Nothing => Skip
	}

	describe : List(File) -> Str
	describe = |files| match files {
		[f, ..] => "${f.name()} (${f.size().to_str()} bytes)"
		[] => "none"
	}

	## Save the first of `files`, in the turn of the click.
	save_first : S, List(File) -> S
	save_first = |s, files| match files {
		[f, ..] => { ..s, save: Save(f, s.saves + 1), saves: s.saves + 1 }
		[] => s
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"convert",
			[
				Html.file_input(Engine.const("CSV file"), { accept: Types(".csv") }, st.on_files(Convert.chosen)),
				# region derive
				# The conversion follows the chosen file: a newer file stops
				# the job for the older one. The answer's file is the page's.
				Worker.derive_when(
					Convert.to_tsv,
					v.map(Convert.converting),
					|r| Engine.element(
						"section",
						[Html.aria_label("converted")],
						[
							Html.p_v(
								r.map(
									|{ request, answer }| match (request, answer) {
										(Pending, _) => "converting"
										(Idle, Answered(f)) => "converted ${f.name()} (${f.size().to_str()} bytes)"
										(Idle, Failed(Failed(e))) => "conversion failed: ${Str.inspect(e)}"
										(Idle, Failed(e)) => "no answer: ${Str.inspect(e)}"
										(Idle, Unanswered) => "choose a CSV file"
									},
								),
								[Engine.test_id("converted")],
							),
							# A save the user asks for: the click's handler
							# reads the answer's file and keeps it to save.
							Html.button(
								"Save TSV",
								[],
								st.lift().update_by(
									r,
									|s, remote| match remote.answer {
										Answered(f) => Convert.save_first(s, [f])
										_ => s
									},
								),
							),
						],
					),
				),
				# endregion derive
				# region log
				# Each click asks for one job; its answer replaces the log,
				# and `logging` goes back to `Idle` so the request's input,
				# which holds the old log, is not kept alive.
				Html.button("Log a line", [], st.update(|s| { ..s, entries: s.entries + 1, logging: Append({ log: s.log, line: "entry ${(s.entries + 1).to_str()}" }) })),
				Engine.latest(
					v.map(|s| s.logging),
					|logging| match logging {
						Append(input) => [Convert.log_line.request(input)]
						Idle => []
					},
					st.on_result(
						|s, _, res| match Convert.log_line.result(res) {
							Ok(log) => { ..s, log: [log], logging: Idle }
							Err(Failed(e)) => { ..s, status: "log failed: ${Str.inspect(e)}", logging: Idle }
							Err(e) => { ..s, status: "log lost: ${Str.inspect(e)}", logging: Idle }
						},
					),
				),
				Html.p_v(v.map(|s| "log: ${Convert.describe(s.log)}"), [Engine.test_id("log")]),
				Html.button("Save log", [], st.update(|s| Convert.save_first(s, s.log))),
				# endregion log
				# region fetch
				# A download into a file: the body stays in the browser, and
				# a task measures it.
				Html.button("Download data", [], st.update(|s| { ..s, download: Get("/data/sales.csv") })),
				Engine.latest(
					v.map(|s| s.download),
					|d| match d {
						Get(url) => [File.fetch({ url: url })]
						Idle => []
					},
					st.on_result(
						|s, _, res| match Engine.fetched(res) {
							Ok(body) => { ..s, downloaded: [body], download: Idle }
							Err(e) => { ..s, status: "download failed: ${Str.inspect(e)}", download: Idle }
						},
					),
				),
				Worker.derive_when(
					Convert.count_lines,
					v.map(
						|s| match s.downloaded {
							[f] => Run(f)
							_ => Skip
						},
					),
					|r| Html.p_v(
						r.map(
							|{ answer, .. }| match answer {
								Answered(n) => "${n.to_str()} lines downloaded"
								_ => "nothing downloaded"
							},
						),
						[Engine.test_id("downloaded")],
					),
				),
				# endregion fetch
				# region save
				# The save command, issued in the turn of the click that
				# asked for it, so the browser sees the user's gesture.
				Engine.on_change(
					v.map(|s| s.save),
					|save| match save {
						Save(f, _) => [File.save(f, {})]
						Idle => []
					},
					Engine.ignore({}),
				),
				# endregion save
				Html.p_v(v.map(|s| s.status), [Engine.test_id("status")]),
			],
		)
	}

	# region register
	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ source: Nothing, log: [], entries: 0, logging: Idle, download: Idle, downloaded: [], save: Idle, saves: 0, status: "" }, Convert.view))
			.with_workers([Convert.to_tsv.registration(), Convert.log_line.registration(), Convert.count_lines.registration()])
	# endregion register
}
