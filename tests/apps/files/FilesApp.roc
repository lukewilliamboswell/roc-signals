import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html

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
FilesApp := [].{
	S : { files : List(File), refused : U64, panel : Bool }

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
	program = Engine.program(|| Engine.state({ files: [], refused: 0, panel: Bool.False }, |st| FilesApp.view(st)))
}
