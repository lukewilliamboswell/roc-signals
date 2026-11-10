import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## Files test app: the files a user gives the app arrive as handles, and live
## as long as a value holds them.
## - "Upload" is a file input that takes several files; "Drop" a drop target
##   and "Paste" a paste target. Every file received is kept in the list, which
##   shows each file's name, size and type (`test-id "files"`); "refused"
##   counts files the instance had no room for.
## - "Keep first" drops every file but the first, "Clear" all of them: their
##   handles are released when nothing holds them any more.
## - "Panel" mounts a section with a file input of its own, whose state keeps
##   what it receives; closing the panel disposes that state, and its files go
##   with it.
## - "Count" sends the kept files to a worker program, which reads each one's
##   bytes there and answers its size and byte sum (`test-id "counts"`);
##   "Count tail" sends the last half of the first file only. "Probe" checks,
##   in the worker, that a file's bytes behave as an ordinary list: two reads
##   agree, a slice and a UTF-8 view see the same bytes, and changing one
##   read leaves the other alone (`test-id "probe"`).
FilesApp := [].{
	S : { files : List(File), refused : U64, panel : Bool, ask : Ask }

	## What the worker was last asked: nothing yet, to count the kept files,
	## to count the tail of the first, or to probe the first.
	Ask : [Nothing, Count(List(File)), Tail(List(File)), Probe(List(File))]

	## Each file's name, size and byte sum, read in the worker.
	count : Worker.Program(List(File), List({ name : Str, bytes : U64, sum : U64 }))
	count = Worker.pure(
		"test.roc-signals/files/count",
		|files| files.map(
			|f| {
				contents = f.contents()
				var $sum = 0.U64
				for b in contents {
					$sum = $sum + b.to_u64()
				}
				{ name: f.name(), bytes: contents.len(), sum: $sum }
			},
		),
	)

	## The spike's ownership probe, on a file's bytes in the worker.
	probe : Worker.Program(File, Bool)
	probe = Worker.pure(
		"test.roc-signals/files/probe",
		|f| {
			bytes = f.contents()
			other = f.contents()
			before = bytes.get(0) ?? 0
			text = Str.from_utf8(bytes) ?? "invalid"
			part = bytes.sublist({ start: 1, len: 3 })
			changed = bytes.set(0, 0) ?? []
			changed.get(0) == Ok(0) and other.get(0) == Ok(before) and part == other.sublist({ start: 1, len: 3 }) and text.count_utf8_bytes() == other.len()
		},
	)

	show_counts : Engine.Remote(List({ name : Str, bytes : U64, sum : U64 }), Worker.Error) -> Str
	show_counts = |{ request, answer }| match answer {
		Unanswered => if (request == Pending) "counting" else "not counted"
		Answered(counts) => Str.join_with(counts.map(|c| "${c.name}:${c.bytes.to_str()}:${c.sum.to_str()}"), "|")
		Failed(Lost(fault)) => "lost ${Str.inspect(fault)}"
		Failed(FileFailed(reason)) => "unread ${Str.inspect(reason)}"
		Failed(_) => "failed"
	}

	asked : Ask -> [Run(List(File)), Skip]
	asked = |a| match a {
		Count(files) => Run(files)
		Tail(files) => Run(files)
		_ => Skip
	}

	probed : Ask -> [Run(File), Skip]
	probed = |a| match a {
		Probe([first, ..]) => Run(first)
		_ => Skip
	}

	tail_of : List(File) -> List(File)
	tail_of = |files| match files {
		[first, ..] => [first.slice({ start: first.size() / 2, len: first.size() - first.size() / 2 })]
		[] => []
	}

	Ctx : In(Root, S)

	describe : File -> Str
	describe = |f| "${f.name()}:${f.size().to_str()}:${f.mime()}"

	listing : List(File) -> Str
	listing = |files| if (files.is_empty()) "none" else Str.join_with(files.map(FilesApp.describe), "|")

	## The first file in a list of its own. A slice (`take_first`) would keep
	## the whole list, and so every file in it, alive.
	first_only : List(File) -> List(File)
	first_only = |files|
		match files {
			[first, ..] => [first]
			[] => []
		}

	received : S, Engine.Received -> S
	received = |s, { files, refused }| { ..s, files: s.files.concat(files), refused: s.refused + refused }

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"files",
			[
				Html.file_input(Engine.const("Upload"), { accept: "", multiple: Bool.True }, st.on_files(FilesApp.received)),
				Engine.element("section", [Html.aria_label("Drop"), Html.on_drop_files(st.on_files(FilesApp.received))], [Engine.text("drop here")]),
				Engine.element("section", [Html.aria_label("Paste"), Html.on_paste_files(st.on_files(FilesApp.received))], [Engine.text("paste here")]),
				Html.button("Keep first", [], st.update(|s| { ..s, files: FilesApp.first_only(s.files) })),
				Html.button("Clear", [], st.update(|s| { ..s, files: [] })),
				Html.p_v(v.map(|s| FilesApp.listing(s.files)), [Engine.test_id("files")]),
				Html.p_v(v.map(|s| "refused ${s.refused.to_str()}"), [Engine.test_id("refused")]),
				Html.button("Count", [], st.update(|s| { ..s, ask: Count(s.files) })),
				Html.button("Count tail", [], st.update(|s| { ..s, ask: Tail(FilesApp.tail_of(s.files)) })),
				Html.button("Probe", [], st.update(|s| { ..s, ask: Probe(FilesApp.first_only(s.files)) })),
				Html.button("Forget", [], st.update(|s| { ..s, ask: Nothing })),
				Worker.derive_when(FilesApp.count, v.map(|s| FilesApp.asked(s.ask)), |r| Html.p_v(r.map(FilesApp.show_counts), [Engine.test_id("counts")])),
				Worker.derive_when(
					FilesApp.probe,
					v.map(|s| FilesApp.probed(s.ask)),
					|r| Html.p_v(
						r.map(
							|{ answer, .. }| match answer {
								Answered(ok) => if (ok) "probe ok" else "probe failed"
								_ => "no probe"
							},
						),
						[Engine.test_id("probe")],
					),
				),
				Html.button("Panel", [], st.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					v.map(|s| s.panel),
					|| Engine.state(
						[],
						|inner| Engine.element(
							"section",
							[Html.aria_label("panel")],
							[
								Html.file_input(Engine.const("Panel upload"), { accept: ".txt", multiple: Bool.False }, inner.on_files(|kept, { files, refused: _ }| kept.concat(files))),
								Html.p_v(inner.val().map(FilesApp.listing), [Engine.test_id("panel-files")]),
							],
						),
					),
					|| Engine.text(""),
				),
			],
		)
	}

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ files: [], refused: 0, panel: Bool.False, ask: Nothing }, |st| FilesApp.view(st)))
			.with_workers([FilesApp.count.registration(), FilesApp.probe.registration()])
}
