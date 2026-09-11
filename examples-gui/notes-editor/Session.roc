import Document
import pf.Elem exposing [Elem]
import pf.Files

## A document operation runs as one effect that owns the snapshot it submitted;
## editing the live body while a save runs never changes what that save writes.
Session := [].{
	Destination := [NewDocument, OpenDocument, RevertDocument].{
		is_eq : _
	}

	Operation := [Opening, Saving].{
		is_eq : _
	}

	Phase := [Idle, ConfirmDiscard(Destination), Busy(Operation)].{
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
	close_decision : State -> Elem.CloseDecision
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
	save_and_close = |state| { ..begin_save({ ..state, close: NoClose }), close: SaveClose }

	## Only one file operation may be started for this document at a time.
	can_start : State -> Bool
	can_start = |state| state.phase == Idle and state.close == NoClose

	## A save keeps the editor available, since it writes the snapshot it was
	## given; document replacement waits for its result.
	can_edit : Phase -> Bool
	can_edit = |phase|
		match phase {
			Idle | Busy(Saving) => True
			_ => False
		}

	## A file's final path component supplies the document's displayed name.
	## The native worker returns the operating system's own spelling, so the
	## component is located through the typed `Files.Path` boundary.
	file_name : Str -> Str
	file_name = |path| Files.parse_path(path).name()

	## Start a save; the effect that follows captures the draft it submits.
	begin_save : State -> State
	begin_save = |state|
		if can_start(state) {
			{ ..state, phase: Busy(Saving), problem: None }
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
				Busy(Opening)
			}
			{ ..state, phase, problem: None }
		} else {
			state
		}

	## Discarding the draft continues the open that asked for confirmation.
	confirm_open : State -> State
	confirm_open = |state|
		match state.phase {
			ConfirmDiscard(OpenDocument) => { ..state, phase: Busy(Opening), problem: None }
			_ => state
		}

	## Install a read result as a complete new accepted document. The view uses
	## the same file value for its body source in one coordinated state write.
	loaded : State, { path : Str, text : Str } -> State
	loaded = |state, file|
		match state.phase {
			Busy(Opening) => {
				# The file is decoded once, here: the editor holds LF text with
				# no byte-order mark, and the format remembers what the file used
				# so a save writes that spelling back.
				opened = Document.decode(file.text)
				{
					document_generation: next_generation(state),
					close: NoClose,
					path: Some(file.path),
					baseline: { title: file_name(file.path), body: opened.text },
					body: opened.text,
					format: opened.format,
					phase: Idle,
					problem: None,
				}
			}
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
			Busy(Opening) => "Opening document…"
			Busy(Saving) => "Saving document…"
		}

	## A successful save accepts the submitted body, never a later editor value.
	## The current draft may therefore remain dirty after this operation succeeds.
	written : State, { path : Str, body : Str } -> State
	written = |state, saved|
		match state.phase {
			Busy(Saving) => {
				..state,
				close: if state.close == SaveClose {
					AllowClose
				} else {
					NoClose
				},
				path: Some(saved.path),
				baseline: { title: file_name(saved.path), body: saved.body },
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
## A save commits the body as it was when the save began; later typing stays dirty.
expect {
	editing = Session.edit(Session.initial, "First revision")
	saving = Session.begin_save(editing)
	saved = Session.edit(Session.written(saving, { path: "/tmp/Ideas.txt", body: "First revision" }), "Second revision")
	actual =
		\\saved body: ${saved.baseline.body}
		\\still dirty: ${Str.inspect(Document.is_dirty({ draft: Session.draft(saved), baseline: saved.baseline }))}
		\\ready: ${Str.inspect(Session.can_start(saved))}
	actual ==
		\\saved body: First revision
		\\still dirty: True
		\\ready: True
}

## A second save request while one is running changes nothing.
expect {
	saving = Session.begin_save(Session.initial)
	Session.begin_save(saving) == saving
}

## Cancellation and failure keep the accepted document and the edited body.
expect {
	accepted = { title: "Ideas.txt", body: "Accepted" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: accepted, body: "Edited" }
	saving = Session.begin_save(state)
	canceled = Session.cancel(saving)
	failed = Session.failed(saving, "Permission denied")
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

## Opening over an edited draft asks first; confirming starts the read.
expect {
	requested = Session.begin_open(Session.edit(Session.initial, "Keep this draft"))
	requested.phase == ConfirmDiscard(OpenDocument) and Session.confirm_open(requested).phase == Busy(Opening)
}

## Saving equal text is still a save.
expect {
	accepted = { title: "Ideas.txt", body: "Same text" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: accepted, body: accepted.body }
	saved = Session.written(Session.begin_save(state), { path: "/tmp/Ideas.txt", body: "Same text" })
	Session.begin_save(saved).phase == Busy(Saving)
}

## A loaded file installs its text as the body, decoded, under a new lifetime.
expect {
	requested = { ..Session.initial, phase: Busy(Opening) }
	loaded = Session.loaded(requested, { path: "/tmp/新しい note.txt", text: "Heading\r\n\r\nBody\r\n" })
	loaded.baseline == { title: "新しい note.txt", body: "Heading\n\nBody\n" } and loaded.body == "Heading\n\nBody\n" and loaded.format == { ending: Crlf, bom: False }
}

## Closing with unsaved work waits for a decision; a completed save closes.
expect {
	requested = Session.request_close(Session.edit(Session.initial, "Keep this"))
	saving = Session.save_and_close(requested)
	done = Session.written(saving, { path: "/tmp/Close.txt", body: "Keep this" })
	actual =
		\\requested: ${Str.inspect(Session.close_decision(requested))}
		\\saving: ${Str.inspect(Session.close_decision(saving))}
		\\done: ${Str.inspect(Session.close_decision(done))}
		\\saved: ${done.baseline.body}
	actual ==
		\\requested: AwaitDecision
		\\saving: AwaitDecision
		\\done: Close
		\\saved: Keep this
}

## A failed or canceled closing save keeps the window open.
expect {
	saving = Session.save_and_close(Session.request_close(Session.edit(Session.initial, "Draft")))
	Session.close_decision(Session.failed(saving, "Permission denied")) == KeepOpen and Session.close_decision(Session.cancel(saving)) == KeepOpen
}

## Every accepted replacement takes a fresh lifetime, even for equal text.
expect {
	reading = { ..Session.initial, phase: Session.Phase.Busy(Session.Operation.Opening) }
	loaded = Session.loaded(reading, { path: "/tmp/Empty.txt", text: "" })
	next = Session.new_document(loaded)
	loaded.document_generation == 1 and next.document_generation == 2
}

expect {
	open_again : Session.State -> Session.State
	open_again = |state| Session.loaded({ ..state, phase: Session.Phase.Busy(Session.Operation.Opening) }, { path: "/tmp/Same.txt", text: "Same body" })
	first = open_again(Session.initial)
	second = open_again(first)
	third = open_again(second)
	[first, second, third].map(|state| { generation: state.document_generation, body: state.body }) == [
		{ generation: 1, body: "Same body" },
		{ generation: 2, body: "Same body" },
		{ generation: 3, body: "Same body" },
	]
}

## Typing, saving, failing and canceling never touch the lifetime.
expect {
	state = { ..Session.initial, document_generation: 4, path: Some("/tmp/Ideas.txt"), baseline: { title: "Ideas.txt", body: "Body" }, body: "Body" }
	typed = Session.edit(state, "Body and more")
	writing = Session.begin_save(typed)
	saved = Session.written(writing, { path: "/tmp/Ideas.txt", body: "Body and more" })
	failed = Session.failed(writing, "Permission denied")
	canceled = Session.cancel(Session.begin_open(typed))
	[typed, writing, saved, failed, canceled].map(|value| value.document_generation) == [4, 4, 4, 4, 4]
}

## Reverting is a document replacement: the accepted text under a new lifetime.
expect {
	state = { ..Session.initial, document_generation: 2, path: Some("/tmp/Ideas.txt"), baseline: { title: "Ideas.txt", body: "Accepted" }, body: "Edited" }
	reverted = Session.revert({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) })
	reverted.document_generation == 3 and reverted.body == "Accepted" and reverted.phase == Idle
}

## A failed read keeps the draft and its lifetime.
expect {
	state = { ..Session.initial, document_generation: 7, phase: Session.Phase.Busy(Session.Operation.Opening), body: "Draft" }
	failed = Session.failed(state, "Not valid UTF-8: document bytes")
	failed.document_generation == 7 and failed.body == "Draft" and failed.baseline == Document.blank
}

expect {
	last = { ..Session.initial, document_generation: 18446744073709551614, phase: Session.Phase.Busy(Session.Operation.Opening) }
	Session.loaded(last, { path: "/tmp/Last.txt", text: "" }).document_generation == 18446744073709551615
}
