import Explorer
import pf.Files
import pf.Rows

## The last successful dataset stays available throughout chooser and scan work.
## Phase is an explicit workflow state; task results update it through one command.
Session := [].{
	Source := [Sample, Folder(Str)].{
		is_eq : _
	}
	Phase := [Idle, Choosing, Scanning(Str)].{
		is_eq : _
	}
	State : {
		rows : Rows.Rows(Explorer.Entry),
		selection : Explorer.Selection,
		source : Source,
		phase : Phase,
		notice : Str,
	}

	initial : State
	initial = {
		rows: Rows.from_list(Explorer.sample_entries, |entry| entry.path) ?? crash "Sample paths must be unique",
		selection: NoSelection,
		source: Sample,
		phase: Idle,
		notice: "Explore the sample or choose a folder on this computer.",
	}

	begin_choose : State -> State
	begin_choose = |state| if state.phase == Idle {
		{ ..state, phase: Choosing, notice: "Choose a folder to inspect." }
	} else {
		state
	}

	rescan : State -> State
	rescan = |state| match (state.phase, state.source) {
		(Idle, Folder(path)) => { ..state, phase: Scanning(path), notice: "Scanning ${path}. Previous results remain available." }
		_ => state
	}

	chosen : State, Files.Choice -> State
	chosen = |state, choice| match (state.phase, choice) {
		(Choosing, Files.Choice.Canceled) => { ..state, phase: Idle, notice: "Folder selection canceled." }
		(Choosing, Files.Choice.Chosen(path)) => { ..state, phase: Scanning(path), notice: "Scanning ${path}. Previous results remain available." }
		_ => crash "A folder choice arrived outside its operation"
	}

	entry : Files.Entry -> Explorer.Entry
	entry = |value| {
		path: value.path,
		bytes: value.bytes,
		kind: match value.kind {
			Files.Kind.File => File
			Files.Kind.Directory => Directory
			Files.Kind.SymbolicLink => SymbolicLink
			Files.Kind.Other => Other
		},
	}

	loaded : State, Files.Scan -> State
	loaded = |state, scan| match state.phase {
		Scanning(path) if path == scan.root => {
			entries = scan.entries.map(entry)
			{
				rows: Rows.replace_all(state.rows, entries) ?? crash "Scanned paths must be unique",
				selection: Explorer.selection_after_scan(state.selection, entries),
				source: Folder(scan.root),
				phase: Idle,
				notice: "Scan complete: ${entries.len().to_str()} entries.",
			}
		}
		_ => crash "A scan arrived outside its matching operation"
	}

	failed : State, Files.Error -> State
	failed = |state, error| match state.phase {
		Idle => crash "A task failure arrived outside its operation"
		_ => { ..state, phase: Idle, notice: Files.error_text(error) }
	}

	load_sample : State -> State
	load_sample = |state| if state.phase == Idle {
		{ ..initial, rows: Rows.replace_all(state.rows, Explorer.sample_entries) ?? crash "Sample paths must be unique" }
	} else {
		state
	}
}

## Cancellation and errors preserve the last successful dataset and selection.
expect {
	before = { ..Session.initial, selection: Selected({ path: "README.md", kind: File, bytes: 1536 }), phase: Scanning("/tmp/project") }
	after = Session.failed(before, Files.Error.Canceled)
	Rows.content_is_eq(after.rows, before.rows) and after.selection == before.selection and after.source == before.source and after.phase == Idle
}

## A successful rescan refreshes surviving selected metadata and retains its path.
expect {
	before = { ..Session.initial, selection: Selected({ path: "/tmp/project/note.txt", kind: File, bytes: 5 }), phase: Scanning("/tmp/project") }
	after = Session.loaded(before, { root: "/tmp/project", entries: [{ path: "/tmp/project/note.txt", kind: Files.Kind.File, bytes: 12 }] })
	after.selection == Selected({ path: "/tmp/project/note.txt", kind: File, bytes: 12 }) and after.source == Folder("/tmp/project") and after.phase == Idle
}

## Dismissing the native chooser leaves sample provenance and content intact.
expect {
	after = Session.chosen(Session.begin_choose(Session.initial), Files.Choice.Canceled)
	Rows.content_is_eq(after.rows, Session.initial.rows) and after.source == Sample and after.phase == Idle
}
