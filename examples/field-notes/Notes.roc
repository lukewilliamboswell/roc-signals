## Field Notes domain: the persisted note shape, the idempotent operation log
## the session records on top of the restored notes, and the pure derivation
## from (notes, online, auto-sync, lane settlements) to per-row view records.
##
## Nothing in here knows about markup or CSS.
import pf.Browser

Notes := {}.{
	## Local storage key holding the whole persisted note list.
	notes_key = "field-notes:notes"

	## The outbox has a fixed number of sync lanes. Each lane owns one task
	## source, so a note's sync outcome is derived from its lane instead of being
	## copied into retained state (a task result can never be written back into
	## `Ui.state`).
	slot_count : U64
	slot_count = 4

	TaskView : [TaskIdle, TaskDone(Str), TaskFailed(Str)]

	## Where a note sits in the sync pipeline. This is derived per render from
	## (note, lane settlement, online, auto-sync) — it is never stored — and it is
	## the single source for the badge caption, the badge tone, and the
	## `data-status` attribute, so the three can never disagree.
	Status := [Draft, Queued, Syncing, Synced, Failed].{
		is_eq : Notes.Status, Notes.Status -> Bool
		is_eq = |left, right|
			match left {
				Draft => match right {
					Draft => True
					_ => False
				}
				Queued => match right {
					Queued => True
					_ => False
				}
				Syncing => match right {
					Syncing => True
					_ => False
				}
				Synced => match right {
					Synced => True
					_ => False
				}
				Failed => match right {
					Failed => True
					_ => False
				}
			}
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

	expect status_code(Draft) == "draft"
	expect status_code(Failed) == "failed"
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

	## What a lane should be doing right now. `Signal.start_str` puts a `Str` on
	## the wire, so the token is encoded at exactly one point (`sync_lane`) rather
	## than an empty string standing in for "nothing to send".
	Request := [Idle, Send(Str)].{
		is_eq : Notes.Request, Notes.Request -> Bool
		is_eq = |left, right|
			match left {
				Idle => match right {
					Idle => True
					_ => False
				}
				Send(left_token) => match right {
					Send(right_token) => left_token == right_token
					_ => False
				}
			}
	}

	Op : [
		OpAdd(Str, Str),
		OpEdit(Str, Str, Str),
		OpDelete(Str),
		OpQueue(Str),
		OpRetry(Str, Str),
		OpPromote(Str),
	]

	Note : { id : Str, slot : U64, body : Str, queued : Bool, rev : Str }

	Capture : { draft : Str, ops : List(Op) }

	Row : {
		id : Str,
		body : Str,
		status : Notes.Status,
		detail : Str,
		queue_disabled : Bool,
		retry_disabled : Bool,
	}

	Board : { notes : List(Note), online : Bool, auto : Bool, views : List(TaskView) }

	initial_capture : Capture
	initial_capture = { draft: "", ops: [] }

	## --- small helpers ---
	part_at : List(Str), U64 -> Str
	part_at = |parts, index| Try.ok_or(parts.get(index), "")

	## Remove the two characters the storage format reserves as separators.
	sanitize : Str -> Str
	sanitize = |text| Str.join_with(Str.join_with(text.split_on("|"), " ").split_on(";"), " ")

	view_at : List(TaskView), U64 -> TaskView
	view_at = |views, slot| Try.ok_or(views.get(slot), TaskIdle)

	## --- storage codec ---
	encode_note : Note -> Str
	encode_note = |note| {
		queued_text = if note.queued { "1" } else { "0" }
		"${note.id}|${note.slot.to_str()}|${queued_text}|${note.rev}|${note.body}"
	}

	encode_notes : List(Note) -> Str
	encode_notes = |notes| Str.join_with(notes.map(encode_note), ";")

	## Storage keeps every field of a note, ids included, so decoding a value this
	## app just wrote reproduces exactly the notes it encoded.
	decode_note : Str -> List(Note)
	decode_note = |chunk| {
		parts = chunk.split_on("|")
		id = part_at(parts, 0)
		slot_text = part_at(parts, 1)

		if id == "" or slot_text == "" {
			[]
		} else {
			## Storage may hold a value this app never wrote, so an unparseable
			## slot falls back to 0 rather than rejecting the note.
			slot = Try.ok_or(U64.from_str(slot_text), 0)
			if slot >= slot_count {
				[]
			} else {
				[
					{
						id: id,
						slot: slot,
						body: part_at(parts, 4),
						queued: part_at(parts, 2) == "1",
						rev: part_at(parts, 3),
					},
				]
			}
		}
	}

	decode_notes : Str -> List(Note)
	decode_notes = |text|
		if text.trim() == "" {
			[]
		} else {
			text.split_on(";").join_map(decode_note)
		}

	## Encoding a note and decoding it again reproduces it exactly, which is what
	## lets the persisted value be replayed through the operation log.
	expect {
		note = { id: "n0", slot: 0, body: "Generator hours", queued: True, rev: "r7" }
		decode_note(encode_note(note)) == [note]
	}

	expect decode_notes("") == []
	expect decode_notes("n0|0|1|r7|Generator hours").map(|note| note.id) == ["n0"]

	## A slot outside the outbox is not a note this app can hold, so it is dropped.
	expect decode_notes("n0|9|1|r7|Generator hours") == []

	stored_notes : Browser.StorageText -> List(Note)
	stored_notes = |stored|
		match stored {
			StorageValue(value) => decode_notes(value)
			_ => []
		}

	storage_notice : Browser.StorageText -> Str
	storage_notice = |stored|
		match stored {
			StorageUnavailable(_) => "Local storage is unavailable, so nothing survives a reload"
			_ => "Notes are restored from local storage on reload"
		}

	## --- operation log ---
	free_slot : List(Note), U64 -> U64
	free_slot = |notes, candidate|
		if candidate >= slot_count {
			slot_count
		} else if !notes.keep_if(|note| note.slot == candidate).is_empty() {
			free_slot(notes, candidate + 1)
		} else {
			candidate
		}

	next_id : List(Op) -> Str
	next_id = |ops| {
		adds =
			ops.keep_if(
				|op|
					match op {
						OpAdd(_, _) => True
						_ => False
					},
			).len()
		"s${(adds + 1).to_str()}"
	}

	## Every operation is idempotent: re-applying the whole log to notes that
	## already contain its effect is a no-op. That matters because the persisted
	## value this app writes is read back through the same storage signal, so the
	## log is replayed over its own output until it reaches a fixed point.
	apply_op : List(Note), Op -> List(Note)
	apply_op = |notes, op|
		match op {
			OpAdd(id, body) => {
				if !notes.keep_if(|note| note.id == id).is_empty() {
					notes
				} else {
					slot = free_slot(notes, 0)
					if slot >= slot_count {
						notes
					} else {
						notes.append({ id: id, slot: slot, body: body, queued: False, rev: "r0" })
					}
				}
			}
			OpEdit(id, body, rev) =>
				notes.map(
					|note|
						if note.id == id {
							{ ..note, body: body, rev: rev }
						} else {
							note
						},
				)
			OpDelete(id) => notes.keep_if(|note| note.id != id)
			OpQueue(id) =>
				notes.map(
					|note|
						if note.id == id {
							{ ..note, queued: True }
						} else {
							note
						},
				)
			OpRetry(id, rev) =>
				notes.map(
					|note|
						if note.id == id {
							{ ..note, rev: rev }
						} else {
							note
						},
				)
			OpPromote(id) => {
				List.concat(notes.keep_if(|note| note.id == id), notes.keep_if(|note| note.id != id))
			}
		}

	## The next absolute revision for a note, derived from the log alone so the
	## reducer never has to read a signal.
	next_rev : List(Op), Str -> Str
	next_rev = |ops, id| {
		bumps =
			ops.keep_if(
				|op|
					match op {
						OpEdit(op_id, _, _) => op_id == id
						OpRetry(op_id, _) => op_id == id
						_ => False
					},
			).len()
		"${id}:${(bumps + 1).to_str()}"
	}

	expect next_id([]) == "s1"
	expect next_id([OpAdd("s1", "one"), OpQueue("s1")]) == "s2"
	expect next_rev([], "n0") == "n0:1"
	expect next_rev([OpEdit("n0", "one", "n0:1")], "n0") == "n0:2"
	expect next_rev([OpEdit("n1", "one", "n1:1")], "n0") == "n0:1"

	## Re-applying a log over notes that already contain its effect is a no-op.
	expect {
		once = [OpAdd("s1", "one")].fold([], apply_op)
		twice = [OpAdd("s1", "one"), OpAdd("s1", "one")].fold([], apply_op)
		once == twice
	}

	edit_note : Capture, Str, Str -> Capture
	edit_note = |capture, id, body| push_op(capture, OpEdit(id, body, next_rev(capture.ops, id)))

	retry_note : Capture, Str -> Capture
	retry_note = |capture, id| push_op(capture, OpRetry(id, next_rev(capture.ops, id)))

	push_op : Capture, Op -> Capture
	push_op = |capture, op| { ..capture, ops: capture.ops.append(op) }

	save_note : Capture -> Capture
	save_note = |capture| {
		body = sanitize(capture.draft).trim()
		if body == "" {
			capture
		} else {
			{ draft: "", ops: capture.ops.append(OpAdd(next_id(capture.ops), body)) }
		}
	}

	## --- sync derivation ---
	## A note's sync request token. Editing or retrying mints a new revision, which
	## invalidates the lane's last settled token and re-queues the note.
	token : Note -> Str
	token = |note| "${note.id}#${note.rev}"

	is_synced : Note, TaskView -> Bool
	is_synced = |note, view|
		match view {
			TaskDone(payload) => payload == token(note)
			_ => False
		}

	is_failed : Note, TaskView -> Bool
	is_failed = |note, view|
		match view {
			TaskFailed(payload) => payload == token(note)
			_ => False
		}

	## Outstanding means "this lane has not settled the note's current token".
	is_outstanding : Note, TaskView -> Bool
	is_outstanding = |note, view| !is_synced(note, view) and !is_failed(note, view)

	## The outbox drains in capture order; failed notes are skipped so one failure
	## does not stall the notes behind it.
	head_id : List(Note), List(TaskView) -> Str
	head_id = |notes, views|
		match notes.find_first(|note| note.queued and is_outstanding(note, view_at(views, note.slot))) {
			Ok(note) => note.id
			Err(_) => ""
		}

	row_status : Board, Str, Note -> Notes.Status
	row_status = |board, head, note| {
		view = view_at(board.views, note.slot)
		if !note.queued {
			Draft
		} else if is_synced(note, view) {
			Synced
		} else if is_failed(note, view) {
			Failed
		} else if board.online and board.auto and head == note.id {
			Syncing
		} else {
			Queued
		}
	}

	board_rows : Board -> List(Row)
	board_rows = |board| {
		head = head_id(board.notes, board.views)
		board.notes.map(
			|note| {
				status = row_status(board, head, note)
				{
					id: note.id,
					body: note.body,
					status: status,
					detail: "Outbox slot ${(note.slot + 1).to_str()}, revision ${note.rev}",
					queue_disabled: note.queued,
					retry_disabled: match status {
						Failed => False
						_ => True
					},
				}
			},
		)
	}

	## Only one lane is ever in flight, so the whole outbox shares one task name.
	request_at : Board, U64 -> Notes.Request
	request_at = |board, slot|
		if !board.online or !board.auto {
			Idle
		} else {
			head = head_id(board.notes, board.views)
			if head == "" {
				Idle
			} else {
				match board.notes.find_first(|note| note.slot == slot and note.id == head) {
					Ok(note) => Send(token(note))
					Err(_) => Idle
				}
			}
		}

	## Only the lane holding the head of the outbox is asked to send; every other
	## lane, and every lane while offline or paused, stays idle.
	expect {
		notes = [{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7" }]
		board = { notes: notes, online: True, auto: True, views: [] }
		request_at(board, 0) == Send("n0#r7") and request_at(board, 1) == Idle
	}

	expect {
		notes = [{ id: "n0", slot: 0, body: "one", queued: True, rev: "r7" }]
		request_at({ notes: notes, online: False, auto: True, views: [] }, 0) == Idle
	}

	outbox_text : List(Row) -> Str
	outbox_text = |rows| {
		count = outbox_count(rows)
		if count == 1 {
			"1 note waiting to sync"
		} else {
			"${count.to_str()} notes waiting to sync"
		}
	}

	expect outbox_text([{ id: "a", body: "", status: Queued, detail: "", queue_disabled: True, retry_disabled: True }]) == "1 note waiting to sync"
	expect outbox_text([]) == "0 notes waiting to sync"

	count_status : List(Row), Notes.Status -> U64
	count_status = |rows, status| rows.keep_if(|row| row.status == status).len()

	outbox_count : List(Row) -> U64
	outbox_count = |rows| rows.keep_if(|row| in_outbox(row.status)).len()

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
	is_full = |rows| rows.len() >= slot_count

	capacity_text : List(Row) -> Str
	capacity_text = |rows| {
		used = rows.len()
		if used >= slot_count {
			"Full"
		} else {
			"${used.to_str()} of ${slot_count.to_str()}"
		}
	}
}
