import Document
import pf.Elem exposing [Elem]

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

	State : {
		document_generation : U64,
		close : CloseState,
		path : [None, Some(Str)],
		baseline : Document.Snapshot,
		phase : Phase,
		problem : [None, Some(Str)],
	}

	initial : State
	initial = { document_generation: 0, close: NoClose, path: None, baseline: Document.blank, phase: Idle, problem: None }

	## New document lifetimes reset native editing history independently of text.
	new_document : State -> State
	new_document = |state| { ..initial, document_generation: next_generation(state) }

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

	request_close : State, Str -> State
	request_close = |state, body| if state.phase != Idle {
		{ ..state, problem: Some("Finish or cancel the current file operation before closing.") }
	} else if Document.is_dirty({ draft: draft(state, body), baseline: state.baseline }) {
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

	## A file's final path segment supplies the document's displayed name.
	file_name : Str -> Str
	file_name = |path| path.split_on("/").fold(path, |_, segment| segment)

	## Start a save; the effect that follows captures the draft it submits.
	begin_save : State -> State
	begin_save = |state|
		if can_start(state) {
			{ ..state, phase: Busy(Saving), problem: None }
		} else {
			state
		}

	## Opening a document asks before replacing an edited draft.
	begin_open : { state : State, draft : Document.Snapshot } -> State
	begin_open = |{ state, draft }|
		if can_start(state) {
			phase = if Document.is_dirty({ draft, baseline: state.baseline }) {
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
				document_generation: next_generation(state),
				close: NoClose,
				path: Some(file.path),
				baseline: { title: file_name(file.path), body: file.text },
				phase: Idle,
				problem: None,
			}
			_ => crash "A file read arrived without its owning Notes operation"
		}

	## A draft's displayed name follows its current file; the body remains an
	## independent editable source while background writes hold older snapshots.
	draft : State, Str -> Document.Snapshot
	draft = |state, body| { title: state.baseline.title, body }

	## Describe operation progress without exposing internal task identifiers.
	status : { state : State, body : Str } -> Str
	status = |{ state, body }|
		match state.phase {
			Idle | ConfirmDiscard(_) => if Document.is_dirty({ draft: draft(state, body), baseline: state.baseline }) {
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
expect {
	saving = Session.begin_save(Session.initial)
	saved = Session.written(saving, { path: "/tmp/Ideas.txt", body: "First revision" })
	current = { title: "Ideas.txt", body: "Second revision" }
	actual =
		\\saved body: ${saved.baseline.body}
		\\still dirty: ${Str.inspect(Document.is_dirty({ draft: current, baseline: saved.baseline }))}
		\\ready: ${Str.inspect(Session.can_start(saved))}
	actual ==
		\\saved body: First revision
		\\still dirty: True
		\\ready: True
}

## A second save cannot start while one is running.
expect {
	saving = Session.begin_save(Session.initial)
	Session.begin_save(saving) == saving
}

## Dialog cancellation and write failures preserve the previously accepted file.
expect {
	draft = { title: "Ideas.txt", body: "Accepted" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: draft }
	saving = Session.begin_save(state)
	canceled = Session.cancel(saving)
	failed = Session.failed(saving, "Permission denied")
	actual =
		\\cancel baseline: ${canceled.baseline.body}
		\\failure baseline: ${failed.baseline.body}
		\\failure path: ${Str.inspect(failed.path)}
	actual ==
		\\cancel baseline: Accepted
		\\failure baseline: Accepted
		\\failure path: Some("/tmp/Ideas.txt")
}

## An edited document requires discard confirmation before the Open dialog starts,
## and discarding continues into the open.
expect {
	draft = { ..Document.blank, body: "Keep this draft" }
	requested = Session.begin_open({ state: Session.initial, draft })
	requested.phase == ConfirmDiscard(OpenDocument) and Session.confirm_open(requested).phase == Busy(Opening)
}

## Finishing a save allows the same text to be saved again without a nonce.
expect {
	draft = { title: "Ideas.txt", body: "Same text" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: draft }
	saved = Session.written(Session.begin_save(state), { path: "/tmp/Ideas.txt", body: "Same text" })
	Session.begin_save(saved).phase == Busy(Saving)
}

## A successful read replaces the baseline and names the file without parsing its body.
expect {
	requested = { ..Session.initial, phase: Busy(Opening) }
	loaded = Session.loaded(requested, { path: "/tmp/新しい note.txt", text: "Heading\n\nBody\n" })
	loaded.baseline == { title: "新しい note.txt", body: "Heading\n\nBody\n" }
}

## Saving before closing closes only after its owned write has succeeded.
expect {
	requested = Session.request_close(Session.initial, "Keep this")
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

## Failed or canceled saves abandon closure while preserving the current draft owner.
expect {
	saving = Session.save_and_close(Session.request_close(Session.initial, "Draft"))
	Session.close_decision(Session.failed(saving, "Permission denied")) == KeepOpen and Session.close_decision(Session.cancel(saving)) == KeepOpen
}

## Equal text still belongs to a new document lifetime when opened or reset.
expect {
	reading = { ..Session.initial, phase: Session.Phase.Busy(Session.Operation.Opening) }
	loaded = Session.loaded(reading, { path: "/tmp/Empty.txt", text: "" })
	next = Session.new_document(loaded)
	loaded.document_generation == 1 and next.document_generation == 2
}
