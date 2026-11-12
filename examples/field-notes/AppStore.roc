import pf.Engine
import Notes

## Field Notes' store: the state the whole page shares, held at the root
## and reached from any depth with no `lift`, and every change to it as a
## decision, a pure function that returns the writes it makes.
##
## - `board`: the notes and the outbox that syncs them, one value because
##   its parts must agree (`Notes.Board`). Every change to it is one of
##   `Notes`' pure functions on the board.
## - `draft`: the note being typed. It is a cell of its own, so a
##   keystroke wakes the box and the save button and none of the board's
##   readers.
## - `hide_synced`: whether the list leaves out the notes that have
##   synced.
##
## The store stands apart from the page (`NotesApp`) so that what the app
## shares and how it changes are read, and tested, without the markup.
##
## The module's one tag, `FieldNotes`, is the store's name. Nothing spells
## the store's storage type: an annotation that mentions it says `_`.
AppStore := [FieldNotes].{

	## The store: its name, and its cells with their starting values: an
	## empty board that is offline, nothing typed, every note shown.
	store = Engine.store(
		AppStore.FieldNotes,
		{
			board: Engine.cell(Notes.initial([], False)),
			draft: Engine.cell(""),
			hide_synced: Engine.cell(False),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = AppStore.store.handles()

	## The store a session starts with: the notes kept in local storage on
	## a board that knows whether the browser is online.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| AppStore.store.with_initial(AppStore.h.board, Notes.initial(Notes.stored_notes(boot.storage), boot.online))

	## The reader types in the new note's box.
	drafted : Str -> List(Engine.Write(_))
	drafted = |text| [AppStore.h.draft.put(text)]

	## The reader saves `draft`: it joins the board as a note and the box
	## is cleared, in one transition. A blank draft writes nothing.
	saved : Str -> List(Engine.Write(_))
	saved = |draft|
		if Notes.draft_body(draft) == "" {
			[]
		} else {
			[AppStore.h.board.change(|board| Notes.save_note(board, draft)), AppStore.h.draft.put("")]
		}

	## The reader edits the body of the note `id`, which queues it again
	## if it had synced.
	edited : { id : Str, text : Str } -> List(Engine.Write(_))
	edited = |{ id, text }| [AppStore.h.board.change(|board| Notes.edit_note(board, id, Notes.sanitize(text)))]

	## The reader queues the note `id` for the outbox.
	queued : Str -> List(Engine.Write(_))
	queued = |id| [AppStore.h.board.change(|board| Notes.queue_note(board, id))]

	## The reader sends a failed note again.
	retried : Str -> List(Engine.Write(_))
	retried = |id| [AppStore.h.board.change(|board| Notes.retry_note(board, id))]

	## The reader moves the note `id` to the front, so it drains first.
	promoted : Str -> List(Engine.Write(_))
	promoted = |id| [AppStore.h.board.change(|board| Notes.promote_note(board, id))]

	## The reader deletes the note `id`.
	deleted : Str -> List(Engine.Write(_))
	deleted = |id| [AppStore.h.board.change(|board| Notes.delete_note(board, id))]

	## The reader pauses or resumes automatic sync.
	auto_set : Bool -> List(Engine.Write(_))
	auto_set = |auto| [AppStore.h.board.change(|board| Notes.set_auto(board, auto))]

	## The browser went offline or came back.
	connected : Bool -> List(Engine.Write(_))
	connected = |online| [AppStore.h.board.change(|board| Notes.set_online(board, online))]

	## The sync service answered lane `slot`'s send, issued at `issue`:
	## `accepted` when it echoed the token it was sent.
	answered : { slot : U64, issue : Notes.Issue, accepted : Bool } -> List(Engine.Write(_))
	answered = |{ slot, issue, accepted }| [AppStore.h.board.change(|board| Notes.settle_send(board, slot, issue, accepted))]

	## The reader shows or hides the notes that have synced.
	synced_hidden : Bool -> List(Engine.Write(_))
	synced_hidden = |hide| [AppStore.h.hide_synced.put(hide)]
}

## A board with one queued note in lane 0 and a draft in lane 1, online.
stored : Engine.Store(_, _)
stored = AppStore.store.with_initial(
	AppStore.h.board,
	Notes.initial([{ id: "n0", slot: 0, body: "Generator hours", queued: True, rev: "r7" }, { id: "n1", slot: 1, body: "Fence line check", queued: False, rev: "r7" }], True),
)

## The ids of a store's notes, in drain order.
ids : Engine.Store(_, _) -> List(Str)
ids = |at| at.read(AppStore.h.board).notes.map(|note| note.id)

## The status of the note `id` in a store.
status : Engine.Store(_, _), Str -> Str
status = |at, id| match Notes.board_rows(at.read(AppStore.h.board)).find_first(|row| row.id == id) {
	Ok(row) => Notes.status_title(row.status)
	Err(_) => "no such note"
}

## Saving a draft adds the note and clears the box as one transition, and
## a blank draft writes neither cell.
expect {
	typed = stored.after(AppStore.drafted(" Pump | pressure "))
	saved = typed.after(AppStore.saved(typed.read(AppStore.h.draft)))
	blank = stored.after(AppStore.drafted("  ;  "))
	unsaved = blank.after(AppStore.saved(blank.read(AppStore.h.draft)))
	actual =
		\\saved: ${Str.inspect(ids(saved))} "${saved.read(AppStore.h.draft)}" ${status(saved, "s1")}
		\\blank: ${Str.inspect(ids(unsaved))} "${unsaved.read(AppStore.h.draft)}"
	expected =
		\\saved: ["n0", "n1", "s1"] "" Draft
		\\blank: ["n0", "n1"] "  ;  "
	actual == expected
}

## A sync that echoes its token settles its note, and an edit of the
## synced note queues it again under a new revision.
expect {
	issue = Notes.issue_at(stored.read(AppStore.h.board), 0)
	synced = stored.after(AppStore.answered({ slot: 0, issue, accepted: True }))
	edited = synced.after(AppStore.edited({ id: "n0", text: "Generator | hours 128" }))
	actual =
		\\at mount: ${status(stored, "n0")}
		\\answered: ${status(synced, "n0")}
		\\edited: ${status(edited, "n0")} ${Str.inspect(Notes.issue_at(edited.read(AppStore.h.board), 0))}
	expected =
		\\at mount: Syncing
		\\answered: Synced
		\\edited: Syncing { generation: 2, request: Send("n0#n0:1") }
	actual == expected
}

## Going offline stops the lanes, and the answer to a send from before
## settles nothing once the connection has returned.
expect {
	first = Notes.issue_at(stored.read(AppStore.h.board), 0)
	offline = stored.after(AppStore.connected(False))
	back = offline.after(AppStore.connected(True))
	late = back.after(AppStore.answered({ slot: 0, issue: first, accepted: True }))
	actual =
		\\offline: ${status(offline, "n0")}
		\\back: ${status(back, "n0")}
		\\late answer: ${status(late, "n0")}
	expected =
		\\offline: Queued
		\\back: Syncing
		\\late answer: Syncing
	actual == expected
}

## Queueing, promoting and deleting each change the board's notes, and
## pausing auto-sync leaves a queued note waiting.
expect {
	paused = stored.after(AppStore.auto_set(False))
	queued = paused.after(AppStore.queued("n1"))
	promoted = queued.after(AppStore.promoted("n1"))
	resumed = promoted.after(AppStore.auto_set(True))
	deleted = resumed.after(AppStore.deleted("n1"))
	actual =
		\\paused: ${status(paused, "n0")}
		\\queued: ${status(queued, "n1")}
		\\promoted: ${Str.inspect(ids(promoted))}
		\\resumed: ${status(resumed, "n1")}, ${status(resumed, "n0")}
		\\deleted: ${Str.inspect(ids(deleted))} ${status(deleted, "n0")}
	expected =
		\\paused: Queued
		\\queued: Queued
		\\promoted: ["n1", "n0"]
		\\resumed: Syncing, Queued
		\\deleted: ["n0"] Syncing
	actual == expected
}

## A failed sync can be retried, which sends the note again under a new
## revision.
expect {
	issue = Notes.issue_at(stored.read(AppStore.h.board), 0)
	failed = stored.after(AppStore.answered({ slot: 0, issue, accepted: False }))
	retried = failed.after(AppStore.retried("n0"))
	actual =
		\\answered: ${status(failed, "n0")}
		\\retried: ${status(retried, "n0")} ${Str.inspect(Notes.issue_at(retried.read(AppStore.h.board), 0).request)}
	expected =
		\\answered: Failed
		\\retried: Syncing Send("n0#n0:1")
	actual == expected
}

## Hiding the synced notes writes the filter and leaves the board alone.
expect {
	hidden = stored.after(AppStore.synced_hidden(True))
	(hidden.read(AppStore.h.hide_synced), hidden.read(AppStore.h.board) == stored.read(AppStore.h.board)) == (True, True)
}
