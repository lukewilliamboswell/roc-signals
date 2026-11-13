import Time

## Field Notes domain: the persisted note shape, the board (notes,
## connectivity, auto-sync and the four sync lanes), every change to the
## board as a pure function on it, and the pure derivation from the board
## to per-row view records.
##
## The board is one value because its parts must agree: which lane sends
## follows from the notes, their order, the lanes' settlements and the
## connection, so every change ends by working the lanes out again
## (`settle`). The app holds it in one cell of its store (`AppStore`).
##
## Nothing in here knows about markup, CSS or the engine.
Notes := {}.{

	## Local storage key holding the whole persisted note list.
	notes_key = "field-notes:notes"

	## The outbox has a fixed number of sync lanes, one per slot. Each lane
	## retains its latest settlement; a note's status compares that token with
	## its current revision.
	slot_count : U64
	slot_count = 4

	TaskView : [TaskIdle, TaskDone(Str), TaskFailed(Str)]

	## Where a note sits in the sync pipeline. This is derived per render from
	## (note, lane settlement, online, auto-sync) — it is never stored — and it is
	## the single source for the badge caption, the badge tone, and the
	## `data-status` attribute, so the three can never disagree.
	Status := [Draft, Queued, Syncing, Synced, Failed].{
		is_eq : _
	}

	## The machine-readable token, rendered into `data-status`.
	status_code : Notes.Status -> Str
	status_code = |status|
		match status {
			Draft => "draft"
			Queued => "queued"
			Syncing => "syncing"
			Synced => "synced"
			Failed => "failed"
		}

	## The status word a row shows in its badge.
	status_title : Notes.Status -> Str
	status_title = |status|
		match status {
			Draft => "Draft"
			Queued => "Queued"
			Syncing => "Syncing"
			Synced => "Synced"
			Failed => "Failed"
		}

	## The wire token for a note nobody has queued yet is `draft`.
	expect status_code(Draft) == "draft"

	## A lane that settled with a failure reports the `failed` token.
	expect status_code(Failed) == "failed"

	## The badge caption is the human spelling of the same tag.
	expect status_title(Syncing) == "Syncing"

	## A note counts against the outbox until it has settled successfully; a
	## failure still occupies a lane, so it still counts.
	in_outbox : Notes.Status -> Bool
	in_outbox = |status|
		match status {
			Draft => False
			Synced => False
			_ => True
		}

	## What a lane should send next. Idle is explicit, so an empty string never
	## stands in for "nothing to send".
	Request := [Idle, Send(Str)].{
		is_eq : _
	}

	## Restored five-field notes have no capture sample. New notes remain
	## unknown only until their own timer answers.
	Captured : [Unknown, At(I64)]

	Note : { id : Str, slot : U64, body : Str, queued : Bool, rev : Str, captured : Captured }

	## One sync lane: the request it last issued, how many sends it has
	## issued (its generation), and the settlement of its latest send. A
	## result for an older generation is stale and settles nothing. The
	## settlement is of the note in the lane's slot, and goes when that
	## note is deleted.
	Lane : { request : Notes.Request, generation : U64, settled : TaskView }

	## What a lane's effect site watches: a new generation is a new send, so
	## a resend of the same token is a distinct occurrence.
	Issue : { request : Notes.Request, generation : U64 }

	## The whole board. Saves advance the id generator alongside the new
	## note, and sync changes work the lanes' requests out again (`settle`),
	## so the notes, generator and lanes are one value.
	Board : {
		notes : List(Note),
		rng : U64,
		online : Bool,
		auto : Bool,
		lanes : List(Lane),
	}

	Row : {
		id : Str,
		body : Str,
		status : Notes.Status,
		detail : Str,
		captured : Captured,
		queue_disabled : Bool,
		retry_disabled : Bool,
	}

	idle_lane : Lane
	idle_lane = { request: Idle, generation: 0, settled: TaskIdle }

	## The board at mount: the restored notes, the browser's connectivity,
	## auto-sync on, and the lanes asked to send whatever is due.
	initial : List(Note), Bool -> Board
	initial = |notes, online| Notes.settle({ notes, rng: 0, online, auto: True, lanes: List.repeat(Notes.idle_lane, Notes.slot_count) })

	## The browser supplies a fresh seed for each document. The generator's
	## state stays beside the notes whose ids it mints.
	seeded : Board, U128 -> Board
	seeded = |board, seed| { ..board, rng: Time.seed_state(seed) }

	## The id the next successful save will mint, as a small reading for the
	## capture outbox. Reading it keeps no reference to the board's notes.
	next_id : Board -> Str
	next_id = |board| "n-${Time.hex(Time.next(board.rng).value)}"

	## --- small helpers ---
	part_at : List(Str), U64 -> Str
	part_at = |parts, index| parts.get(index) ?? ""

	## Remove the two characters the storage format reserves as separators.
	sanitize : Str -> Str
	sanitize = |text| Str.join_with(Str.join_with(text.split_on("|"), " ").split_on(";"), " ")

	lane_at : Board, U64 -> Lane
	lane_at = |board, slot| board.lanes.get(slot) ?? Notes.idle_lane

	views : Board -> List(TaskView)
	views = |board| board.lanes.map(|lane| lane.settled)

	view_at : List(TaskView), U64 -> TaskView
	view_at = |vs, slot| vs.get(slot) ?? TaskIdle

	## --- storage codec ---
	encode_note : Note -> Str
	encode_note = |note| {
		queued_text = if note.queued {
			"1"
		} else {
			"0"
		}
		captured_text = match note.captured {
			Unknown => "unknown"
			At(at_ms) => at_ms.to_str()
		}
		"${note.id}|${note.slot.to_str()}|${queued_text}|${note.rev}|${captured_text}|${note.body}"
	}

	encode_notes : List(Note) -> Str
	encode_notes = |notes| Str.join_with(notes.map(Notes.encode_note), ";")

	## Storage keeps every field of a note, ids included, so decoding a value this
	## app just wrote reproduces exactly the notes it encoded.
	decode_note : Str -> List(Note)
	decode_note = |chunk| {
		parts = chunk.split_on("|")
		id = Notes.part_at(parts, 0)
		slot_text = Notes.part_at(parts, 1)
		if id == "" or slot_text == "" {
			[]
		} else {
			# Keep the app's existing recovery of a malformed stored slot.
			slot = Try.ok_or(U64.from_str(slot_text), 0)
			captured = if parts.len() == 5 {
				Ok(Unknown)
			} else if Notes.part_at(parts, 4) == "unknown" {
				Ok(Unknown)
			} else {
				match I64.from_str(Notes.part_at(parts, 4)) {
					Ok(at_ms) => Ok(At(at_ms))
					Err(error) => Err(error)
				}
			}
			match captured {
				Ok(at) if slot < Notes.slot_count => [{ id, slot, body: Notes.part_at(parts, if (parts.len() == 5) 4 else 5), queued: Notes.part_at(parts, 2) == "1", rev: Notes.part_at(parts, 3), captured: at }]
				_ => []
			}
		}
	}

	decode_notes : Str -> List(Note)
	decode_notes = |text|
		if text.trim() == "" {
			[]
		} else {
			text.split_on(";").join_map(Notes.decode_note)
		}

	## Encoding a note and decoding it again reproduces it exactly, which is
	## what lets the persisted value restore the board.
	expect {
		note = { id: "n0", slot: 0, body: "Generator hours", queued: True, rev: "r7", captured: Unknown }
		Notes.decode_note(Notes.encode_note(note)) == [note]
	}

	## An empty storage value restores an empty board rather than a phantom note.
	expect Notes.decode_notes("") == []

	## A single stored record restores as one note keeping the id it was written with.
	expect Notes.decode_notes("n0|0|1|r7|Generator hours").map(|note| note.id) == ["n0"]

	## A slot outside the outbox is not a note this app can hold, so it is dropped.
	expect Notes.decode_notes("n0|9|1|r7|Generator hours") == []

	## The notes in the boot storage (none when the key is absent).
	stored_notes : List((Str, Str)) -> List(Note)
	stored_notes = |storage|
		match storage.find_first(|(key, _)| key == Notes.notes_key) {
			Ok((_, value)) => Notes.decode_notes(value)
			Err(_) => []
		}

	## The hint under the toolbar: whether notes survive a reload depends on
	## the browser letting the app use local storage at all.
	storage_notice : Bool -> Str
	storage_notice = |available|
		if available {
			"Notes are restored from local storage on reload"
		} else {
			"Local storage is unavailable, so nothing survives a reload"
		}

	## --- transitions ---
	free_slot : List(Note), U64 -> U64
	free_slot = |notes, candidate|
		if candidate >= Notes.slot_count {
			Notes.slot_count
		} else if notes.any(|note| note.slot == candidate) {
			Notes.free_slot(notes, candidate + 1)
		} else {
			candidate
		}

	## The revision an edit or a retry gives `note`: `<id>:<n>`, one more
	## than the note's current revision. Storage keeps a note's revision
	## with it, so the count goes on through a reload, and a note is never
	## given a revision it has held: its token can never be one a lane has
	## settled for it. A revision that is not of that form (a note as first
	## saved, or whatever storage held) counts as none, so the first is
	## `<id>:1`.
	next_rev : Note -> Str
	next_rev = |note| {
		prefix = "${note.id}:"
		held = if (note.rev.starts_with(prefix)) U64.from_str(note.rev.drop_prefix(prefix)) ?? 0 else 0
		"${prefix}${(if (held < U64.highest) held + 1 else 1).to_str()}"
	}

	## A note that has never been edited is given its first revision.
	expect Notes.next_rev({ id: "n0", slot: 0, body: "", queued: True, rev: "r7", captured: Unknown }) == "n0:1"

	## Each edit gives the revision after the note's own, wherever that came
	## from: this session, or the storage an earlier one left.
	expect Notes.next_rev({ id: "n0", slot: 0, body: "", queued: True, rev: "n0:1", captured: Unknown }) == "n0:2"

	## Only a revision under the note's own id counts.
	expect Notes.next_rev({ id: "n0", slot: 0, body: "", queued: True, rev: "n1:4", captured: Unknown }) == "n0:1"

	map_note : Board, Str, (Note -> Note) -> Board
	map_note = |board, id, f| { ..board, notes: board.notes.map(|note| if (note.id == id) f(note) else note) }

	## The body a draft saves as: without the storage format's separators
	## and the space around it. A blank draft has none (`""`).
	draft_body : Str -> Str
	draft_body = |draft| Notes.sanitize(draft).trim()

	## Save a nonblank draft in the first free slot under the next generated
	## id. Its capture time is unknown until the posted Timer(0) answers.
	save_note : Board, Str -> Board
	save_note = |board, draft| {
		body = Notes.draft_body(draft)
		slot = Notes.free_slot(board.notes, 0)
		if body == "" or slot >= Notes.slot_count {
			board
		} else {
			generated = Time.next(board.rng)
			note = { id: "n-${Time.hex(generated.value)}", slot, body, queued: False, rev: "r0", captured: Unknown }
			Notes.settle({ ..board, rng: generated.state, notes: board.notes.append(note) })
		}
	}

	## A timer's answer stamps the note it was issued for, even if a later
	## save or edit has happened. A deleted note is left absent.
	stamped : Board, { id : Str, at_ms : I64 } -> Board
	stamped = |board, { id, at_ms }| Notes.map_note(board, id, |note| { ..note, captured: At(at_ms) })

	## Saving uses the seeded stream and leaves a blank draft unchanged.
	expect {
		board = Notes.seeded(Notes.initial([{ id: "n0", slot: 1, body: "one", queued: True, rev: "r7", captured: Unknown }], False), 7)
		saved = Notes.save_note(board, "  Pump | pressure; log ")
		blank = Notes.save_note(board, " | ")
		(saved.notes.drop_first(1), blank == board) == ([{ id: "n-63cbe1e459320dd7", slot: 0, body: "Pump   pressure  log", queued: False, rev: "r0", captured: Unknown }], True)
	}

	## A second save takes the next generated id. A new document's seed makes
	## its first id different from the notes a previous document stored.
	expect {
		first = Notes.save_note(Notes.seeded(Notes.initial([], False), 7), "one")
		second = Notes.save_note(first, "two")
		reloaded = Notes.seeded(Notes.initial(first.notes, False), 8)
		{ same_document: second.notes.map(|note| note.id), next_document: Notes.save_note(reloaded, "three").notes.map(|note| note.id) } == {
			same_document: ["n-63cbe1e459320dd7", "n-044c3cd7f43c661c"],
			next_document: ["n-63cbe1e459320dd7", "n-9e5651b0ef953636"],
		}
	}

	## Stamping keeps the requested note's identity and every other note's time.
	expect {
		board = Notes.save_note(Notes.save_note(Notes.seeded(Notes.initial([], False), 7), "one"), "two")
		at = Notes.stamped(board, { id: "n-63cbe1e459320dd7", at_ms: -1 })
		at.notes.map(|note| note.captured) == [At(-1), Unknown]
	}

	## An edit gives the note its next revision, which no lane has settled,
	## and so re-queues an already synced note.
	edit_note : Board, Str, Str -> Board
	edit_note = |board, id, body| Notes.settle(Notes.map_note(board, id, |note| { ..note, body, rev: Notes.next_rev(note) }))

	## A retry sends the note again under its next revision.
	retry_note : Board, Str -> Board
	retry_note = |board, id| Notes.settle(Notes.map_note(board, id, |note| { ..note, rev: Notes.next_rev(note) }))

	queue_note : Board, Str -> Board
	queue_note = |board, id| Notes.settle(Notes.map_note(board, id, |note| { ..note, queued: True }))

	## Delete a note. Its lane forgets what it settled: a note saved into
	## the slot later is another note, even one a later session gives the
	## same id, and must not be taken for the one that synced there.
	delete_note : Board, Str -> Board
	delete_note = |board, id| {
		lanes = match board.notes.find_first(|note| note.id == id) {
			Ok(note) => board.lanes.set(note.slot, { ..Notes.lane_at(board, note.slot), settled: TaskIdle }) ?? board.lanes
			Err(_) => board.lanes
		}
		Notes.settle({ ..board, lanes, notes: board.notes.keep_if(|note| note.id != id) })
	}

	## Move a note to the front, so it drains first.
	promote_note : Board, Str -> Board
	promote_note = |board, id| Notes.settle({ ..board, notes: board.notes.keep_if(|note| note.id == id).concat(board.notes.keep_if(|note| note.id != id)) })

	set_online : Board, Bool -> Board
	set_online = |board, online| Notes.settle({ ..board, online })

	set_auto : Board, Bool -> Board
	set_auto = |board, auto| Notes.settle({ ..board, auto })

	## A sync result for lane `slot`, issued at `issue`. Only the lane's
	## latest send settles it: an older generation's result is stale.
	settle_send : Board, U64, Issue, Bool -> Board
	settle_send = |board, slot, issue, ok| {
		lane = Notes.lane_at(board, slot)
		match issue.request {
			Send(token) if lane.generation == issue.generation => {
				settled = if (ok) TaskDone(token) else TaskFailed(token)
				Notes.settle({ ..board, lanes: board.lanes.set(slot, { ..lane, settled }) ?? board.lanes })
			}
			_ => board
		}
	}

	## Re-derive every lane's request from the board. A lane whose request
	## changed to a send starts a new generation; its effect site then sends.
	settle : Board -> Board
	settle = |board| {
		var $lanes = []
		var $slot = 0.U64
		while $slot < Notes.slot_count {
			lane = Notes.lane_at(board, $slot)
			request = Notes.request_at(board, $slot)
			$lanes = $lanes.append(
				if request == lane.request {
					lane
				} else {
					generation = match request {
						Send(_) => lane.generation + 1
						Idle => lane.generation
					}
					{ ..lane, request, generation }
				},
			)
			$slot = $slot + 1
		}
		{ ..board, lanes: $lanes }
	}

	## What lane `slot`'s effect site watches.
	issue_at : Board, U64 -> Issue
	issue_at = |board, slot| {
		lane = Notes.lane_at(board, slot)
		{ request: lane.request, generation: lane.generation }
	}

	## --- sync derivation ---
	## A note's sync request token. Editing or retrying gives the note a new
	## revision, so a new token, which its lane has not settled: the note is
	## queued again.
	token : Note -> Str
	token = |note| "${note.id}#${note.rev}"

	is_synced : Note, TaskView -> Bool
	is_synced = |note, view|
		match view {
			TaskDone(payload) => payload == Notes.token(note)
			_ => False
		}

	is_failed : Note, TaskView -> Bool
	is_failed = |note, view|
		match view {
			TaskFailed(payload) => payload == Notes.token(note)
			_ => False
		}

	## Outstanding means "this lane has not settled the note's current token".
	is_outstanding : Note, TaskView -> Bool
	is_outstanding = |note, view| !Notes.is_synced(note, view) and !Notes.is_failed(note, view)

	## The outbox drains in capture order; failed notes are skipped so one failure
	## does not stall the notes behind it.
	head_id : List(Note), List(TaskView) -> Str
	head_id = |notes, vs|
		match notes.find_first(|note| note.queued and Notes.is_outstanding(note, Notes.view_at(vs, note.slot))) {
			Ok(note) => note.id
			Err(_) => ""
		}

	row_status : Board, List(TaskView), Str, Note -> Notes.Status
	row_status = |board, vs, head, note| {
		view = Notes.view_at(vs, note.slot)
		if !note.queued {
			Draft
		} else if Notes.is_synced(note, view) {
			Synced
		} else if Notes.is_failed(note, view) {
			Failed
		} else if board.online and board.auto and head == note.id {
			Syncing
		} else {
			Queued
		}
	}

	board_rows : Board -> List(Row)
	board_rows = |board| {
		vs = Notes.views(board)
		head = Notes.head_id(board.notes, vs)
		board.notes.map(
			|note| {
				status = Notes.row_status(board, vs, head, note)
				{
					id: note.id,
					body: note.body,
					status: status,
					detail: "Outbox slot ${(note.slot + 1).to_str()}, revision ${note.rev}",
					captured: note.captured,
					queue_disabled: note.queued,
					retry_disabled: match status {
						Failed => False
						_ => True
					},
				}
			},
		)
	}

	## Only the outbox head requests a send, from the lane of its slot.
	request_at : Board, U64 -> Notes.Request
	request_at = |board, slot|
		if !board.online or !board.auto {
			Idle
		} else {
			head = Notes.head_id(board.notes, Notes.views(board))
			if head == "" {
				Idle
			} else {
				match board.notes.find_first(|note| note.slot == slot and note.id == head) {
					Ok(note) => Send(Notes.token(note))
					Err(_) => Idle
				}
			}
		}

	## The lane holding the head of the outbox is asked to send that note's
	## token, as its first generation.
	expect {
		board = Notes.initial([{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7", captured: Unknown }], True)
		Notes.issue_at(board, 0) == { request: Send("n0#r7"), generation: 1 }
	}

	## Every lane that does not hold the head stays idle, so only one send is ever in flight.
	expect {
		board = Notes.initial([{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7", captured: Unknown }], True)
		Notes.issue_at(board, 1) == { request: Idle, generation: 0 }
	}

	## While offline no lane sends, however many notes are queued.
	expect {
		board = Notes.initial([{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7", captured: Unknown }], False)
		Notes.request_at(board, 0) == Idle
	}

	## Going offline and back resends the same token as a new generation, and
	## the first send's late result is stale.
	expect {
		board0 = Notes.initial([{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7", captured: Unknown }], True)
		first = Notes.issue_at(board0, 0)
		board1 = Notes.set_online(Notes.set_online(board0, False), True)
		late = Notes.settle_send(board1, 0, first, True)
		actual = [Notes.issue_at(board1, 0).generation.to_str(), Str.inspect(Notes.lane_at(late, 0).settled == TaskIdle)]
		actual == ["2", "True"]
	}

	outbox_text : List(Row) -> Str
	outbox_text = |rows| {
		count = Notes.outbox_count(rows)
		if count == 1 {
			"1 note waiting to sync"
		} else {
			"${count.to_str()} notes waiting to sync"
		}
	}

	## A single waiting note is counted in the singular.
	expect Notes.outbox_text([{ id: "a", body: "", status: Queued, detail: "", captured: Unknown, queue_disabled: True, retry_disabled: True }]) == "1 note waiting to sync"

	## An empty outbox still reads as a plural count rather than a special sentence.
	expect Notes.outbox_text([]) == "0 notes waiting to sync"

	## The storage hint tells the truth about reloads either way.
	expect Notes.storage_notice(True) == "Notes are restored from local storage on reload"
	expect Notes.storage_notice(False) == "Local storage is unavailable, so nothing survives a reload"

	count_status : List(Row), Notes.Status -> U64
	count_status = |rows, status| rows.keep_if(|row| row.status == status).len()

	outbox_count : List(Row) -> U64
	outbox_count = |rows| rows.keep_if(|row| Notes.in_outbox(row.status)).len()

	syncing_text : List(Row) -> Str
	syncing_text = |rows|
		match rows.find_first(|row| row.status == Syncing) {
			Ok(row) => row.id
			Err(_) => "None"
		}

	network_text : Bool -> Str
	network_text = |online|
		if online {
			"Online. The outbox drains one note at a time."
		} else {
			"Offline. Notes stay in the outbox until the connection returns."
		}

	auto_text : Bool -> Str
	auto_text = |auto|
		if auto {
			"Auto sync on"
		} else {
			"Auto sync paused"
		}

	is_full : List(Row) -> Bool
	is_full = |rows| rows.len() >= Notes.slot_count

	capacity_text : List(Row) -> Str
	capacity_text = |rows| {
		used = rows.len()
		if used >= Notes.slot_count {
			"Full"
		} else {
			"${used.to_str()} of ${Notes.slot_count.to_str()}"
		}
	}
}

## Whether a note waits to be sent after it is restored at revision `rev`,
## synced, and then edited `edits` times while offline.
requeued : Str, U64 -> Bool
requeued = |rev, edits| {
	restored = Notes.initial([{ id: "n0", slot: 0, body: "one", queued: True, rev, captured: Unknown }], True)
	synced = Notes.set_online(Notes.settle_send(restored, 0, Notes.issue_at(restored, 0), True), False)
	edited = List.repeat({}, edits).fold(synced, |board, _| Notes.edit_note(board, "n0", "two"))
	edited.notes.all(|note| Notes.is_outstanding(note, Notes.view_at(Notes.views(edited), note.slot)))
}

## An edit re-queues a synced note whatever revision it was restored at:
## `n0:1` and `n0:2` are what edits in an earlier session left.
expect [requeued("r7", 1), requeued("n0:1", 1), requeued("n0:2", 1)] == [True, True, True]

## A second edit before the first is sent does not come back to the
## revision the lane settled.
expect [requeued("n0:1", 2), requeued("n0:2", 2)] == [True, True]

## Deleting a synced note clears its lane settlement before another id
## takes that slot, so a new note remains outstanding.
expect {
	restored = Notes.initial([{ id: "old", slot: 0, body: "one", queued: True, rev: "old:1", captured: Unknown }], True)
	synced = Notes.settle_send(restored, 0, Notes.issue_at(restored, 0), True)
	fresh_id = Notes.next_id(synced)
	again = Notes.edit_note(Notes.save_note(Notes.delete_note(synced, "old"), "two"), fresh_id, "three")
	again.notes.map(|note| Notes.is_outstanding(note, Notes.view_at(Notes.views(again), note.slot))) == [True]
}

## The new storage field preserves negative samples, and old five-field
## notes remain explicitly unknown instead of acquiring a plausible date.
expect {
	legacy = Notes.decode_notes("old|0|0|r0|before clocks")
	before_epoch = Notes.stamped(Notes.initial(legacy, False), { id: "old", at_ms: -1 })
	{ legacy: legacy.map(|note| note.captured), round_trip: Notes.decode_notes(Notes.encode_notes(before_epoch.notes)) } == { legacy: [Unknown], round_trip: before_epoch.notes }
}

## A malformed timestamp is not repaired into a date or an unknown sample.
expect Notes.decode_notes("bad|0|0|r0|tomorrow|body").is_empty()
