import pf.Engine exposing [Elem, File, State]
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
## - "Count" sends the kept files to a worker task, whose job reads each
##   one's bytes there and answers its size and byte sum (`test-id
##   "counts"`); "Count tail" sends the last half of the first file only.
## - "Inbox" is a drop target whose handler is a decision
##   (`Engine.handle_files`): one drop puts the files in a store cell and
##   writes a note in another. "Inbox with a reading" adds to the inbox and
##   notes how many it held when the files arrived
##   (`Engine.handle_files_by`). "Inbox and list" writes the cells and the
##   local list as one event (`FilesHandler.also`), and "Empty inbox" lets
##   the inbox's files go (`Engine.does`).
##   "Probe" checks, in the job, that a file's bytes behave as an ordinary
##   list: two reads agree, a slice and a UTF-8 view see the same bytes, and
##   changing one read leaves the other alone (`test-id "probe"`).
FilesApp := [Shelf].{
	S : { files : List(File), refused : U64, panel : Bool, ask : Ask }

	## The app's store: the files a decision received, and a note of what
	## arrived.
	store = Engine.store(
		FilesApp.Shelf,
		{
			inbox: Engine.cell([]),
			note: Engine.cell("nothing arrived"),
		}.Engine.Cells,
	)

	h = FilesApp.store.handles()

	## What a drop on "Inbox" writes: the files it delivered in place of
	## the inbox's, and a note of how many came and how many were refused.
	arrived : Engine.Received -> List(Engine.Write(_))
	arrived = |{ files, refused }| [
		FilesApp.h.inbox.put(files),
		FilesApp.h.note.put("${files.len().to_str()} arrived, ${refused.to_str()} refused"),
	]

	## What a drop on "Inbox with a reading" writes, given how many files
	## the inbox held when the drop arrived: the files added to them, and a
	## note that says both numbers.
	arrived_after : U64, Engine.Received -> List(Engine.Write(_))
	arrived_after = |held, { files, refused: _ }| [
		FilesApp.h.inbox.change(|kept| kept.concat(files)),
		FilesApp.h.note.put("${files.len().to_str()} arrived after ${held.to_str()}"),
	]

	## What "Empty inbox" writes.
	emptied : List(Engine.Write(_))
	emptied = [FilesApp.h.inbox.put([]), FilesApp.h.note.put("emptied")]

	## What the worker was last asked: nothing yet, to count the kept files,
	## to count the tail of the first, or to probe the first.
	Ask : [Nothing, Count(List(File)), Tail(List(File)), Probe(List(File))]

	## Each file's name, size and byte sum, read in the worker.
	count : Worker.Task(List(File), List({ name : Str, bytes : U64, sum : U64 }), Engine.FileError)
	count = Worker.task({ name: "test.roc-signals/files/count", run!: FilesApp.count! })

	## Read each file whole and sum its bytes.
	count! : List(File) => Try(List({ name : Str, bytes : U64, sum : U64 }), Engine.FileError)
	count! = |files| {
		var $counts = []
		for f in files {
			contents = f.contents!()?
			var $sum = 0.U64
			for b in contents {
				$sum = $sum + b.to_u64()
			}
			$counts = $counts.append({ name: f.name(), bytes: contents.len(), sum: $sum })
		}
		Ok($counts)
	}

	## An ownership probe on a file's bytes in the worker.
	probe : Worker.Task(File, Bool, Engine.FileError)
	probe = Worker.task({ name: "test.roc-signals/files/probe", run!: FilesApp.probe! })

	## Two reads of one file, compared after changing one.
	probe! : File => Try(Bool, Engine.FileError)
	probe! = |f| {
		bytes = f.contents!()?
		other = f.contents!()?
		before = bytes.get(0) ?? 0
		text = Str.from_utf8(bytes) ?? "invalid"
		part = bytes.sublist({ start: 1, len: 3 })
		changed = bytes.set(0, 0) ?? []
		Ok(changed.get(0) == Ok(0) and other.get(0) == Ok(before) and part == other.sublist({ start: 1, len: 3 }) and text.count_utf8_bytes() == other.len())
	}

	show_counts : Engine.Remote(List({ name : Str, bytes : U64, sum : U64 }), Worker.Error(Engine.FileError)) -> Str
	show_counts = |{ request, answer }| match answer {
		Unanswered => if (request == Pending) "counting" else "not counted"
		Answered(counts) => Str.join_with(counts.map(|c| "${c.name}:${c.bytes.to_str()}:${c.sum.to_str()}"), "|")
		Failed(Lost(fault)) => "lost ${Str.inspect(fault)}"
		Failed(Failed(reason)) => "unread ${Str.inspect(reason)}"
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

	view : State(ctx, S) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	view = |st| {
		v = st.signal()
		inbox = FilesApp.h.inbox
		Html.div(
			"files",
			[
				Html.file_input(Engine.const("Upload"), { selection: Multiple }, st.on_files(FilesApp.received)),
				Engine.element("section", [Html.aria_label("Drop"), Html.on_drop_files(st.on_files(FilesApp.received))], [Engine.text("drop here")]),
				Engine.element("section", [Html.aria_label("Paste"), Html.on_paste_files(st.on_files(FilesApp.received))], [Engine.text("paste here")]),
				Engine.element("section", [Html.aria_label("Inbox"), Html.on_drop_files(Engine.handle_files(FilesApp.arrived))], [Engine.text("inbox")]),
				Engine.element(
					"section",
					[Html.aria_label("Inbox with a reading"), Html.on_drop_files(Engine.handle_files_by(inbox.signal().map(|held| held.len()), FilesApp.arrived_after))],
					[Engine.text("inbox, added to")],
				),
				Engine.element(
					"section",
					[Html.aria_label("Inbox and list"), Html.on_drop_files(st.on_files(FilesApp.received).also(Engine.handle_files(FilesApp.arrived)))],
					[Engine.text("inbox and list")],
				),
				Html.button("Empty inbox", [], Engine.does(FilesApp.emptied)),
				Html.p_s(inbox.signal().map(FilesApp.listing), [Engine.test_id("inbox")]),
				Html.p_s(FilesApp.h.note.signal(), [Engine.test_id("note")]),
				Html.button("Keep first", [], st.update(|s| { ..s, files: FilesApp.first_only(s.files) })),
				Html.button("Clear", [], st.update(|s| { ..s, files: [] })),
				Html.p_s(v.map(|s| FilesApp.listing(s.files)), [Engine.test_id("files")]),
				Html.p_s(v.map(|s| "refused ${s.refused.to_str()}"), [Engine.test_id("refused")]),
				Html.button("Count", [], st.update(|s| { ..s, ask: Count(s.files) })),
				Html.button("Count tail", [], st.update(|s| { ..s, ask: Tail(FilesApp.tail_of(s.files)) })),
				Html.button("Probe", [], st.update(|s| { ..s, ask: Probe(FilesApp.first_only(s.files)) })),
				Html.button("Forget", [], st.update(|s| { ..s, ask: Nothing })),
				Worker.derive_when(FilesApp.count, v.map(|s| FilesApp.asked(s.ask)), |r| Html.p_s(r.map(FilesApp.show_counts), [Engine.test_id("counts")])),
				Worker.derive_when(
					FilesApp.probe,
					v.map(|s| FilesApp.probed(s.ask)),
					|r| Html.p_s(
						r.map(|remote| remote.answered().map_ok(|ok| if (ok) "probe ok" else "probe failed") ?? "no probe"),
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
								Html.file_input(Engine.const("Panel upload"), { accept: Types(".txt") }, inner.on_files(|kept, { files, refused: _ }| kept.concat(files))),
								Html.p_s(inner.signal().map(FilesApp.listing), [Engine.test_id("panel-files")]),
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
		Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| FilesApp.store, |_| Engine.state({ files: [], refused: 0, panel: Bool.False, ask: Nothing }, |st| FilesApp.view(st)))
			.with_workers([FilesApp.count.registration(), FilesApp.probe.registration()])
}

## A drop on "Inbox" writes the inbox and the note as one decision, and
## "Empty inbox" both again.
expect {
	after = FilesApp.store.after(FilesApp.arrived({ files: [], refused: 3 }))
	added = after.after(FilesApp.arrived_after(2, { files: [], refused: 0 }))
	gone = added.after(FilesApp.emptied)
	(after.read(FilesApp.h.note), added.read(FilesApp.h.note), gone.read(FilesApp.h.note), gone.read(FilesApp.h.inbox).len()) == ("0 arrived, 3 refused", "0 arrived after 2", "emptied", 0)
}
