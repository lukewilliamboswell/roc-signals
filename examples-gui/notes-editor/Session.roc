import Document

## A document operation owns its submitted snapshot until its task settles.
## Editing the live body while a write runs never changes what that write saves.
Session := [].{
	Destination := [NewDocument, OpenDocument, RevertDocument].{
		is_eq : _
	}

	Write : { path : Str, document : Document.Snapshot }
	SaveChoice : { document : Document.Snapshot, previous_path : [None, Some(Str)] }

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

	State : {
		path : [None, Some(Str)],
		baseline : Document.Snapshot,
		phase : Phase,
		problem : [None, Some(Str)],
	}

	initial : State
	initial = { path: None, baseline: Document.blank, phase: Idle, problem: None }

	## Only one file operation may be started for this document at a time.
	can_start : State -> Bool
	can_start = |state| state.phase == Idle

	## Writes keep the editor available; document replacement waits for its result.
	can_edit : Phase -> Bool
	can_edit = |phase|
		match phase {
			Idle | Writing(_) => True
			_ => False
		}

	## A file's final path segment supplies the document's displayed name.
	file_name : Str -> Str
	file_name = |path| path.split_on("/").fold(path, |_, segment| segment)

	## Capture a save snapshot before any dialog or write begins.
	begin_save : { state : State, draft : Document.Snapshot, save_as : Bool } -> State
	begin_save = |{ state, draft, save_as }|
		if can_start(state) {
			phase = match state.path {
				Some(path) if !save_as => Writing({ path, document: draft })
				_ => ChoosingSave({ document: draft, previous_path: state.path })
			}
			{ ..state, phase, problem: None }
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
			ChoosingSave(choice) => { ..state, phase: Writing({ path, document: choice.document }) }
			_ => crash "A file choice arrived without its owning Notes operation"
		}

	## Install a read result as a complete new accepted document. The view uses
	## the same file value for its body source in one coordinated state write.
	from_file : { path : Str, text : Str } -> State
	from_file = |file| {
		path: Some(file.path),
		baseline: { title: file_name(file.path), body: file.text },
		phase: Idle,
		problem: None,
	}

	## A successful read belongs to the active reading operation.
	loaded : State, { path : Str, text : Str } -> State
	loaded = |state, file|
		match state.phase {
			Reading(_) => from_file(file)
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
				path: Some(path),
				baseline: { title: file_name(path), body: write.document.body },
				phase: Idle,
				problem: None,
			}
			_ => crash "A file write arrived without its owning Notes operation"
		}

	## Cancellation ends only the operation, preserving the accepted document.
	cancel : State -> State
	cancel = |state| { ..state, phase: Idle, problem: None }

	## Failed native work keeps the baseline and current file location intact.
	failed : State, Str -> State
	failed = |state, problem| { ..state, phase: Idle, problem: Some(problem) }
}

## A save retains its submitted text even when a newer draft exists on completion.
expect {
	draft = { title: "Untitled note", body: "First revision" }
	choosing = Session.begin_save({ state: Session.initial, draft, save_as: False })
	writing = Session.choose_path(choosing, "/tmp/Ideas.txt")
	saved = Session.written(writing, "/tmp/Ideas.txt")
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

## A second save cannot replace an active write's captured snapshot.
expect {
	draft = { title: "Ideas.txt", body: "First revision" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: draft }
	writing = Session.begin_save({ state, draft, save_as: False })
	second = Session.begin_save({ state: writing, draft: { ..draft, body: "Second revision" }, save_as: False })
	second == writing
}

## Dialog cancellation and write failures preserve the previously accepted file.
expect {
	draft = { title: "Ideas.txt", body: "Accepted" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: draft }
	choosing = Session.begin_save({ state, draft: { ..draft, body: "Edited" }, save_as: True })
	canceled = Session.cancel(choosing)
	failed = Session.failed(choosing, "Permission denied")
	actual =
		\\cancel baseline: ${canceled.baseline.body}
		\\failure baseline: ${failed.baseline.body}
		\\failure path: ${Str.inspect(failed.path)}
	actual ==
		\\cancel baseline: Accepted
		\\failure baseline: Accepted
		\\failure path: Some("/tmp/Ideas.txt")
}

## An edited document requires discard confirmation before the Open dialog starts.
expect {
	draft = { ..Document.blank, body: "Keep this draft" }
	requested = Session.begin_open({ state: Session.initial, draft })
	requested.phase == ConfirmDiscard(OpenDocument)
}

## Finishing a write allows the same text to be saved again without a nonce.
expect {
	draft = { title: "Ideas.txt", body: "Same text" }
	state = { ..Session.initial, path: Some("/tmp/Ideas.txt"), baseline: draft }
	first = Session.begin_save({ state, draft, save_as: False })
	saved = Session.written(first, "/tmp/Ideas.txt")
	second = Session.begin_save({ state: saved, draft, save_as: False })
	second.phase == Writing({ path: "/tmp/Ideas.txt", document: draft })
}

## A successful read replaces the baseline and names the file without parsing its body.
expect {
	requested = { ..Session.initial, phase: Reading("/tmp/新しい note.txt") }
	loaded = Session.loaded(requested, { path: "/tmp/新しい note.txt", text: "Heading\n\nBody\n" })
	loaded.baseline == { title: "新しい note.txt", body: "Heading\n\nBody\n" }
}
