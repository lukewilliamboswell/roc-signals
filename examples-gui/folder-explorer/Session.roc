import Explorer
import pf.Files
import pf.Rows

## Accepted content and navigation history change together only after a complete
## directory result. Pending work owns its destination; cancel/error keep the
## accepted location, rows, selection, preview, and history available for retry.
Session := [].{
	Source := [Sample(Str), Folder(Str)].{
		is_eq : _
	}
	Travel := [Push, Back, Forward, Refresh].{
		is_eq : _
	}
	Visit : { destination : Source, travel : Travel }
	Phase := [Idle, Choosing, Listing(Visit), Previewing(Str), Opening(Str)].{
		is_eq : _
	}
	Retry := [NoRetry, Again(Phase)].{
		is_eq : _
	}
	Preview := [NoPreview, Ready(Files.Preview)].{
		is_eq : _
	}
	State : {
		rows : Rows.Rows(Explorer.Entry),
		selection : Explorer.Selection,
		query : Str,
		source : Source,
		back : List(Source),
		forward : List(Source),
		phase : Phase,
		retry : Retry,
		preview : Preview,
		notice : Str,
	}

	initial : State
	initial = {
		rows: Rows.from_list(Explorer.sample_children(""), |entry| entry.path) ?? crash "Sample paths must be unique",
		selection: NoSelection,
		query: "",
		source: Sample(""),
		back: [],
		forward: [],
		phase: Idle,
		retry: NoRetry,
		preview: NoPreview,
		notice: "Open a sample folder or choose a folder on this computer.",
	}

	path : Source -> Str
	path = |source| match source {
		Sample(value) => value
		Folder(value) => value
	}

	at_path : Source, Str -> Source
	at_path = |source, value| match source {
		Sample(_) => Sample(value)
		Folder(_) => Folder(value)
	}

	begin_choose : State -> State
	begin_choose = |state| if state.phase == Idle {
		{ ..state, phase: Choosing, retry: NoRetry, notice: "Choose a folder to browse." }
	} else {
		state
	}

	## Histories retain at most 64 accepted locations per direction.
	accept : State, Visit, List(Explorer.Entry) -> State
	accept = |state, visit, entries| {
		(back, forward) = match visit.travel {
			Push => ([state.source].concat(state.back).take_first(64), [])
			Back => (state.back.drop_first(1), [state.source].concat(state.forward).take_first(64))
			Forward => ([state.source].concat(state.back).take_first(64), state.forward.drop_first(1))
			Refresh => (state.back, state.forward)
		}
		{
			..state,
			rows: Rows.replace_all(state.rows, entries) ?? crash "Directory paths must be unique",
			selection: if visit.destination == state.source {
				Explorer.selection_after_scan(state.selection, entries)
			} else {
				NoSelection
			},
			query: if visit.destination == state.source {
				state.query
			} else {
				""
			},
			source: visit.destination,
			back,
			forward,
			phase: Idle,
			retry: NoRetry,
			preview: NoPreview,
			notice: loaded_text(entries.len()),
		}
	}

	begin_visit : State, Visit -> State
	begin_visit = |state, visit| if state.phase != Idle {
		state
	} else {
		match visit.destination {
			Sample(value) => accept(state, visit, Explorer.sample_children(value))
			Folder(value) => { ..state, phase: Listing(visit), retry: NoRetry, notice: "Loading ${value}. Showing the previous folder until it is ready." }
		}
	}

	navigate : State, Str -> State
	navigate = |state, target| {
		destination = at_path(state.source, target)
		begin_visit(
			state,
			{
				destination,
				travel: if destination == state.source {
					Refresh
				} else {
					Push
				},
			},
		)
	}

	backward : State -> State
	backward = |state| match state.back.first() {
		Ok(destination) => begin_visit(state, { destination, travel: Back })
		Err(_) => state
	}

	forward : State -> State
	forward = |state| match state.forward.first() {
		Ok(destination) => begin_visit(state, { destination, travel: Forward })
		Err(_) => state
	}

	up : State -> State
	up = |state| {
		current = path(state.source)
		parent = Explorer.parent_path(current)
		if current == parent {
			state
		} else {
			navigate(state, parent)
		}
	}

	refresh : State -> State
	refresh = |state| begin_visit(state, { destination: state.source, travel: Refresh })

	chosen : State, Files.Choice -> State
	chosen = |state, choice| match (state.phase, choice) {
		(Choosing, Files.Choice.Canceled) => { ..state, phase: Idle, notice: "Folder selection canceled." }
		(Choosing, Files.Choice.Chosen(value)) => begin_visit(
			{ ..state, phase: Idle },
			{
				destination: Folder(value),
				travel: if state.source == Folder(value) {
					Refresh
				} else {
					Push
				},
			},
		)
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

	loaded : State, Files.Directory -> State
	loaded = |state, result| match state.phase {
		Listing(visit) if visit.destination == Folder(result.path) => accept(state, visit, result.entries.map(entry))
		_ => crash "A directory result arrived outside its matching operation"
	}

	select : State, Explorer.Entry -> State
	select = |state, selected| if state.phase == Idle {
		{ ..state, selection: Selected(selected), preview: NoPreview }
	} else {
		state
	}

	activate : State, Explorer.Entry -> State
	activate = |state, selected| match selected.kind {
		Directory => navigate(state, selected.path)
		_ => select(state, selected)
	}

	## The listing notice reads as prose, so one entry is "1 entry loaded."
	loaded_text : U64 -> Str
	loaded_text = |count| if count == 1 { "1 entry loaded." } else { "${count.to_str()} entries loaded." }

	preview_selected : State -> State
	preview_selected = |state| match (state.phase, state.selection, state.source) {
		(Idle, Selected(selected), Sample(_)) if selected.kind == File => {
			..state,
			preview: Ready({ path: selected.path, text: Explorer.sample_text(selected.path), truncated: False }),
			notice: "Sample preview. Sample files are not stored on this computer.",
			retry: NoRetry,
		}
		(Idle, Selected(selected), Folder(_)) if selected.kind == File => { ..state, phase: Previewing(selected.path), retry: NoRetry, notice: "Reading a preview of ${selected.path}." }
		_ => state
	}

	previewed : State, Files.Preview -> State
	previewed = |state, result| match state.phase {
		Previewing(value) if value == result.path => {
			..state,
			phase: Idle,
			preview: Ready(result),
			notice: if result.truncated {
				"Preview loaded. Showing the first 64 KiB of text."
			} else {
				"Preview loaded."
			},
		}
		_ => crash "A preview arrived outside its matching operation"
	}

	open_selected : State -> State
	open_selected = |state| match (state.phase, state.selection, state.source) {
		(Idle, Selected(selected), Folder(_)) if selected.kind == File => { ..state, phase: Opening(selected.path), retry: NoRetry, notice: "Opening ${selected.path} in its associated application." }
		_ => state
	}

	opened : State, Str -> State
	opened = |state, launched| match state.phase {
		Opening(value) if value == launched => { ..state, phase: Idle, notice: "Opened ${launched} in its associated application." }
		_ => crash "A launch result arrived outside its matching operation"
	}

	failed : State, Files.Error -> State
	failed = |state, error| match state.phase {
		Idle => crash "A task failure arrived outside its operation"
		_ => { ..state, phase: Idle, retry: Again(state.phase), notice: Files.error_text(error) }
	}

	retry_last : State -> State
	retry_last = |state| match (state.phase, state.retry) {
		(Idle, Again(previous)) => { ..state, phase: previous, retry: NoRetry, notice: "Retrying the previous operation. Current content remains available." }
		_ => state
	}

	load_sample : State -> State
	load_sample = |state| begin_visit(
		state,
		{
			destination: Sample(""),
			travel: if state.source == Sample("") {
				Refresh
			} else {
				Push
			},
		},
	)

	Breadcrumb : { path : Str, label : Str }

	## Each crumb navigates to a real ancestor, so the trail is built by walking
	## the typed `Files.Path` components from that path's own root outward. A
	## Windows location therefore starts at its drive or share and keeps its own
	## separators; the sample tree keeps its named relative root.
	breadcrumbs : Source -> List(Breadcrumb)
	breadcrumbs = |source| {
		location = Files.parse_path(path(source))
		start = match source {
			Sample(_) => { path: Files.parse_path(""), label: "Sample" }
			Folder(_) => { path: location.root(), label: location.root().to_str() }
		}
		trail = location.components().fold(
			{ cursor: start.path, crumbs: [{ path: start.path.to_str(), label: start.label }] },
			|state, part| {
				next = state.cursor.join(part)
				{ cursor: next, crumbs: state.crumbs.append({ path: next.to_str(), label: part }) }
			},
		)
		trail.crumbs
	}
}

## Sample navigation is direct-child and uses the same bounded accepted history.
expect {
	root = Session.initial
	docs = Session.navigate(root, "docs")
	back = Session.backward(docs)
	again = Session.forward(back)
	docs.source == Sample("docs") and Rows.len(docs.rows) == 4 and back.source == root.source and Rows.len(back.rows) == 6 and again.source == docs.source and Session.up(docs).source == Sample("")
}

## Failed or canceled Back retains both histories and accepted content; retry
## continues the requested destination rather than refreshing the current one.
expect {
	before = { ..Session.initial, source: Folder("/tmp/docs"), back: [Folder("/tmp")], selection: Selected({ path: "/tmp/docs/a.txt", kind: File, bytes: 5 }) }
	pending = Session.backward(before)
	failed = Session.failed(pending, Files.Error.PermissionDenied("/tmp"))
	retry = Session.retry_last(failed)
	after = Session.loaded(retry, { path: "/tmp", entries: [] })
	Rows.content_is_eq(failed.rows, before.rows) and failed.selection == before.selection and failed.back == before.back and failed.source == before.source and after.source == Folder("/tmp") and after.back.is_empty() and after.forward == [before.source]
}

## Successful refresh updates surviving selected metadata and clears stale preview.
expect {
	before = { ..Session.initial, source: Folder("/tmp"), selection: Selected({ path: "/tmp/note.txt", kind: File, bytes: 5 }), preview: Ready({ path: "/tmp/note.txt", text: "old", truncated: False }) }
	after = Session.loaded(Session.refresh(before), { path: "/tmp", entries: [{ path: "/tmp/note.txt", kind: Files.Kind.File, bytes: 12 }] })
	after.selection == Selected({ path: "/tmp/note.txt", kind: File, bytes: 12 }) and after.preview == NoPreview and after.back == before.back
}

## Branching after Back discards forward history; each stack has a fixed bound.
expect {
	docs = Session.navigate(Session.initial, "docs")
	branched = Session.navigate(Session.backward(docs), "src")
	full = { ..Session.initial, back: List.repeat(Sample("docs"), 64) }
	branched.forward.is_empty() and Session.navigate(full, "test").back.len() == 64
}

## Preview and launch failures preserve the accepted preview and exact retry path.
expect {
	before = { ..Session.initial, source: Folder("/tmp"), selection: Selected({ path: "/tmp/a.txt", kind: File, bytes: 5 }), preview: Ready({ path: "/tmp/a.txt", text: "old", truncated: False }) }
	failed = Session.failed(Session.preview_selected(before), Files.Error.InvalidUtf8("/tmp/a.txt"))
	failed.preview == before.preview and Session.retry_last(failed).phase == Previewing("/tmp/a.txt") and Session.open_selected(before).phase == Opening("/tmp/a.txt")
}

## Breadcrumbs name real ancestors of the visited location on either operating
## system, including the sample tree's relative root.
expect {
	Session.breadcrumbs(Folder("/tmp/project")) == [{ path: "/", label: "/" }, { path: "/tmp", label: "tmp" }, { path: "/tmp/project", label: "project" }] and
	Session.breadcrumbs(Folder("C:\\Users\\Lee")) == [{ path: "C:\\", label: "C:\\" }, { path: "C:\\Users", label: "Users" }, { path: "C:\\Users\\Lee", label: "Lee" }] and
	Session.breadcrumbs(Sample("docs")) == [{ path: "", label: "Sample" }, { path: "docs", label: "docs" }]
}

expect Session.loaded_text(1) == "1 entry loaded." and Session.loaded_text(3) == "3 entries loaded."
