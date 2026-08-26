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
		status : Str,
		status_label : Str,
		detail : Str,
		queue_disabled : Bool,
		retry_disabled : Bool,
	}

	Board : { notes : List(Note), online : Bool, auto : Bool, views : List(TaskView) }

	initial_capture : Capture
	initial_capture = { draft: "", ops: [] }

	## --- small helpers ---
	part_at : List(Str), U64 -> Str
	part_at = |parts, index|
		parts
			.fold(
				{ cursor: 0, found: "" },
				|acc, part|
					if acc.cursor == index {
						{ cursor: acc.cursor + 1, found: part }
					} else {
						{ cursor: acc.cursor + 1, found: acc.found }
					},
			)
			.found

	digit_value : Str -> U64
	digit_value = |text|
		if text == "1" {
			1
		} else if text == "2" {
			2
		} else if text == "3" {
			3
		} else if text == "4" {
			4
		} else if text == "5" {
			5
		} else if text == "6" {
			6
		} else if text == "7" {
			7
		} else if text == "8" {
			8
		} else if text == "9" {
			9
		} else {
			0
		}

	## Remove the two characters the storage format reserves as separators.
	sanitize : Str -> Str
	sanitize = |text| Str.join_with(Str.join_with(text.split_on("|"), " ").split_on(";"), " ")

	view_at : List(TaskView), U64 -> TaskView
	view_at = |views, slot|
		views
			.fold(
				{ cursor: 0, found: TaskIdle },
				|acc, view|
					if acc.cursor == slot {
						{ cursor: acc.cursor + 1, found: view }
					} else {
						{ cursor: acc.cursor + 1, found: acc.found }
					},
			)
			.found

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
			slot = digit_value(slot_text)
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
			text.split_on(";").fold([], |acc, chunk| List.concat(acc, decode_note(chunk)))
		}

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
		} else if notes.fold(False, |taken, note| taken or note.slot == candidate) {
			free_slot(notes, candidate + 1)
		} else {
			candidate
		}

	next_id : List(Op) -> Str
	next_id = |ops| {
		adds : U64
		adds =
			ops.fold(
				0,
				|count, op|
					match op {
						OpAdd(_, _) => count + 1
						_ => count
					},
			)
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
				if notes.fold(False, |seen, note| seen or note.id == id) {
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
			OpDelete(id) => notes.fold([], |acc, note| if note.id == id { acc } else { acc.append(note) })
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
				promoted = notes.fold([], |acc, note| if note.id == id { acc.append(note) } else { acc })
				rest = notes.fold([], |acc, note| if note.id == id { acc } else { acc.append(note) })
				List.concat(promoted, rest)
			}
		}

	## The next absolute revision for a note, derived from the log alone so the
	## reducer never has to read a signal.
	next_rev : List(Op), Str -> Str
	next_rev = |ops, id| {
		bumps : U64
		bumps =
			ops.fold(
				0,
				|count, op|
					match op {
						OpEdit(op_id, _, _) => if op_id == id { count + 1 } else { count }
						OpRetry(op_id, _) => if op_id == id { count + 1 } else { count }
						_ => count
					},
			)
		"${id}:${(bumps + 1).to_str()}"
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
		notes.fold(
			"",
			|found, note|
				if found != "" {
					found
				} else if note.queued and is_outstanding(note, view_at(views, note.slot)) {
					note.id
				} else {
					found
				},
		)

	row_status : Board, Str, Note -> Str
	row_status = |board, head, note| {
		view = view_at(board.views, note.slot)
		if !note.queued {
			"draft"
		} else if is_synced(note, view) {
			"synced"
		} else if is_failed(note, view) {
			"failed"
		} else if board.online and board.auto and head == note.id {
			"syncing"
		} else {
			"queued"
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
					status_label: status_title(status),
					detail: "Outbox slot ${(note.slot + 1).to_str()}, revision ${note.rev}",
					queue_disabled: note.queued,
					retry_disabled: status != "failed",
				}
			},
		)
	}

	## Only one lane is ever in flight, so the whole outbox shares one task name.
	request_at : Board, U64 -> Str
	request_at = |board, slot|
		if !board.online or !board.auto {
			""
		} else {
			head = head_id(board.notes, board.views)
			if head == "" {
				""
			} else {
				board.notes.fold(
					"",
					|found, note|
						if note.slot == slot and note.id == head {
							token(note)
						} else {
							found
						},
				)
			}
		}

	## The status word a row shows in its badge. The badge class is derived from
	## the same `status` field, so the colour can never disagree with the word.
	status_title : Str -> Str
	status_title = |status|
		if status == "draft" {
			"Draft"
		} else if status == "queued" {
			"Queued"
		} else if status == "syncing" {
			"Syncing"
		} else if status == "synced" {
			"Synced"
		} else {
			"Failed"
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

	count_status : List(Row), Str -> U64
	count_status = |rows, status| rows.fold(0, |count, row| if row.status == status { count + 1 } else { count })

	outbox_count : List(Row) -> U64
	outbox_count = |rows|
		rows.fold(
			0,
			|count, row|
				if row.status == "queued" or row.status == "syncing" or row.status == "failed" {
					count + 1
				} else {
					count
				},
		)

	syncing_text : List(Row) -> Str
	syncing_text = |rows| {
		found = rows.fold("", |acc, row| if acc != "" { acc } else if row.status == "syncing" { row.id } else { acc })
		if found == "" {
			"None"
		} else {
			found
		}
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
	is_full = |rows| rows.fold(0, |count, _row| count + 1) >= slot_count

	capacity_text : List(Row) -> Str
	capacity_text = |rows| {
		used = rows.fold(0, |count, _row| count + 1)
		if used >= slot_count {
			"Full"
		} else {
			"${used.to_str()} of ${slot_count.to_str()}"
		}
	}
}
