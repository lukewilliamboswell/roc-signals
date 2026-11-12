import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## A text file too large to keep as text: a worker notes where each line
## starts and keeps that index beside the file's handle, and a task reads
## one line back with a single read of its bytes.
Lines := [].{
	S : { doc : [None, Loaded(File)], wanted : Str }

	# region index
	## What the preparation keeps: the file's handle, to read from later,
	## and where each line starts. Not the text.
	Indexed : { file : File, starts : List(U64) }

	## Read the file 64 KiB at a time, so the worker holds one chunk and the
	## index, never the whole file.
	index! : File => Try(Indexed, Engine.FileError)
	index! = |file| {
		var $starts = if (file.size() == 0) [] else [0]
		var $at = 0
		while $at < file.size() {
			len = if (file.size() - $at < 65536) file.size() - $at else 65536
			chunk = file.read!({ start: $at, len })?
			var $i = 0
			for b in chunk {
				if b == '\n' and $at + $i + 1 < file.size() {
					$starts = $starts.append($at + $i + 1)
				}
				$i = $i + 1
			}
			$at = $at + len
		}
		Ok({ file, starts: $starts })
	}

	lines : Worker.Preparation(File, Indexed, Engine.FileError)
	lines = Worker.prepared({ name: "example.org/lines/index", prepare!: Lines.index! })
	# endregion index

	# region line
	## How many lines there are, from the index alone.
	count : Worker.PreparedTask(File, Indexed, {}, U64, Engine.FileError)
	count = Lines.lines.task({ name: "example.org/lines/count", run!: |indexed, {}| Ok(indexed.starts.len()) })

	## One line (from 1), read from the kept handle: just its bytes.
	line : Worker.PreparedTask(File, Indexed, U64, [Text(Str), PastTheEnd], Engine.FileError)
	line = Lines.lines.task({ name: "example.org/lines/line", run!: Lines.line! })

	line! : Indexed, U64 => Try([Text(Str), PastTheEnd], Engine.FileError)
	line! = |{ file, starts }, number| {
		if number == 0 {
			return Ok(PastTheEnd)
		}
		match starts.get(number - 1) {
			Ok(start) => {
				end = starts.get(number) ?? file.size()
				bytes = file.read!({ start, len: end - start })?
				Ok(Text(Str.from_utf8_lossy(if (bytes.last() == Ok('\n')) bytes.drop_last(1) else bytes)))
			}
			Err(OutOfBounds) => Ok(PastTheEnd)
		}
	}
	# endregion line

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ doc: None, wanted: "1" }, Lines.view))
			.with_workers([Lines.lines.registration([Lines.count.registration(), Lines.line.registration()])])

	Ctx : In(Root, S)

	asked : S, q -> [Run(Worker.Question(File, q)), Skip]
	asked = |s, query| match s.doc {
		Loaded(doc) => Run({ input: doc, query })
		None => Skip
	}

	show : Engine.Remote(a, Worker.Error(Engine.FileError)), (a -> Str) -> Str
	show = |{ request, answer }, describe| match answer {
		Answered(value) => if (request == Pending) "working" else describe(value)
		Failed(problem) => "failed: ${Str.inspect(problem)}"
		Unanswered => if (request == Pending) "working" else "choose a file"
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"lines",
			[
				Html.file_input(
					Engine.const("Text file"),
					{},
					st.on_files(
						|s, { files, refused: _ }| match files {
							[first, ..] => { ..s, doc: Loaded(first) }
							[] => s
						},
					),
				),
				Worker.derive_when(Lines.count, v.map(|s| Lines.asked(s, {})), |r| Html.p_v(r.map(|x| Lines.show(x, |n| "${n.to_str()} lines")), [Engine.test_id("count")])),
				Html.number_input(Engine.const("Line"), v.map(|s| s.wanted), [], st.set_value(|s, wanted| { ..s, wanted })),
				Worker.derive_when(
					Lines.line,
					v.map(
						|s| match U64.from_str(s.wanted) {
							Ok(number) => Lines.asked(s, number)
							Err(_) => Skip
						},
					),
					|r| Html.p_v(
						r.map(
							|x| Lines.show(
								x,
								|found| match found {
									Text(text) => text
									PastTheEnd => "past the end"
								},
							),
						),
						[Engine.test_id("line")],
					),
				),
			],
		)
	}
}
