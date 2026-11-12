import pf.Engine exposing [Elem, File, Val]
import pf.Files
import pf.Html
import pf.Worker
import AppStore
import Csv

## CSV Converter: drop a CSV file, of any size, and convert it to TSV or JSON
## lines in a worker, 256 KiB at a time, then preview and save the result.
##
## The file is never read on the page. A task's job reads it a chunk at a
## time, writes the converted records to a builder, and answers with the new
## file and its row counts; the page shows the first lines of the output
## (read back with a small page read) and saves the file when the user asks.
## "Load the sample" downloads a sample CSV into a file the same way.
##
## The file and the format are cells of the app's store (`AppStore`): the
## chooser and the select write them, and the conversion follows them from
## inside its own layer with no `lift`. The result panel keeps what only it
## cares about, the file a click asks to save and the preview's lines, as
## its own state beside the effect sites that use them.
ConverterApp := [].{

	## What a conversion is asked for.
	Job : { source : File, format : Csv.Format }

	## What a conversion answers: the output and what it found.
	Converted : { output : File, rows : U64, columns : U64, ragged : U64 }

	## Why a conversion has no output: the file could not be read or is not
	## UTF-8 (`Unreadable`, `InvalidUtf8`), the output is over the bound
	## (`TooLarge`), or the file has no header line (`Empty`).
	Problem : [Unreadable, TooLarge, InvalidUtf8, Empty]

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
		out = Files.build!({ name: "${ConverterApp.stem(source.name())}.${extension}", mime: Mime(mime) })
		var $header = []
		var $rows = 0
		var $ragged = 0
		var $carry = []
		for span in source.spans(ConverterApp.chunk_bytes) {
			bytes = source.read!(span)?
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

	## The conversion the store asks for: the chosen file to the chosen
	## format, or none while there is no file.
	wanted : AppStore.Source, Csv.Format -> [Run(Job), Skip]
	wanted = |source, format| match source.file {
		Chosen(file) => Run({ source: file, format })
		Nothing => Skip
	}

	## What the conversion shows: its progress, its answer, or why there is
	## none.
	status : Engine.Remote(Converted, Worker.Error(Problem)) -> Str
	status = |remote| match Worker.status(remote) {
		Working => "converting…"
		Answered(c) => "${c.rows.to_str()} rows, ${c.columns.to_str()} columns${ConverterApp.ragged_note(c.ragged)} → ${c.output.name()} (${ConverterApp.size_text(c.output.size())})"
		Failed(problem) => "could not convert: ${ConverterApp.explain(problem)}"
		Unasked => "drop a CSV file, or load the sample"
		stopped => "the conversion stopped: ${Str.inspect(stopped)}"
	}

	ragged_note : U64 -> Str
	ragged_note = |n| if (n == 0) "" else " (${n.to_str()} with another number of fields)"

	explain : Problem -> Str
	explain = |problem| match problem {
		Empty => "the file is empty"
		InvalidUtf8 => "the file is not UTF-8 text"
		TooLarge => "the output is larger than the converter keeps in memory"
		Unreadable => "the browser can no longer read the file"
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

	## The first lines of a preview read, at most `lines` of them.
	first_lines : List(U8), U64 -> Str
	first_lines = |bytes, lines| Str.join_with(Str.from_utf8_lossy(bytes).split_on("\n").take_first(lines), "\n")

	## The page.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		source = AppStore.h.source.val()
		Html.div(
			"converter app-shell app-shell-narrow",
			[
				Html.section(
					"CSV Converter",
					"app-header",
					[
						Html.h1("CSV Converter", "app-title"),
						Html.p("Convert a CSV to TSV or JSON lines. Your file stays in this browser. The first row supplies the column names.", "app-subtitle"),
					],
				),
				chooser({}),
				Html.section(
					"Conversion settings",
					"panel grid gap-4 p-4 sm:grid-cols-2",
					[
						Html.div(
							"field",
							[
								Html.label_for("Format", "converter-format", [Engine.class("field-label")]),
								Html.select(
									Engine.const("Format"),
									AppStore.h.format.val().map(AppStore.option_of),
									[Engine.class("input"), Engine.attr("id", "converter-format")],
									[Html.option("tsv", "TSV"), Html.option("jsonl", "JSON lines")],
									Engine.handle(AppStore.format_picked),
								),
							],
						),
						Html.div(
							"field content-start",
							[
								Html.p("Selected file", "field-label"),
								Html.p_v(
									source.map(
										|s| match s.file {
											Chosen(f) => "${f.name()}, ${ConverterApp.size_text(f.size())}"
											Nothing => "no file"
										},
									),
									[Engine.class("muted break-all"), Engine.test_id("source")],
								),
							],
						),
					],
				),
				result({}),
				# The sample, downloaded into a file.
				Engine.latest(
					source.map(|s| s.sample),
					|sample| match sample {
						Loading => [File.fetch({ url: "sample.csv" })]
						Idle => []
					},
					Engine.react(|_, res| AppStore.sample_arrived(Engine.fetched(res))),
				),
				Html.p_v(source.map(|s| s.note), [Engine.class("muted"), Engine.test_id("note")]),
			],
		)
	}

	program : Engine.Program
	program =
		Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| AppStore.store, |_| ConverterApp.view({}))
			.with_workers([ConverterApp.convert.registration()])
}

## Where a file is dropped or chosen, and the button that asks for the
## sample. A drop and a choice are the same decision over the files they
## carry.
chooser : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
chooser = |{}| Engine.element(
	"section",
	[Engine.class("panel grid gap-4 border-dashed p-5"), Html.aria_label("Drop a CSV file"), Html.on_drop_files(Engine.handle_files(AppStore.chosen))],
	[
		Html.h2("Choose a CSV", "card-title"),
		Html.p("Drop a CSV file here, choose one from your device, or load the sample.", "muted"),
		Engine.element(
			"label",
			[Engine.class("field")],
			[
				Engine.element("span", [Engine.class("field-label")], [Engine.text("CSV file")]),
				Html.file_input(Engine.const("CSV file"), { accept: Types(".csv,text/csv") }, Engine.handle_files(AppStore.chosen)),
			],
		),
		Html.div("toolbar", [Html.button("Load the sample", [Engine.class("button")], Engine.does(AppStore.sample_asked))]),
	],
)

## A preview of a converted file: its first 4 KiB, read back on the
## page. The lines are this panel's own state, kept until the next
## read answers.
preview : Val(ctx, Try(File, [NoAnswer])) -> Elem(ctx)
preview = |output| Engine.state(
	"",
	|lines| Engine.element(
		"section",
		[Engine.class("grid min-w-0 gap-3")],
		[
			Engine.latest(
				output.lift(),
				|converted| match converted {
					Ok(out) => [out.slice({ start: 0, len: out.size().min(4096) }).read_bytes({})]
					Err(NoAnswer) => []
				},
				lines.on_result(
					|_, _, res| match Engine.file_bytes(res) {
						Ok(bytes) => ConverterApp.first_lines(bytes, 6)
						Err(_) => ""
					},
				),
			),
			Html.h2("Preview", "card-title"),
			Html.p("The first six lines of the converted file, up to 4 KiB.", "muted"),
			Html.pre_v(lines.val(), [Engine.class("min-h-20 min-w-0 max-w-full overflow-auto bg-zinc-950 p-4 font-mono text-xs leading-6 text-zinc-50"), Engine.test_id("preview")]),
		],
	),
)

## The conversion and what is done with its output. The conversion
## follows the file and the format: changing either stops the job for
## the old ones.
##
## The file a click asks to save is posted to an outbox that only this
## panel reads, so the outbox is the panel's own state, with the site
## that saves what is posted beside it.
result : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
result = |{}| Worker.derive_when(
	ConverterApp.convert,
	AppStore.h.source.val().map2(AppStore.h.format.val(), ConverterApp.wanted),
	|answer| Engine.state(
		Engine.outbox({}),
		|save| {
			remote = answer.lift()
			Engine.element(
				"section",
				[Engine.class("panel grid min-w-0 gap-4 p-4"), Html.aria_label("Result")],
				[
					Html.h2("Converted file", "card-title"),
					Html.p_v(remote.map(ConverterApp.status), [Engine.class("notice notice-info break-words"), Engine.test_id("status")]),
					Html.button(
						"Save",
						[Engine.class("button-primary justify-self-start")],
						save.update_by(
							remote,
							|box, latest| match latest.answered() {
								Ok(c) => box.post(c.output)
								Err(NoAnswer) => box
							},
						),
					),
					preview(remote.map(|latest| latest.answered().map_ok(|c| c.output))),
					# Saving, in the turn of the click that asked for it.
					Engine.on_post(save.val(), |out| [File.save(out, {})], Engine.ignore({})),
				],
			)
		},
	),
)
