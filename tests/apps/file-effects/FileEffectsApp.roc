import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html

## File effects test app: operations on a file the user gave the app, run
## where the file lives, and reads that bring its bytes into the page.
## - "Upload" is a file input that takes several files; "Clear" lets them go.
## - "Read text" and "Read bytes" read the first file into the page; "Read
##   tail" reads the second half of it as bytes, and "Read cut" its second
##   byte alone as text (which cuts a two-byte character in two). The answer
##   is shown in `test-id "read"`: the text, or the byte count and byte sum,
##   or the typed failure. "Forget" gives the read up.
## - "Panel" mounts a section that reads the first file's text as it mounts;
##   closing the panel disposes the read with it.
FileEffectsApp := [].{
	S : { files : List(File), read : Ask, panel : Bool }

	## What the page was last asked to read: nothing, or a file as text or
	## as bytes.
	Ask : [Skip, Bytes(File), Text(File)]

	## The read's answer, as the page shows it.
	Shown : [NotRead, Reading, GotBytes(Try(List(U8), Engine.FileError)), GotText(Try(Str, Engine.FileError))]

	Ctx : In(Root, S)

	describe : File -> Str
	describe = |f| "${f.name()}:${f.size().to_str()}:${f.mime()}"

	listing : List(File) -> Str
	listing = |files| if (files.is_empty()) "none" else Str.join_with(files.map(FileEffectsApp.describe), "|")

	received : S, Engine.Received -> S
	received = |s, { files, refused: _ }| { ..s, files: s.files.concat(files) }

	## Ask to read the first file, or a range of it, as `make` says.
	ask_first : S, (File -> Ask) -> S
	ask_first = |s, make| match s.files {
		[first, ..] => { ..s, read: make(first) }
		[] => s
	}

	tail_of : File -> File
	tail_of = |f| f.slice({ start: f.size() / 2, len: f.size() - f.size() / 2 })

	sum : List(U8) -> U64
	sum = |bytes| bytes.fold(0, |acc, b| acc + b.to_u64())

	show : Shown -> Str
	show = |shown| match shown {
		NotRead => "not read"
		Reading => "reading"
		GotBytes(Ok(bytes)) => "bytes ${bytes.len().to_str()} sum ${FileEffectsApp.sum(bytes).to_str()}"
		GotText(Ok(text)) => "text ${text}"
		GotBytes(Err(e)) => "failed ${Str.inspect(e)}"
		GotText(Err(e)) => "failed ${Str.inspect(e)}"
	}

	## A `resource` that reads what `ask` names into the page.
	reader : Engine.Val(ctx, Ask), (Engine.Val(In(ctx, Shown), Shown) -> Elem(In(ctx, Shown))) -> Elem(ctx)
	reader = |ask, body|
		Engine.resource(
			ask,
			{
				init: NotRead,
				begin: |_, a| match a {
					Skip => NotRead
					_ => Reading
				},
				plan: |a| match a {
					Bytes(f) => [f.read_bytes()]
					Text(f) => [f.read_utf8()]
					Skip => []
				},
				fold: |_, a, res| match a {
					Bytes(_) => GotBytes(Engine.file_bytes(res))
					Text(_) => GotText(Engine.file_text(res))
					Skip => NotRead
				},
			},
			body,
		)

	first_text : List(File) -> Ask
	first_text = |files| match files {
		[first, ..] => Text(first)
		[] => Skip
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"file-effects",
			[
				Html.file_input(Engine.const("Upload"), { accept: "", multiple: Bool.True }, st.on_files(FileEffectsApp.received)),
				Html.p_v(v.map(|s| FileEffectsApp.listing(s.files)), [Engine.test_id("files")]),
				Html.button("Clear", [], st.update(|s| { ..s, files: [] })),
				Html.button("Read text", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Text(f)))),
				Html.button("Read bytes", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Bytes(f)))),
				Html.button("Read tail", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Bytes(FileEffectsApp.tail_of(f))))),
				Html.button("Read cut", [], st.update(|s| FileEffectsApp.ask_first(s, |f| Text(f.slice({ start: 1, len: 1 }))))),
				Html.button("Forget", [], st.update(|s| { ..s, read: Skip })),
				FileEffectsApp.reader(v.map(|s| s.read), |r| Html.p_v(r.map(FileEffectsApp.show), [Engine.test_id("read")])),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.element(
						"section",
						[Html.aria_label("panel")],
						[FileEffectsApp.reader(v.map(|s| FileEffectsApp.first_text(s.files)), |r| Html.p_v(r.map(FileEffectsApp.show), [Engine.test_id("panel-read")]))],
					),
					|| Engine.text(""),
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ files: [], read: Skip, panel: Bool.False }, |st| FileEffectsApp.view(st)))
}
