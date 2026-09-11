import Document
import pf.Files
import pf.Gui

## A document operation owns its submitted snapshot until its task settles.
## Editing the live body while a write runs never changes what that write saves.
Session := [].{
	Destination := [NewDocument, OpenDocument, RevertDocument].{
		is_eq : _
	}

	Write : { path : Str, document : Document.Snapshot, format : Document.Format }
	SaveChoice : { document : Document.Snapshot, format : Document.Format, previous_path : [None, Some(Str)] }

	Phase := [
		Idle,
		ConfirmDiscard(Destination),
		ChoosingOpen,
		Reading(Str),
		ChoosingSave(SaveChoice),
		Writing(Write),
	].{
		is_eq : _
	}

	CloseState := [NoClose, ConfirmClose, SaveClose, AllowClose].{
		is_eq : _
	}

	## The editable body belongs to the same state as the lifetime that owns it.
	## A document replacement therefore advances `document_generation` and
	## installs its text in one settled value, so the editor identity keyed by
	## that generation can never be paired with another document's text.
	State : {
		document_generation : U64,
		close : CloseState,
		path : [None, Some(Str)],
		baseline : Document.Snapshot,
		body : Str,
		## The opened file's line-end spelling and byte-order mark, written back on save.
		format : Document.Format,
		phase : Phase,
		problem : [None, Some(Str)],
	}

	initial : State
	initial = { document_generation: 0, close: NoClose, path: None, baseline: Document.blank, body: "", format: Document.native_format, phase: Idle, problem: None }

	## Ordinary typing is not a document replacement: it never advances the
	## lifetime, so the native editor keeps its own selection and undo history.
	edit : State, Str -> State
	edit = |state, body| { ..state, body }

	## New document lifetimes reset native editing history independently of text.
	new_document : State -> State
	new_document = |state| { ..initial, document_generation: next_generation(state) }

	## Reverting installs the accepted baseline as a replacement document, so it
	## also abandons the native history that belonged to the discarded draft.
	revert : State -> State
	revert = |state| { ..cancel(state), document_generation: next_generation(state), body: state.baseline.body }

	## Never reuse an editor lifetime after generation exhaustion.
	next_generation : State -> U64
	next_generation = |state| if state.document_generation == 18446744073709551615 {
		crash "Notes document lifetime exhausted"
	} else {
		state.document_generation + 1
	}

	## Window closure remains an ordinary app transition, including async saving.
	close_decision : State -> Gui.CloseDecision
	close_decision = |state| match state.close {
		NoClose => KeepOpen
		ConfirmClose | SaveClose => AwaitDecision
		AllowClose => Close
	}

	request_close : State -> State
	request_close = |state| if state.phase != Idle {
		{ ..state, problem: Some("Finish or cancel the current file operation before closing.") }
	} else if Document.is_dirty({ draft: draft(state), baseline: state.baseline }) {
		{ ..state, close: ConfirmClose, problem: None }
	} else {
		{ ..state, close: AllowClose }
	}

	save_and_close : State -> State
	save_and_close = |state| {
		next = begin_save({ state: { ..state, close: NoClose }, save_as: False })
		{ ..next, close: SaveClose }
	}

	## Only one file operation may be started for this document at a time.
	can_start : State -> Bool
	can_start = |state| state.phase == Idle and state.close == NoClose

	## Writes keep the editor available; document replacement waits for its result.
	can_edit : Phase -> Bool
	can_edit = |phase|
		match phase {
			Idle | Writing(_) => True
			_ => False
		}

	## A file's final path component supplies the document's displayed name.
	## The native worker returns the operating system's own spelling, so the
	## component is located through the typed `Files.Path` boundary.
	file_name : Str -> Str
	file_name = |path| Files.parse_path(path).name()

	## Capture a save snapshot before any dialog or write begins.
	begin_save : { state : State, save_as : Bool } -> State
	begin_save = |{ state, save_as }|
		if can_start(state) {
			phase = match state.path {
				Some(path) if !save_as => Writing({ path, document: draft(state), format: state.format })
				_ => ChoosingSave({ document: draft(state), format: state.format, previous_path: state.path })
			}
			{ ..state, phase, problem: None }
		} else {
			state
		}

	## Opening a document asks before replacing an edited draft.
	begin_open : State -> State
	begin_open = |state|
		if can_start(state) {
			phase = if Document.is_dirty({ draft: draft(state), baseline: state.baseline }) {
				ConfirmDiscard(OpenDocument)
			} else {
				ChoosingOpen
			}
			{ ..state, phase, problem: None }
		} else {
			state
		}

	## Choosing a path continues the operation that owns that dialog.
	choose_path : State, Str -> State
	choose_path = |state, path|
		match state.phase {
			ChoosingOpen => { ..state, phase: Reading(path) }
			ChoosingSave(choice) => { ..state, phase: Writing({ path, document: choice.document, format: choice.format }) }
			_ => crash "A file choice arrived without its owning Notes operation"
		}

	## Describe a complete new accepted document. Only `loaded` installs one,
	## because only that path can allocate the lifetime that must own it.
	from_file : { path : Str, text : Str } -> State
	from_file = |file| {
		opened = Document.decode(file.text)
		{
			document_generation: 0,
			close: NoClose,
			path: Some(file.path),
			baseline: { title: file_name(file.path), body: opened.text },
			body: opened.text,
			format: opened.format,
			phase: Idle,
			problem: None,
		}
	}

	## A successful read belongs to the active reading operation. Every accepted
	## replacement takes a fresh lifetime, including one whose text equals the
	## text already on screen, because it is a different document.
	loaded : State, { path : Str, text : Str } -> State
	loaded = |state, file|
		match state.phase {
			Reading(_) => { ..from_file(file), document_generation: next_generation(state) }
			_ => crash "A file read arrived without its owning Notes operation"
		}

	## A draft's displayed name follows its current file; the body remains an
	## independent editable source while background writes hold older snapshots.
	draft : State -> Document.Snapshot
	draft = |state| { title: state.baseline.title, body: state.body }

	## Describe operation progress without exposing internal task identifiers.
	status : State -> Str
	status = |state|
		match state.phase {
			Idle | ConfirmDiscard(_) => if Document.is_dirty({ draft: draft(state), baseline: state.baseline }) {
				"Unsaved changes"
			} else {
				"No changes"
			}
			ChoosingOpen => "Choose a document…"
			Reading(_) => "Opening document…"
			ChoosingSave(_) => "Choose where to save…"
			Writing(_) => "Saving document…"
		}

	## A successful save accepts the submitted body, never a later editor value.
	## The current draft may therefore remain dirty after this operation succeeds.
	written : State, Str -> State
	written = |state, path|
		match state.phase {
			Writing(write) => {
				..state,
				close: if state.close == SaveClose {
					AllowClose
				} else {
					NoClose
				},
				path: Some(path),
				baseline: { title: file_name(path), body: write.document.body },
				phase: Idle,
				problem: None,
			}
			_ => crash "A file write arrived without its owning Notes operation"
		}

	## Cancellation ends only the operation, preserving the accepted document.
	cancel : State -> State
	cancel = |state| { ..state, phase: Idle, close: NoClose, problem: None }

	## Failed native work keeps the baseline and current file location intact.
	failed : State, Str -> State
	failed = |state, problem| { ..state, phase: Idle, close: NoClose, problem: Some(problem) }
}

## A save retains its submitted text even when a newer draft exists on completion.
expect {
	editing = Session.edit(Session.initial, "First revision")
	choosing = Session.begin_save({ state: editing, save_as: False })
	writing = Session.choose_path(choosing, "/tmp/Ideas.txt")
	saved = Session.edit(Session.written(writing, "/tmp/Ideas.txt"), "Second revision")
	actual =
		\\saved body: ${saved.baseline.body}
		\\still dirty: ${Str.inspect(Document.is_dirty({ draft: Session.draft(saved), baseline: saved.baseline }))}
		\\ready: ${Str.inspect(Session.can_start(saved))}
	actual ==
		\\saved body: First revision
		\\still dirty: True
		\\ready: True
}

## A second save cannot replace an active write's captured snapshot.
expect {
	accepted = { title: "Ideas.txt", body: "First revision" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: accepted, body: accepted.body }
	writing = Session.begin_save({ state, save_as: False })
	second = Session.begin_save({ state: Session.edit(writing, "Second revision"), save_as: False })
	second.phase == writing.phase
}

## Dialog cancellation and write failures preserve the previously accepted file.
expect {
	accepted = { title: "Ideas.txt", body: "Accepted" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: accepted, body: "Edited" }
	choosing = Session.begin_save({ state, save_as: True })
	canceled = Session.cancel(choosing)
	failed = Session.failed(choosing, "Permission denied")
	actual =
		\\cancel baseline: ${canceled.baseline.body}
		\\cancel body: ${canceled.body}
		\\failure baseline: ${failed.baseline.body}
		\\failure path: ${Str.inspect(failed.path)}
	actual ==
		\\cancel baseline: Accepted
		\\cancel body: Edited
		\\failure baseline: Accepted
		\\failure path: Some("/tmp/Ideas.txt")
}

## An edited document requires discard confirmation before the Open dialog starts.
expect {
	requested = Session.begin_open(Session.edit(Session.initial, "Keep this draft"))
	requested.phase == ConfirmDiscard(OpenDocument)
}

## Finishing a write allows the same text to be saved again without a nonce.
expect {
	accepted = { title: "Ideas.txt", body: "Same text" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: accepted, body: accepted.body }
	first = Session.begin_save({ state, save_as: False })
	saved = Session.written(first, "/tmp/Ideas.txt")
	second = Session.begin_save({ state: saved, save_as: False })
	second.phase == Writing({ path: "/tmp/Ideas.txt", document: accepted, format: Document.native_format })
}

## A successful read replaces the baseline and names the file without parsing its body.
expect {
	requested = { ..Session.initial, phase: Reading("/tmp/新しい note.txt") }
	loaded = Session.loaded(requested, { path: "/tmp/新しい note.txt", text: "Heading\n\nBody\n" })
	loaded.baseline == { title: "新しい note.txt", body: "Heading\n\nBody\n" } and loaded.body == "Heading\n\nBody\n"
}

## Saving before closing closes only after its owned write has succeeded.
expect {
	requested = Session.request_close(Session.edit(Session.initial, "Keep this"))
	saving = Session.save_and_close(requested)
	writing = Session.choose_path(saving, "/tmp/Close.txt")
	done = Session.written(writing, "/tmp/Close.txt")
	actual =
		\\requested: ${Str.inspect(Session.close_decision(requested))}
		\\saving: ${Str.inspect(Session.close_decision(writing))}
		\\done: ${Str.inspect(Session.close_decision(done))}
		\\saved: ${done.baseline.body}
	actual ==
		\\requested: AwaitDecision
		\\saving: AwaitDecision
		\\done: Close
		\\saved: Keep this
}

## Failed or canceled saves abandon closure while preserving the current draft owner.
expect {
	saving = Session.save_and_close(Session.request_close(Session.edit(Session.initial, "Draft")))
	Session.close_decision(Session.failed(saving, "Permission denied")) == KeepOpen and Session.close_decision(Session.cancel(saving)) == KeepOpen
}

## Equal text still belongs to a new document lifetime when opened or reset.
expect {
	reading = { ..Session.initial, phase: Session.Phase.Reading("/tmp/Empty.txt") }
	loaded = Session.loaded(reading, { path: "/tmp/Empty.txt", text: "" })
	next = Session.new_document(loaded)
	loaded.document_generation == 1 and next.document_generation == 2
}

## Repeated opens of equal text keep allocating distinct lifetimes, and the body
## installed by a replacement always belongs to that replacement's lifetime.
expect {
	open_again : Session.State -> Session.State
	open_again = |state| Session.loaded({ ..state, phase: Session.Phase.Reading("/tmp/Same.txt") }, { path: "/tmp/Same.txt", text: "Same body" })
	first = open_again(Session.initial)
	second = open_again(first)
	third = open_again(second)
	[first, second, third].map(|state| { generation: state.document_generation, body: state.body }) == [
		{ generation: 1, body: "Same body" },
		{ generation: 2, body: "Same body" },
		{ generation: 3, body: "Same body" },
	]
}

## Typing, saving, cancellation and temporary availability changes all preserve
## the current editor lifetime.
expect {
	state = { ..Session.initial, document_generation: 4, path: Some("/tmp/Ideas.txt"), baseline: { title: "Ideas.txt", body: "Body" }, body: "Body" }
	typed = Session.edit(state, "Body and more")
	writing = Session.begin_save({ state: typed, save_as: False })
	saved = Session.written(writing, "/tmp/Ideas.txt")
	failed = Session.failed(writing, "Permission denied")
	canceled = Session.cancel(Session.begin_open(typed))
	[typed, writing, saved, failed, canceled].map(|value| value.document_generation) == [4, 4, 4, 4, 4]
}

## Reverting a draft is a document replacement, so it takes a fresh lifetime and
## restores the accepted baseline text.
expect {
	state = { ..Session.initial, document_generation: 2, path: Some("/tmp/Ideas.txt"), baseline: { title: "Ideas.txt", body: "Accepted" }, body: "Edited" }
	reverted = Session.revert({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) })
	reverted.document_generation == 3 and reverted.body == "Accepted" and reverted.phase == Idle
}

## A failed read installs no document, so it neither replaces the draft nor
## spends a lifetime the reader would have to reconcile.
expect {
	state = { ..Session.initial, document_generation: 7, phase: Session.Phase.Reading("/tmp/Ideas.txt"), body: "Draft" }
	failed = Session.failed(state, "Not valid UTF-8: document bytes")
	failed.document_generation == 7 and failed.body == "Draft" and failed.baseline == Document.blank
}

## Lifetimes are allocated to exhaustion rather than wrapping around, because a
## reused lifetime would silently hand a new document the previous editor.
expect {
	last = { ..Session.initial, document_generation: 18446744073709551614, phase: Session.Phase.Reading("/tmp/Last.txt") }
	Session.loaded(last, { path: "/tmp/Last.txt", text: "" }).document_generation == 18446744073709551615
}
