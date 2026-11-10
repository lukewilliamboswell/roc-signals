import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker
import Csv

## CSV Converter: drop a CSV file, of any size, and convert it to TSV or JSON
## lines in a worker, 256 KiB at a time, then preview and save the result.
##
## The file is never read on the page. A task's job reads it a chunk at a
## time, writes the converted records to a builder, and answers with the new
## file and its row counts; the page shows the first lines of the output
## (read back with a small page read) and saves the file when the user asks.
## "Load the sample" downloads a sample CSV into a file the same way.
ConverterApp := [].{

	## What a conversion is asked for.
	Job : { source : File, format : Csv.Format }

	## What a conversion answers: the output and what it found.
	Converted : { output : File, rows : U64, columns : U64, ragged : U64 }

	## Why a conversion has no output: the file could not be read or is not
	## UTF-8 (`Unreadable`, `InvalidUtf8`), the output is over the bound
	## (`TooLarge`), or the file has no header line (`Empty`).
	Problem : [Unreadable, TooLarge, InvalidUtf8, Unavailable, Refused, Empty]

	convert : Worker.Task(Job, Converted, Problem)
	convert = Worker.task({ name: "roc-signals.example/csv-converter/convert", run!: ConverterApp.convert! })

	## How much of the source one read brings into the job's memory.
	chunk_bytes : U64
	chunk_bytes = 262144

	## Convert `source` a chunk at a time. A record that spans two chunks is
	## carried over: only the bytes after the last line break wait for the
	## next chunk.
	convert! : Job => Try(Converted, Problem)
	convert! = |{ source, format }| {
		extension = match format {
			Tsv => "tsv"
			JsonLines => "jsonl"
		}
		mime = match format {
			Tsv => "text/tab-separated-values"
			JsonLines => "application/x-ndjson"
		}
		out = File.build!({ name: "${ConverterApp.stem(source.name())}.${extension}", mime: Mime(mime) })
		var $header = []
		var $rows = 0
		var $ragged = 0
		var $carry = []
		var $at = 0
		while $at < source.size() {
			len = if (source.size() - $at < ConverterApp.chunk_bytes) source.size() - $at else ConverterApp.chunk_bytes
			bytes = source.read!({ start: $at, len })?
			{ complete, rest } = Csv.lines($carry.concat(bytes))
			var $text = ""
			for line in complete {
				values = Csv.fields(Str.from_utf8(line) ? |_| InvalidUtf8)
				if $header.is_empty() {
					$header = values
					$text = Str.concat($text, Csv.header_line(format, values))
				} else {
					$rows = $rows + 1
					$ragged = $ragged + (if (values.len() == $header.len()) 0 else 1)
					$text = Str.concat($text, Csv.record(format, $header, values))
				}
			}
			out.append!($text.to_utf8())?
			$carry = rest
			$at = $at + len
		}
		# The last line may have no line break.
		if !$carry.is_empty() {
			values = Csv.fields(Str.from_utf8($carry) ? |_| InvalidUtf8)
			if $header.is_empty() {
				$header = values
				out.append!(Csv.header_line(format, values).to_utf8())?
			} else {
				$rows = $rows + 1
				$ragged = $ragged + (if (values.len() == $header.len()) 0 else 1)
				out.append!(Csv.record(format, $header, values).to_utf8())?
			}
		}
		if $header.is_empty() {
			return Err(Empty)
		}
		Ok({ output: out.finish!(), rows: $rows, columns: $header.len(), ragged: $ragged })
	}

	## A file name without its last extension.
	stem : Str -> Str
	stem = |name| {
		parts = name.split_on(".")
		if (parts.len() > 1) Str.join_with(parts.drop_last(1), ".") else name
	}

	## The page's state: the source and the format, the file to save, and
	## whether the sample is being downloaded.
	S : {
		source : [Nothing, Chosen(File)],
		format : Csv.Format,
		sample : [Idle, Loading],
		save : [Idle, Save(File, U64)],
		saves : U64,
		note : Str,
	}

	Ctx : In(Root, S)

	chosen : S, Engine.Received -> S
	chosen = |s, { files, refused: _ }| match files {
		[f, ..] => { ..s, source: Chosen(f), note: "" }
		[] => s
	}

	wanted : S -> [Run(Job), Skip]
	wanted = |s| match s.source {
		Chosen(source) => Run({ source, format: s.format })
		Nothing => Skip
	}

	## What the conversion shows: its progress, its answer, or why there is
	## none.
	status : Engine.Remote(Converted, Worker.Error(Problem)) -> Str
	status = |{ request, answer }| match (request, answer) {
		(Pending, _) => "converting…"
		(Idle, Answered(c)) => "${c.rows.to_str()} rows, ${c.columns.to_str()} columns${ConverterApp.ragged_note(c.ragged)} → ${c.output.name()} (${ConverterApp.size_text(c.output.size())})"
		(Idle, Failed(Failed(problem))) => "could not convert: ${ConverterApp.explain(problem)}"
		(Idle, Failed(error)) => "the conversion stopped: ${Str.inspect(error)}"
		(Idle, Unanswered) => "drop a CSV file, or load the sample"
	}

	ragged_note : U64 -> Str
	ragged_note = |n| if (n == 0) "" else " (${n.to_str()} with another number of fields)"

	explain : Problem -> Str
	explain = |problem| match problem {
		Empty => "the file is empty"
		InvalidUtf8 => "the file is not UTF-8 text"
		TooLarge => "the output is larger than the converter keeps in memory"
		Unreadable => "the browser can no longer read the file"
		Unavailable => "the browser cannot read files here"
		Refused => "too many requests at once"
	}

	size_text : U64 -> Str
	size_text = |n|
		if n < 1024 {
			"${n.to_str()} bytes"
		} else if n < 1048576 {
			"${(n / 1024).to_str()} KiB"
		} else {
			"${(n / 1048576).to_str()} MiB"
		}

	## The converted file in a remote layer, when there is one.
	output_of : Engine.Remote(Converted, Worker.Error(Problem)) -> List(File)
	output_of = |{ answer, .. }| match answer {
		Answered(c) => [c.output]
		_ => []
	}

	## The first lines of a preview read, at most `lines` of them.
	first_lines : List(U8), U64 -> Str
	first_lines = |bytes, lines| Str.join_with(Str.from_utf8_lossy(bytes).split_on("\n").take_first(lines), "\n")

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"converter",
			[
				Engine.element(
					"section",
					[Html.aria_label("Drop a CSV file"), Html.on_drop_files(st.on_files(ConverterApp.chosen))],
					[
						Html.file_input(Engine.const("CSV file"), { accept: Types(".csv,text/csv") }, st.on_files(ConverterApp.chosen)),
						Html.button("Load the sample", [], st.update(|s| { ..s, sample: Loading })),
					],
				),
				Html.select(
					Engine.const("Format"),
					v.map(
						|s| match s.format {
							Tsv => "tsv"
							JsonLines => "jsonl"
						},
					),
					[],
					[Html.option("tsv", "TSV"), Html.option("jsonl", "JSON lines")],
					st.set_value(|s, value| { ..s, format: if (value == "jsonl") JsonLines else Tsv }),
				),
				Html.p_v(
					v.map(
						|s| match s.source {
							Chosen(f) => "${f.name()}, ${ConverterApp.size_text(f.size())}"
							Nothing => "no file"
						},
					),
					[Engine.test_id("source")],
				),
				# The conversion follows the file and the format: changing
				# either stops the job for the old ones.
				Worker.derive_when(
					ConverterApp.convert,
					v.map(ConverterApp.wanted),
					|r| Engine.element(
						"section",
						[Html.aria_label("Result")],
						[
							Html.p_v(r.map(ConverterApp.status), [Engine.test_id("status")]),
							Html.button(
								"Save",
								[],
								st.lift().update_by(
									r,
									|s, remote| match ConverterApp.output_of(remote) {
										[out] => { ..s, save: Save(out, s.saves + 1), saves: s.saves + 1 }
										_ => s
									},
								),
							),
							# A preview of the output: its first 4 KiB, read
							# back on the page.
							Engine.state(
								"",
								|preview| Engine.element(
									"section",
									[],
									[
										Engine.latest(
											r.map(ConverterApp.output_of).lift(),
											|outputs| match outputs {
												[out] => [out.slice({ start: 0, len: if (out.size() < 4096) out.size() else 4096 }).read_bytes({})]
												_ => []
											},
											preview.on_result(
												|_, _, res| match Engine.file_bytes(res) {
													Ok(bytes) => ConverterApp.first_lines(bytes, 6)
													Err(_) => ""
												},
											),
										),
										Html.pre_v(preview.val(), [Engine.test_id("preview")]),
									],
								),
							),
						],
					),
				),
				# The sample, downloaded into a file.
				Engine.latest(
					v.map(|s| s.sample),
					|sample| match sample {
						Loading => [File.fetch({ url: "sample.csv" })]
						Idle => []
					},
					st.on_result(
						|s, _, res| match Engine.fetched(res) {
							Ok(f) => { ..s, source: Chosen(f), sample: Idle }
							Err(e) => { ..s, sample: Idle, note: "the sample did not load: ${Str.inspect(e)}" }
						},
					),
				),
				# Saving, in the turn of the click that asked for it.
				Engine.on_change(
					v.map(|s| s.save),
					|save| match save {
						Save(out, _) => [File.save(out, {})]
						Idle => []
					},
					Engine.ignore({}),
				),
				Html.p_v(v.map(|s| s.note), [Engine.test_id("note")]),
			],
		)
	}

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ source: Nothing, format: Tsv, sample: Idle, save: Idle, saves: 0, note: "" }, ConverterApp.view))
			.with_workers([ConverterApp.convert.registration()])
}
