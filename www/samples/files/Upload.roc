import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## A text file the user chooses or drops, read in a worker: the page keeps the
## file's handle, and a worker task counts the file's lines and words.
Upload := [].{

	# region state
	## The files the user gave the app, and how many it had no room for.
	S : { files : List(File), refused : U64 }

	received : S, Engine.Received -> S
	received = |s, { files, refused }| { ..s, files: s.files.concat(files), refused: s.refused + refused }
	# endregion state

	# region task
	## A file's line and word counts, read in a worker. The task receives the
	## file's handle, and its job reads the bytes as text with the effect
	## `contents_utf8!` (`contents!` gives the bytes, `read!` a range); a file
	## that is not text, or that the browser can no longer read, is the
	## task's error.
	Counts : { name : Str, lines : U64, words : U64 }

	count : Worker.Task(File, Counts, Engine.FileError)
	count = Worker.task({
		name: "example.org/upload/count",
		run!: |file| {
			text = file.contents_utf8!()?
			lines = text.split_on("\n").len()
			words = text.split_on("\n").map(|l| l.split_on(" ").keep_if(|w| w != "").len()).sum()
			Ok({ name: file.name(), lines, words })
		},
	})
	# endregion task

	show : Engine.Remote(Counts, Worker.Error(Engine.FileError)) -> Str
	show = |{ request, answer }| match answer {
		Answered(
			{
				name,
				lines,
				words,
			},
		) => "${name}: ${lines.to_str()} lines, ${words.to_str()} words"
		Failed(Failed(InvalidUtf8)) => "The file is not text."
		Failed(_) => "The file could not be read."
		Unanswered => if (request == Pending) "Counting…" else "Choose a file."
	}

	latest : List(File) -> [Run(File), Skip]
	latest = |files| match files.last() {
		Ok(file) => Run(file)
		Err(_) => Skip
	}

	# region view
	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| {
		v = st.signal()
		Html.div(
			"upload",
			[
				Html.file_input(Engine.const("Text file"), { accept: Types(".txt,text/plain") }, st.set_value(Upload.received)),
				Engine.element("section", [Html.aria_label("Drop a file"), Html.on_drop_files(st.set_value(Upload.received))], [Engine.text("or drop one here")]),
				Worker.resource_when(Upload.count, v.map(|s| Upload.latest(s.files)), |r| Html.p_s(r.map(Upload.show), [Engine.test_id("counts")])),
				Html.button("Forget files", [], st.update(|s| { ..s, files: [] })),
			],
		)
	}
	# endregion view

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ files: [], refused: 0 }, Upload.view))
			.with_workers([Upload.count.registration()])
}
